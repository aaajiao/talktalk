// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Observation
import Synchronization
import TalkTalkApple
import TalkTalkAudio
import TalkTalkCore
import TalkTalkCloudUI
import TalkTalkDriverSupport
import TalkTalkEngineHost
import TalkTalkSession

/// The app composition for one SPEAK session. Lifecycle and key actions each have one ordered
/// consumer; immediate gate closes happen before any async cleanup or device replacement.
@MainActor
final class SpeakController {
    private enum Control: Sendable {
        case meeting(MeetingEvent), configurationChanged, endDemo
        case phoneInputChanged(MeetingSession, UInt64)
        case startDemo(CheckedContinuation<Void, any Error>)
    }
    enum DemoFailure: LocalizedError {
        case meetingActive, unavailable, reason(String)
        var errorDescription: String? {
            switch self {
            case .meetingActive: String(localized: "请先结束会议模式，再进行说话测试。")
            case .unavailable: String(localized: "说话测试未能启动，请检查组件和输入监控权限。")
            case .reason(let message): message
            }
        }
    }
    let output: SpeakOutput
    private let state: AppState
    private let meeting: MeetingController
    private let systemInput: SystemInputController
    private let engineHost: EngineHost
    private let hud: PTTHUD
    private let privacy: PrivacySettings?
    private var transcript: TranscriptWriter?
    private var sessionLog: EventLog?
    private let profile: PolicyProfile
    private let selfTestRunning: () -> Bool
    private var subscription: MeetingSubscription?
    private var ownsMeetingMode = false
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleEvents: AsyncStream<Control>.Continuation?
    private var actionTask: Task<Void, Never>?
    private var actionEvents: AsyncStream<PushToTalkKey.Action>.Continuation?
    private var meterTask: Task<Void, Never>?
    private var pipeline: SpeakPipeline?
    private var mic: MicIngest?
    private var keys: PassthroughRuntime?
    private var reporter: PlayoutReporter?
    private var clauseQueue: ClauseQueue?
    private var floor: FloorManager
    private var remoteSpeech: RemoteSpeechDetector
    private var owner: MeetingSession?
    private let watcher = DeviceWatcher()
    private var observedUIDs: Set<String> = []
    private var watching = false
    private var meetingOutputUIDs: Set<String>?
    private var lastMicUID: String?
    private var feedConfirmed = false
    private var phoneBoundary = PhoneSpeechBoundary()
    private var passthroughStart: HostTime?
    private(set) var speaking = false
    private(set) var passthroughOpen = false
    private(set) var degraded = false
    private(set) var warming = false
    private var closed = false
    private var sessionTarget: Lang?
    private var translationRefusal: String?
    private var announcementEnabled: Bool?
    private var restartQueued = false
    private var demoActive = false
    private var demoReady = false
    private var demoStopRequested = false
    private var demoFailure: String?
    private let demoMicrophone = DemoMicrophoneLease()
    private var demoMicPreference: String?
    private var lockObserver: NSObjectProtocol?
    private var demoWorkspaceObservers: [NSObjectProtocol] = []
    private var generation: UInt64 = 0
    var onDemoPlayed: (() -> Void)?
    var onDemoFailure: ((String) -> Void)?
    var onDemoStatus: ((String) -> Void)?
    var onMonitorAvailabilityChange: (() -> Void)?
    var onChange: (() -> Void)?
    var isActive: Bool { owner != nil || demoActive }

    private struct Links {
        var mic: MicIngest?
        var keys: PassthroughRuntime?
        var speakerMode = true
        var micUID: String?
        var gainDb = 0.0
        var cueDbfs = -30.0
        var generation: UInt64 = 0
    }
    private final class LinkBox: Sendable { let value = Mutex(Links()) }
    private let links = LinkBox()

    init(state: AppState, meeting: MeetingController, systemInput: SystemInputController,
         engineHost: EngineHost, output: SpeakOutput, profile: PolicyProfile, hud: PTTHUD,
         privacy: PrivacySettings? = nil,
         selfTestRunning: @escaping () -> Bool) {
        self.state = state; self.meeting = meeting; self.systemInput = systemInput
        self.engineHost = engineHost; self.output = output; self.profile = profile; self.hud = hud
        floor = FloorManager(config: profile.speak.floor)
        remoteSpeech = RemoteSpeechDetector(config: profile.speak.floor)
        self.selfTestRunning = selfTestRunning
        self.privacy = privacy
        let (stream, continuation) = AsyncStream<Control>.makeStream()
        lifecycleEvents = continuation
        subscription = meeting.events.subscribe { [weak self] event in
            guard let self else { return }
            if case let .started(_, _, _, mode) = event {
                ownsMeetingMode = mode.supportsSpeaking
                if !ownsMeetingMode {
                    if demoActive { continuation.yield(.endDemo) }
                    return
                }
            }
            guard ownsMeetingMode else { return }
            switch event {
            case .suspended: keys?.systemEvent(.sleep, at: HostClock.now())
            case .ended: keys?.systemEvent(.meetingModeEnded, at: HostClock.now())
            case .audioServiceRestarted(let at): keys?.systemEvent(.coreaudiodRestarted, at: at)
            default: break
            }
            if event.isLifecycle { continuation.yield(.meeting(event)) }
            if case .ended = event { ownsMeetingMode = false }
        }
        lifecycleTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .meeting(let event): await self?.handle(event)
                case let .phoneInputChanged(session, token):
                    guard let self, owner === session, session.mode == .phone, let pipeline,
                          phoneBoundary.isPendingReset(token: token), case .running = session.state else { continue }
                    await pipeline.phoneInputLost()
                    guard owner === session, self.pipeline === pipeline, case .running = session.state,
                          phoneBoundary.isPendingReset(token: token) else { continue }
                    await pipeline.resume()
                    guard owner === session, self.pipeline === pipeline, case .running = session.state,
                          phoneBoundary.completeReset(token: token) else { continue }
                    refreshFacts()
                case .configurationChanged:
                    guard let self else { continue }
                    let wasDemo = demoActive
                    if !wasDemo { guard let session = owner, case .running = session.state else { continue } }
                    await end()
                    await begin(demo: wasDemo)
                case .startDemo(let reply):
                    guard let self, !state.meetingActive, owner == nil, !demoActive else {
                        reply.resume(throwing: DemoFailure.meetingActive); continue
                    }
                    guard !selfTestRunning() else {
                        reply.resume(throwing: DemoFailure.reason(String(localized: "请先结束自检，再进行说话测试。"))); continue
                    }
                    await begin(demo: true)
                    if pipeline != nil { reply.resume() }
                    else { reply.resume(throwing: demoFailure.map(DemoFailure.reason) ?? .unavailable) }
                case .endDemo:
                    if self?.demoActive == true { await self?.end() }
                }
            }
        }
        systemInput.onFactsChange = { [weak self] in self?.refreshFacts() }
        systemInput.playGuardCue = { [weak self] in
            guard let self else { return false }
            return await self.output.monitor.playCue(.meetingMicAlert, dbfs: AppUIModels.shared.audio.cueDbfs)
        }
        output.setRouteSink { [weak self] in
            Task { @MainActor in
                self?.systemInput.route.refresh()
                self?.systemInput.retryGuardCue()
                self?.refreshFacts()
                self?.onMonitorAvailabilityChange?()
            }
        }
    }

    /// The launch record is taken over only while Feed exists. Give the existing settle timer
    /// its two seconds, explicitly refresh, then release the temporary attachment if still idle.
    func prepareLaunchTakeover() {
        Task { [weak self] in
            guard let self, await output.prepareLaunchTakeover() else { return }
            systemInput.switcher.beginLaunchTakeover()
            try? await Task.sleep(for: .milliseconds(2100))
            systemInput.switcher.refresh()
            await output.finishLaunchTakeover()
        }
    }

    private func handle(_ event: MeetingEvent) async {
        guard !closed else { return }
        switch event {
        case .started(_, _, _, let mode):
            guard mode.supportsSpeaking else { return }
            if demoActive { await end() }
            await begin()
        case .ended: await end()
        case .suspended:
            phoneBoundary.invalidate()
            keys?.suspend(at: HostClock.now())
            await pipeline?.suspend()
            mic?.setPassthroughCadence(false); mic?.setHot(false)
            reporter?.stop()
            await output.suspend()
            feedConfirmed = false
        case .resumed:
            await output.resume()
            await pipeline?.resume()
            if owner?.mode == .phone { phoneBoundary.invalidate() }
            mic?.refreshDevices()
            confirmFeed()
            refreshFacts()
            try? keys?.start()
            reporter?.start()
        case .audioServiceRestarted(let at):
            output.audioServiceRestarted(observedAt: at)
            mic?.refreshDevices(); feedConfirmed = false; refreshFacts()
        case .state, .hint, .translation: break
        }
    }

    private func begin(demo: Bool = false) async {
        guard !closed, owner == nil, !demoActive else { return }
        let session = demo ? nil : meeting.session
        guard demo || session?.mode.supportsSpeaking == true else { return }
        let log = session?.eventLog
            ?? (try? EventLog(sessionID: "demo-" + UUID().uuidString.lowercased()))
            ?? EventLog(inMemory: HostClock.now)
        sessionLog = log
        if demo { log.event("demo.start") }
        let echo: any SpeakEchoSink = session.map { $0 as any SpeakEchoSink } ?? DemoEcho()
        let jobs = session?.jobs ?? JobIDSequence()
        demoActive = demo
        demoReady = false; demoStopRequested = false; demoFailure = nil
        if demo { hud.meetingStarted() }
        generation &+= 1
        let token = generation
        let recorder = demo ? nil : privacy?.recorder
        let transcript = demo ? nil : privacy.map { TranscriptWriter(directory: $0.transcriptsDirectory) }
        self.transcript = transcript
        owner = session; warming = true; onChange?()
        phoneBoundary.invalidate()
        sessionTarget = state.speakLanguage.lang
        translationRefusal = nil
        output.monitor.setMeetingMode(true)
        onMonitorAvailabilityChange?()
        output.setLog(log)
        do {
            if demo {
                try checkDemoIsolation()
                let standalone = !state.meetingActive && !state.meetingStarting && !systemInput.switcher.isMeetingModeOn
                    && !systemInput.switcher.status.impliesRecord && systemInput.switcher.status != .otherInstanceManages
                demoMicPreference = AppUIModels.shared.audio.micUID
                guard let selected = demoMicrophone.begin(standaloneDemo: standalone, preferredMicUID: demoMicPreference) else {
                    throw DemoFailure.reason(String(localized: "独立试说需要可用的内建或有线麦克风，并且没有会议正在管理系统输入。"))
                }
                log.event("demo.mic_selected", ["transport": .tag(selected.transport)])
                lockObserver = DistributedNotificationCenter.default().addObserver(
                    forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopDemo(reason: String(localized: "屏幕已锁定，说话测试已停止。")) }
                }
                demoWorkspaceObservers = [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification].map { name in
                    NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.stopDemo(reason: String(localized: "系统已暂停，说话测试已停止。")) }
                    }
                }
                if let device = CoreAudioOutputRouteSource().defaultOutput(),
                   [.usb, .bluetooth, .bluetoothLE].contains(device.transport) {
                    HeadphoneAnswers.askIfNeeded(uid: device.uid, name: device.name)
                }
                output.monitor.setConfirmedHeadphones(HeadphoneAnswers.confirmed())
                output.monitor.setMeetingSpeakerMode(false)
                output.monitor.setUse(.selfListen, true)
                recoverDemoHeadphoneInput()
            }
            let queue = try await output.beginSession(config: .init(profile))
            clauseQueue = queue
            session?.setEchoReference(output.envelope)
            if demo {
                // No key listener exists yet: allow the monitor's serial worker to attach.
                for _ in 0..<60 {
                    try checkDemoIsolation()
                    recoverDemoHeadphoneInput()
                    if output.isFeedAttached && output.monitor.isSelfListenAudible { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard output.isFeedAttached, output.monitor.isSelfListenAudible else {
                    log.event("demo.output_not_ready", ["feed": .bool(output.isFeedAttached),
                        "monitor": .tag(Self.monitorTag(output.monitor.selfListen))])
                    throw DemoFailure.reason(demoOutputProblem())
                }
                feedConfirmed = true
                demoReady = true
            }
            if !demo { guard let session, case .running = session.state else { await end(); return } }
            let bridge = engineHost.speakBridge, links = self.links, output = self.output
            let audio = AppUIModels.shared.audio
            let micUID = microphoneUID(preference: audio.micUID)
            links.value.withLock {
                $0.micUID = micUID; $0.gainDb = audio.passthroughGainDb ?? 0; $0.cueDbfs = audio.cueDbfs
                $0.generation = token
            }
            let speechRate = (try? state.voiceStore.loadProfile())?.speakingRateCharsPerSecond
            let target = state.speakLanguage.lang
            let mic = try MicIngest(profile: profile.speak, target: target, charactersPerSecond: { speechRate },
                userUID: { links.value.withLock { $0.micUID } },
                onBlock: { block in
                    recorder?.appendMic(block.samples, host: block.hostTime, rate: block.sampleRate)
                    let (keys, gain) = links.value.withLock { ($0.keys, $0.gainDb) }
                    if let keys {
                        keys.gate.micStreamStarted(at: block.hostTime)
                        output.offer(block, gate: keys.gate, gainDb: gain)
                    }
                }, onVAD: { event in
                    let keys = links.value.withLock { $0.keys }
                    switch event {
                    case .began(let time): keys?.vad(speech: true, at: time)
                    case .ended(let time): keys?.vad(speech: false, at: time)
                    }
                }, onState: { [weak self] state in
                    log.event("speak.mic_state", ["capture": .tag(String(describing: state.capture)),
                        "physical": .bool(state.physicalMicPassesRule2)])
                    Task { @MainActor in
                        guard self?.generation == token else { return }
                        self?.refreshFacts()
                    }
                }, onSystemEvent: { event, at in
                    log.event("speak.system_event", ["reason": .tag(event.rawValue)], at: at)
                    links.value.withLock { $0.keys }?.systemEvent(event, at: at)
                })
            self.mic = mic; links.value.withLock { $0.mic = mic }
            var apple: (any MTEngine)?
            var prepareApple: @Sendable (MTSession) async throws -> Void = { _ in }
            if #available(macOS 26.4, *) {
                let mt = AppleTranslationMT()
                apple = mt; prepareApple = { try await mt.prepare($0) }
            }
            let gate = try TargetTextGate(config: profile.speak.mt.targetGate, patterns: GatePatterns.loadDefault())
            let cloud = demo ? ListenCloud.Box() : meeting.cloud.box
            if demo { _ = cloud.make(log: log) }
            let translator = FallbackMT(cloud: cloud.speak, apple: apple, profile: profile, gate: gate,
                                       glossary: { AppGlossary.store.snapshot() },
                                       prepareApple: prepareApple, log: log)
            let pipeline = SpeakPipeline(profile: profile, mic: mic, playout: output, queue: queue,
                primaryASR: SpeakEngineBridge.ASR(bridge: bridge), fallbackASR: AppleFinalizeASR(),
                translator: translator, voice: { bridge.snapshot() }, engine: bridge, echo: echo,
                previewASR: AppleSpeechASR(), target: state.speakLanguage.lang, jobs: jobs, log: log,
                speakerMode: { links.value.withLock { $0.speakerMode } },
                passthroughClosedAt: { links.value.withLock { $0.keys }?.lastCloseHostTime },
                captureFromKeyDown: !demo,
                ttsFailureReason: { error in
                    if case .stalled = error as? RemoteEngineError { return .stall }
                    return .streamBroken
                }, ui: { [weak self] event in Task { @MainActor in
                    guard self?.generation == token else { return }
                    self?.show(event)
                } }, onCommit: { links.value.withLock { $0.keys }?.pushToTalk.didCommit() },
                onWorkChange: { [weak self] busy in
                    // Route safety must not wait for the UI actor to consume its update.
                    let keys = links.value.withLock { $0.generation == token ? $0.keys : nil }
                    keys?.setTranslationBusy(busy, at: HostClock.now())
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.hud.setSpeechWorkPending(busy)
                        self.refreshMeetingAudio()
                    }
                },
                onTTSChunk: { chunk in recorder?.appendTTS(chunk.samples24k, host: chunk.producedAt, rate: 24_000) },
                onSpoken: { [weak self] source, target, at in Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if self.demoActive, self.demoReady, self.output.monitor.isSelfListenAudible { self.onDemoPlayed?() }
                    if self.privacy?.saveTranscripts == true { transcript?.append(direction: "speak", source: source, target: target, at: at) }
                } }, onDegradation: { [weak self] tier in Task { @MainActor in
                    guard self?.generation == token else { return }
                    await session?.setDraftsPaused(tier.pausesAppleDrafts)
                } },
                asrContext: {
                    // Source speech can name an English term even when the target is German.
                    // Give Qwen both spellings; target-language settings do not filter source hints.
                    var seen = Set<String>()
                    let terms = AppGlossary.store.snapshot().flatMap { [$0.zh, $0.en] }
                        .filter { !$0.isEmpty && seen.insert($0).inserted }
                    return terms.isEmpty ? nil : terms.joined(separator: ", ")
                })
            self.pipeline = pipeline
            if !demo {
                announcementEnabled = AppUIModels.shared.general.announcementEnabled
                await pipeline.configureAnnouncement(text: announcementText(), enabled: announcementEnabled == true)
            }
            let (actions, continuation) = AsyncStream<PushToTalkKey.Action>.makeStream()
            actionEvents = continuation
            let keys = PassthroughRuntime(profile: profile.speak, scope: demo ? .onboarding : .meeting,
                automaticOriginal: !demo,
                interaction: .toggle,
                sink: output.passthroughState, playout: pipeline, log: log,
                onPushToTalk: { continuation.yield($0) },
                onHUD: { [weak self] event in
                    switch event {
                    case .cancelled, .closed, .refused: links.value.withLock { $0.mic }?.setPassthroughCadence(false)
                    default: break
                    }
                    Task { @MainActor in
                        guard self?.generation == token else { return }
                        self?.hud.passthrough(event)
                    }
                }, onCue: { cue in
                    output.monitor.playCue(cue == .open ? .passthroughOpen : .passthroughClose,
                        dbfs: links.value.withLock { $0.cueDbfs }) { _ in }
                }, onStartMic: { links.value.withLock { $0.mic }?.setPassthroughCadence(true) },
                onOpenChange: { [weak self] open, at in
                    links.value.withLock { $0.mic }?.setPassthroughCadence(open)
                    if !demo { pipeline.setFloorPaused(open) }
                    if !open {
                        // The gate has already revoked ringP. Automatic original audio has no
                        // legacy key-release delay before handing the Feed writer back to TTS.
                        if !demo { queue.resumeNow(at: at) }
                    }
                    Task { @MainActor in
                        guard self?.generation == token else { return }
                        self?.passthroughChanged(open, at: at)
                    }
                })
            self.keys = keys; links.value.withLock { $0.keys = keys }
            await pipeline.setYieldHandler { [weak keys] time in keys?.gate.playoutYielded(at: time) }
            output.setSystemEventSink { [weak keys] event, at in keys?.systemEvent(event, at: at) }
            actionTask = Task { [weak self] in
                for await action in actions {
                    guard !Task.isCancelled else { break }
                    switch action {
                    case .machine(let event):
                        if case .began = event { self?.translationRefusal = nil }
                        self?.refreshMeetingAudio()
                        switch event {
                        case .began(let at): log.event("key.down", at: at)
                        case .released(let at, let reason):
                            log.event("key.up", ["reason": .tag(String(describing: reason))], at: at)
                        case .cancelled(let at):
                            log.event("key.cancelled", at: at)
                            if self?.demoActive == true { self?.onDemoStatus?(String(localized: "本次按键已取消，尚未完成收音。")) }
                        case .tapped(let at): log.event("key.tap", at: at)
                        case .doubleTapped(let at): log.event("key.double_tap", at: at)
                        }
                        if case .began(let at) = event, let self { await applyFloor(floor.newPress(at: at), at: at) }
                        if case .doubleTapped = event, let self {
                            floor = FloorManager(config: profile.speak.floor)
                            pipeline.setFloorPaused(false)
                            hud.clear(.floorPaused(segments: 0))
                        }
                        await pipeline.handle(event) { busy in
                            keys.actionHandled(translationBusy: busy, at: HostClock.now())
                        }
                        self?.refreshMeetingAudio()
                    case .refused(let at, let reason):
                        log.event("key.refused", ["reason": .tag(String(describing: reason))], at: at)
                        if self?.demoActive == true { self?.onDemoStatus?(Self.pressRefusal(reason)) }
                        else {
                            self?.translationRefusal = Self.pressRefusal(reason)
                            self?.refreshMeetingAudio()
                            self?.systemInput.retryGuardCue()
                        }
                    }
                }
            }
            let reporter = PlayoutReporter(source: { queue.report(at: HostClock.now()) },
                drainable: { queue.drainableMs }, onDrainable: { bridge.noteDrainable($0) },
                sink: { await bridge.report($0) })
            self.reporter = reporter
            await bridge.process?.setMeetingMode(true)
            Task { _ = try? await bridge.process?.start() }
            await pipeline.start()
            mic.refreshDevices()
            confirmFeed(); refreshFacts()
            try keys.start()
            reporter.start()
            watcher.startTimed { [weak self, weak keys] event, at in
                switch event {
                case .defaultInputChanged: keys?.systemEvent(.defaultInputChanged, at: at)
                case .defaultOutputChanged, .deviceSampleRateChanged:
                    keys?.systemEvent(.outputDeviceChanged, at: at)
                case .deviceFormatChanged(let uid):
                    keys?.systemEvent(uid == output.monitor.device?.uid ? .monitorFormatChanged : .outputDeviceChanged, at: at)
                case .deviceDied: keys?.systemEvent(.talkTalkMicGone, at: at)
                case .willSleep, .sessionResigned: keys?.systemEvent(.sleep, at: at)
                default: break
                }
                Task { @MainActor in
                    if demo, event == .willSleep || event == .sessionResigned {
                        self?.stopDemo(reason: String(localized: "系统已暂停，说话测试已停止。"))
                    } else { self?.devicesChanged(event) }
                }
            }
            watching = true
            devicesChanged(.processListChanged)
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { break }
                    confirmFeed(); refreshFacts()
                    // Independent from ASR/text refreshes; original audio also needs immediate
                    // visual capture feedback even though it does not create a transcript.
                    hud.inputActivity(mic.inputLevel())
                    await updateFloorAndLoad(token: token)
                    if !restartQueued, sessionTarget != state.speakLanguage.lang {
                        restartQueued = true
                        keys.systemEvent(.meetingModeEnded, at: HostClock.now())
                        lifecycleEvents?.yield(.configurationChanged)
                    }
                }
            }
        } catch {
            if demo { demoFailure = error.localizedDescription }
            await end()
            if !demo { meeting.phoneSpeechFailed(session) }
            hud.show(String(localized: "说话链路未能启动，请检查组件和输入监控权限。"), .yellow,
                     label: titlebarLabel("说话链路未能启动"))
        }
        warming = false; onChange?()
    }

    private func confirmFeed() {
        if demoActive { feedConfirmed = output.isFeedAttached; return }
        guard !feedConfirmed, output.isFeedAttached, let owner, case .running = owner.state else { return }
        feedConfirmed = true; systemInput.feedBecameReady()
    }

    func refreshFacts() {
        let audio = AppUIModels.shared.audio
        let running: Bool
        if let owner, case .running = owner.state { running = true } else { running = false }
        var speaker = state.meetingActive && !demoActive ? systemInput.route.state.speakerMode : false
        if owner?.mode == .phone, systemInput.micGuard.state.verdict == .noReader, speaker == nil {
            // Before Phone supplies an output route, self-listen uses the actual local output.
            // This does not replace the real route facts consumed by the original-audio gate.
            speaker = OutputRouteClassifier.isSpeakerMode(
                meetingOutputs: systemInput.route.state.defaultOutput.map { [$0] },
                monitor: audio.monitor ? output.monitor.device : nil,
                confirmedHeadphones: HeadphoneAnswers.confirmed())
        }
        let outputs = systemInput.route.state.meetingOutputs.map { Set($0.map(\.uid)) }
        if outputs != meetingOutputUIDs {
            // A meeting can switch between two headphones without changing speakerMode.
            // The old raw-mic grant must still close before accepting the new route.
            keys?.systemEvent(.outputDeviceChanged, at: HostClock.now())
            meetingOutputUIDs = outputs
            watchOutputDevices()
        }
        let micUID = microphoneUID(preference: audio.micUID)
        links.value.withLock { $0.speakerMode = speaker ?? true; $0.micUID = micUID; $0.gainDb = audio.passthroughGainDb ?? 0; $0.cueDbfs = audio.cueDbfs }
        output.monitor.setUse(.cues, state.meetingActive && audio.cuesEnabled)
        output.monitor.setUse(.selfListen, demoActive || (state.meetingActive && audio.monitor))
        output.monitor.setMeetingSpeakerMode(speaker)
        output.monitor.setConfirmedHeadphones(HeadphoneAnswers.confirmed())
        guard let mic, let keys else { return }
        if lastMicUID != micUID { lastMicUID = micUID; mic.refreshDevices() }
        if demoActive {
            // A demo has no SystemInputController confirmation handshake. Read actual readiness
            // here so a queued route callback cannot mistake the initial false cache for a loss.
            feedConfirmed = output.isFeedAttached
            let isolated = (try? checkDemoIsolation()) != nil
            let ready = demoReady && feedConfirmed && output.monitor.isSelfListenAudible && isolated
            if demoReady, !ready {
                sessionLog?.event("demo.readiness_lost", ["feed": .bool(feedConfirmed),
                    "monitor": .tag(Self.monitorTag(output.monitor.selfListen)), "isolated": .bool(isolated)])
                stopDemo(reason: isolated ? demoOutputProblem() : String(localized: "检测到通话或其他麦克风测试，请先结束后重试。"))
            }
            keys.updateFacts(at: HostClock.now()) {
                $0.meetingModeActive = false
                $0.settingEnabled = false
                $0.awaitingAudioConfirmation = !ready
                $0.physicalMicPassesRule2 = mic.state.physicalMicPassesRule2
                $0.selfTestRunning = selfTestRunning()
                $0.speakerMode = false
            }
            mic.setHot(false)
            hud.meetingAudio(nil)
            hud.setPushToTalkAvailable(ready && mic.state.physicalMicPassesRule2)
            return
        }
        guard let owner else { return }
        let pendingVoice = engineHost.routing.source == .myVoicePending
        if warming != pendingVoice { warming = pendingVoice; onChange?() }
        let existing = keys.gate.facts
        if owner.mode == .phone {
            let reader: Bool?
            switch systemInput.micGuard.state.verdict {
            case .green?, .physicalMic?: reader = true
            case .noReader?: reader = false
            case nil: reader = nil
            }
            if let token = phoneBoundary.observe(reader: reader) {
                // Clear pre-call/previous-call speech, then resume local speaking without
                // making a new reader a prerequisite. A newer boundary owns its own barrier.
                keys.systemEvent(.meetingModeEnded, at: HostClock.now())
                mic.setHot(false)
                lifecycleEvents?.yield(.phoneInputChanged(owner, token))
            }
        }
        let inputReady: Bool
        if case .holding = systemInput.switcher.status { inputReady = true }
        else { inputReady = systemInput.micGuard.state.verified }
        let localPhoneReady = owner.mode == .phone && running && output.isFeedAttached
            && feedConfirmed && pipeline != nil && inputReady && !phoneBoundary.resetPending
        let facts = SpeakFacts(meetingState: owner.state, micGuard: systemInput.micGuard.state,
            route: systemInput.route.state, passthroughEnabled: true,
            mode: owner.mode, phoneLocalReady: localPhoneReady,
            physicalMicPassesRule2: mic.state.physicalMicPassesRule2, tapHealthy: existing.tapHealthy,
            secureInput: existing.secureInput, pushToTalkActive: existing.pushToTalkActive, selfTestRunning: selfTestRunning())
        if owner.mode == .phone {
            let ready = running && output.isFeedAttached && feedConfirmed && pipeline != nil
                && facts.pushToTalkAvailable && mic.state.capture == .open
                && !pendingVoice && inputReady && !phoneBoundary.resetPending
            let detail: String?
            if case .physicalMic = systemInput.micGuard.state.verdict {
                detail = String(localized: "请在 Phone 的“音频 › 麦克风”选择“使用系统设置”或 TalkTalk Mic。")
            } else if feedConfirmed, !inputReady {
                detail = String(localized: "请开启自动接入系统输入，或在 Phone 的“音频 › 麦克风”选择 TalkTalk Mic。")
            } else if speaker == true {
                detail = String(localized: "请使用耳机；外放时，原声发送会受回声保护限制。")
            } else if state.phoneAudioActive, speaker == nil {
                detail = String(localized: "电话音频已接入，正在确认通话输出设备…")
            } else { detail = nil }
            meeting.updatePhoneReadiness(ready, detail: detail)
        }
        keys.updateFacts(at: HostClock.now(), phoneLocalSpeechReady: facts.allowsPhoneLocalSpeech) {
            $0 = facts.passthrough
            if !output.isFeedAttached || !feedConfirmed { $0.awaitingAudioConfirmation = true }
            if owner.mode == .phone, phoneBoundary.resetPending { $0.meetingModeActive = false }
        }
        keys.gate.setMicWarm(mic.state.capture == .open)
        keys.gate.setCueAudible(output.monitor.cuesAudible)
        // Default original audio owns capture throughout a healthy meeting, including PTT and
        // its translation tail. The old optional pre-roll setting cannot close this microphone.
        let phoneAllowsSpeech = owner.mode != .phone || !phoneBoundary.resetPending
        mic.setHot(running && facts.pushToTalkAvailable && output.isFeedAttached && feedConfirmed && phoneAllowsSpeech)
        hud.setPushToTalkAvailable(facts.pushToTalkAvailable && output.isFeedAttached && feedConfirmed && phoneAllowsSpeech)
        let waitingForPhone = owner.mode == .phone && state.phoneReadyToDial
            && systemInput.micGuard.state.verdict == .noReader
        if speaker != false && !waitingForPhone { hud.post(.speakerMode) } else { hud.clear(.speakerMode) }
        refreshMeetingAudio()
    }

    private func devicesChanged(_ event: DeviceWatcher.Event) {
        if case .devicesChanged = event { mic?.refreshDevices(); output.devicesChanged() }
        let devices = AudioDeviceCatalog.devices()
        if !devices.contains(where: { $0.uid == MicPolicy.talkTalkMicUID }) {
            keys?.systemEvent(.talkTalkMicGone, at: HostClock.now()); feedConfirmed = false
        }
        watchOutputDevices()
        refreshFacts()
    }

    private func watchOutputDevices() {
        guard watching else { return }
        let route = systemInput.route.state
        let uids = Set((route.meetingOutputs ?? []).map(\.uid) + [route.defaultOutput?.uid, output.monitor.device?.uid].compactMap { $0 })
        for uid in uids.subtracting(observedUIDs) { watcher.watch(deviceUID: uid) }
        for uid in observedUIDs.subtracting(uids) { watcher.unwatch(deviceUID: uid) }
        observedUIDs = uids
    }

    private func passthroughChanged(_ open: Bool, at: HostTime) {
        passthroughOpen = keys?.gate.isOpen(at: HostClock.now()) == true
        if passthroughOpen { floor.passthroughOpened() }
        else { floor = FloorManager(config: profile.speak.floor) }
        if open {
            passthroughStart = at
            // LISTEN needs the live interval, not only the completed interval at key-down.
            if let owner { Task { await owner.recordPassthrough(startHost: at, endHost: at) } }
        }
        else if let start = passthroughStart, let owner {
            passthroughStart = nil
            Task { await owner.recordPassthrough(startHost: start, endHost: at) }
        }
        refreshMeetingAudio()
        onChange?()
    }

    private func refreshMeetingAudio() {
        guard !demoActive, let owner, let keys else { hud.meetingAudio(nil); return }
        guard case .running = owner.state else {
            hud.meetingAudio(.unavailable(reason: String(localized: "音频已暂停"))); return
        }
        // A Phone reader change cancels current speech; its cleanup barrier is not a fault.
        if owner.mode == .phone, phoneBoundary.resetPending {
            hud.meetingAudio(.phoneReconnecting); return
        }
        // Key handling closes raw audio synchronously, while UI callbacks arrive later. Read
        // the key, work and gate facts together instead of mixing two sides of a transition.
        let audio = keys.meetingAudioSnapshot()
        if audio.held == false { translationRefusal = nil }
        guard output.isFeedAttached, feedConfirmed, mic?.state.capture == .open else {
            hud.meetingAudio(.unavailable(reason: String(localized: "正在等待音频就绪"))); return
        }
        guard audio.hardwarePollFresh, audio.held != nil else {
            hud.meetingAudio(.unavailable(reason: String(localized: "正在等待按键监听恢复"))); return
        }
        if case let .unavailable(reason) = audio.translationReadiness {
            hud.meetingAudio(.unavailable(reason: reason.hudText ?? String(localized: "正在等待音频就绪")))
        } else if let reason = translationRefusal, audio.held == true {
            hud.meetingAudio(.unavailable(reason: reason))
        } else if audio.originalOpen {
            hud.meetingAudio(.original)
        } else if audio.recordingActive {
            hud.meetingAudio(.translating)
        } else if audio.held == true {
            hud.meetingAudio(.switching)
        } else if audio.busy {
            hud.meetingAudio(.draining)
        } else if owner.mode == .phone, state.phoneReadyToDial,
                  systemInput.micGuard.state.verdict == .noReader {
            hud.meetingAudio(.phoneReady)
        } else if audio.canRestoreOriginal {
            // Healthy and drained, but the next hardware poll still owns opening the gate.
            // This is normal progress, never a claim that raw audio is already flowing.
            hud.meetingAudio(.restoringOriginal)
        } else if case let .unavailable(reason) = audio.originalReadiness {
            hud.meetingAudio(.unavailable(reason: reason.hudText ?? String(localized: "正在等待音频就绪")))
        } else {
            hud.meetingAudio(.unavailable(reason: String(localized: "正在等待音频就绪")))
        }
    }

    private func show(_ event: SpeakUIEvent) {
        guard owner != nil || demoActive else { return }
        switch event {
        case .transcript(let transcript): hud.transcript(transcript)
        case .outputActivity(let playing): hud.setOutputPlaying(playing)
        case .pushToTalk(let p):
            hud.pushToTalk(p)
            if demoActive {
                switch p {
                case .holding: onDemoStatus?(String(localized: "翻译收音中，再按右⌥结束。"))
                case .idle: break
                default: break
                }
            }
            if case .idle = p { speaking = false } else { speaking = true }
            if case .playing(_, _, let backend, _) = p {
                degraded = backend == .apple
                if degraded, meeting.cloud.box.speak != nil { hud.post(.openAIUnreachable) }
                else { hud.clear(.openAIUnreachable) }
            }
        case .post(let warning):
            hud.post(warning)
            if demoActive { onDemoStatus?(warning.text) }
        case .clear(let warning): hud.clear(warning)
        case .pttAvailable(let available): hud.setPushToTalkAvailable(available)
        }
        onChange?()
    }

    private func end() async {
        if owner?.mode == .phone { meeting.updatePhoneReadiness(false) }
        let wasDemo = demoActive
        demoReady = false
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver); self.lockObserver = nil }
        demoWorkspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        demoWorkspaceObservers.removeAll()
        generation &+= 1
        keys?.stop(); actionEvents?.finish(); actionTask?.cancel()
        if let start = passthroughStart, let owner {
            passthroughStart = nil
            await owner.recordPassthrough(startHost: start, endHost: HostClock.now())
        }
        meterTask?.cancel(); meterTask = nil
        hud.inputActivity(nil)
        watcher.stop(); watching = false; observedUIDs.removeAll(); meetingOutputUIDs = nil
        await pipeline?.stop()
        await owner?.setDraftsPaused(false)
        if let stats = mic?.stats {
            sessionLog?.event("speak.capture_end", ["blocks": .int(stats.blocks), "frames16k": .int(stats.frames16k),
                "onsets": .int(stats.onsets), "dropped_blocks": .int(stats.droppedBlocks), "rate": .double(stats.deviceRate)])
        }
        if wasDemo { sessionLog?.event("demo.stop") }
        mic?.stop(); reporter?.stop()
        await output.endSession()
        output.monitor.setMeetingMode(false)
        onMonitorAvailabilityChange?()
        output.monitor.setUse(.cues, false); output.monitor.setUse(.selfListen, false)
        if wasDemo {
            let monitor = output.monitor
            await Task.detached { monitor.suspend() }.value
            let restored = demoMicrophone.end()
            sessionLog?.event("demo.input_restore", ["restored": .bool(restored)])
            monitor.resume()
        }
        demoMicPreference = nil
        sessionLog?.flush(); sessionLog = nil
        await engineHost.speakBridge.process?.setMeetingMode(false)
        links.value.withLock { $0.keys = nil; $0.mic = nil }
        pipeline = nil; mic = nil; keys = nil; reporter = nil; owner = nil; demoActive = false
        clauseQueue = nil
        floor = FloorManager(config: profile.speak.floor)
        remoteSpeech = RemoteSpeechDetector(config: profile.speak.floor)
        transcript?.finish(); transcript = nil
        actionEvents = nil; actionTask = nil; feedConfirmed = false
        phoneBoundary.invalidate()
        sessionTarget = nil; restartQueued = false; announcementEnabled = nil
        speaking = false; passthroughOpen = false; degraded = false; warming = false
        translationRefusal = nil; hud.meetingAudio(nil)
        hud.setPushToTalkAvailable(false); onChange?()
        if wasDemo, !state.meetingActive { hud.meetingEnded() }
    }

    func shutdown() async {
        closed = true
        subscription?.cancel(); lifecycleEvents?.finish(); lifecycleTask?.cancel()
        await end(); await output.close()
    }

    func beginOnboardingDemo() async throws {
        guard !closed, let lifecycleEvents else { throw DemoFailure.unavailable }
        try await withCheckedThrowingContinuation { lifecycleEvents.yield(.startDemo($0)) }
    }
    func endOnboardingDemo() {
        if demoActive { keys?.systemEvent(.meetingModeEnded, at: HostClock.now()) }
        lifecycleEvents?.yield(.endDemo)
    }

    var canPlayAnnouncement: Bool {
        guard let owner, case .running = owner.state else { return false }
        return !demoActive && output.isFeedAttached
    }
    func playAnnouncement() { guard canPlayAnnouncement else { return }; Task { await pipeline?.playAnnouncement() } }

    private func announcementText() -> String {
        let prefs = TranslationPreferences.load(.standard)
        let cloud = prefs.cloudConsentGiven && (prefs.listenCloudEnabled || prefs.speakCloudEnabled)
        if state.speakLanguage.lang == .de {
            return "Ich nutze maschinelle Live-Übersetzung und eine synthetische Stimme."
                + (cloud ? " Gesprochene Inhalte werden als Text zur Übersetzung an OpenAI gesendet." : "")
        }
        return "I'm using live machine interpretation and a synthesized voice."
            + (cloud ? " Spoken content is sent as text to OpenAI for translation." : "")
    }

    private func updateFloorAndLoad(token: UInt64) async {
        guard let pipeline, generation == token else { return }
        if !demoActive, announcementEnabled != AppUIModels.shared.general.announcementEnabled {
            announcementEnabled = AppUIModels.shared.general.announcementEnabled
            await pipeline.configureAnnouncement(text: announcementText(), enabled: announcementEnabled == true)
        }
        let thermal = ProcessInfo.processInfo.thermalState
        await pipeline.updateLoad(thermalSerious: thermal == .serious || thermal == .critical,
                                  lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard let owner, case .running = owner.state, let queue = clauseQueue else { return }
        let now = HostClock.now()
        if let start = passthroughStart, keys?.gate.isOpen(at: now) == true {
            await owner.recordPassthrough(startHost: start, endHost: now)
        }
        let remote = await owner.remoteSpeechSnapshot(at: now)
        guard generation == token, let vad = remote.vadSpeech, let energy = remote.energyDb else { return }
        let observation = remoteSpeech.observe(vadSpeech: vad, energyDb: energy, echoScore: remote.echoScore,
            volatileText: remote.volatileText, playingText: queue.currentPlayingText ?? "", at: now)
        // The gate owns its initial yield; only it may open raw passthrough.
        if keys?.gate.isEngaged == true, !passthroughOpen { return }
        let actions = floor.observe(remoteSpeaking: observation.speaking, remoteSilenceMs: observation.silenceMs,
            isPlaying: queue.clauseCount > 0, atBoundary: queue.isAtBoundary, at: now)
        await applyFloor(actions, at: now)
    }

    private func applyFloor(_ actions: [FloorManager.Action], at: HostTime) async {
        guard let pipeline else { return }
        for action in actions {
            switch action {
            case .finishCurrent, .pause: pipeline.setFloorPaused(true)
            case .cutAndPause: pipeline.cutForFloor(at: at)
            case .resume: pipeline.setFloorPaused(false); hud.clear(.floorPaused(segments: 0))
            case .offerClear: break
            case .passthroughReady: keys?.gate.playoutYielded(at: at)
            }
            if action != .resume, action != .passthroughReady {
                hud.post(.floorPaused(segments: await pipeline.queuedSegments))
            }
        }
    }

    private func checkDemoIsolation() throws {
        if demoStopRequested { throw DemoFailure.reason(demoFailure ?? String(localized: "说话测试已停止。")) }
        let hal = CoreAudioDriverHAL()
        guard let mic = hal.device(uid: DriverIdentity.micUID), mic.isAlive,
              !mic.isRunningSomewhere, hal.meetingMode() == false else {
            throw DemoFailure.reason(String(localized: "请先结束通话或其他 App 的麦克风测试，再进行说话测试。"))
        }
    }

    private func microphoneUID(preference: String?) -> String? {
        // Keep the temporary demo choice out of stored preferences. A settings change during
        // the demo is explicit and takes precedence; ordinary meeting capture keeps MicPolicy.
        if demoActive, preference == demoMicPreference { return demoMicrophone.selectedMicrophone?.uid ?? preference }
        return preference
    }

    private func recoverDemoHeadphoneInput() {
        // In particular, never replace TalkTalk Mic while a meeting is starting or running.
        guard demoActive, owner == nil, !state.meetingActive, !state.meetingStarting, !systemInput.switcher.isMeetingModeOn,
              !systemInput.switcher.status.impliesRecord, systemInput.switcher.status != .otherInstanceManages,
              let device = AudioDeviceCatalog.defaultOutput(),
              demoMicrophone.recoverBluetoothOutput(transport: device.transport, sampleRate: device.nominalSampleRate) else { return }
        sessionLog?.event("demo.input_selected", ["previous_output_rate": .double(device.nominalSampleRate)])
        onDemoStatus?(String(localized: "已自动使用内建或有线麦克风，正在等待耳机恢复播放。试说结束后会恢复原输入。"))
    }

    private static func pressRefusal(_ reason: PushToTalkKey.BlockReason) -> String {
        switch reason {
        case .secureInput: String(localized: "安全输入正在阻止按键监听。请离开密码输入框后重试。")
        case .awaitingAudioConfirmation: String(localized: "按键监听或音频尚未就绪，请检查输入监控权限和耳机。")
        case .noMeetingReader: String(localized: "没有可用的实体麦克风，请在设置 › 音频中检查。")
        case .meetingUsesPhysicalMic: String(localized: "会议 App 正在使用实体麦克风。")
        case .notInSession: String(localized: "说话测试尚未启动。")
        }
    }

    private static func monitorTag(_ state: MonitorOutput.SelfListen) -> String {
        switch state {
        case .audible: "audible"
        case .off: "off"
        case .noOutput: "no_output"
        case .notHeadphones: "not_headphones"
        case .meetingSpeaker: "meeting_speaker"
        case .sampleRate: "sample_rate"
        }
    }
    private func demoOutputProblem() -> String {
        guard output.isFeedAttached else {
            return String(localized: "虚拟麦克风输出没有连接：\(output.lastFailure ?? "Feed unavailable")")
        }
        switch output.monitor.selfListen {
        case .audible: return String(localized: "输出状态已变化，请重新开始说话测试。")
        case .off: return String(localized: "自听尚未启用，请重新开始说话测试。")
        case .noOutput: return String(localized: "自听输出没有连接：\(output.monitor.stats.lastFailure ?? "No output")")
        case .notHeadphones: return String(localized: "请在设置 › 音频中确认当前输出是耳机。")
        case .meetingSpeaker: return String(localized: "自听被外放状态停用，请检查会议输出。")
        case .sampleRate(let rate): return String(localized: "耳机当前采样率为 \(Int(rate)) Hz，自听需要 48000 Hz。请关闭其他 App 对蓝牙麦克风的使用后重试。")
        }
    }

    private func stopDemo(reason: String) {
        guard demoActive, !demoStopRequested else { return }
        demoReady = false; demoStopRequested = true; demoFailure = reason
        keys?.systemEvent(.meetingModeEnded, at: HostClock.now())
        lifecycleEvents?.yield(.endDemo)
        onDemoFailure?(reason)
    }

    private struct DemoEcho: SpeakEchoSink {
        func recordPlayed(text: String, startHost: HostTime, endHost: HostTime) async {}
        func recordPassthrough(startHost: HostTime, endHost: HostTime) async {}
        func recentRemoteText(withinS: Double) async -> [String] { [] }
        func remoteVADOverlap(from: HostTime, to: HostTime) async -> Double? { nil }
    }
}
