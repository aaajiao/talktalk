// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import CoreAudio
import Foundation
import TalkTalkApple
import TalkTalkAudio
import TalkTalkCore

/// Meeting mode, LISTEN half (ARCHITECTURE.md §3.1, §3.6, §6.3). Owns the meeting source, the
/// include tap (only the meeting's process objects; global capture requires explicit opt-in), the TCC probe at start, the all-zero watchdog, rebuilds on device / process / service
/// changes, auto end and sleep / lock suspend. Subtitles come out through `onSubtitle`; state,
/// hints and lifecycle (start, end, sleep / wake, coreaudiod restart) through `events`, a hub
/// that outlives the session (MeetingEvents).
@MainActor
public final class MeetingSession: SpeakEchoSink {
    public enum State: Sendable, Equatable {
        case idle
        case starting
        case running(app: String)
        case suspended(app: String)
        case ended(EndReason)
    }

    public enum EndReason: String, Sendable, Equatable { case user, autoEnd, afterSleep, failed }

    public enum StartResult: Sendable, Equatable {
        case started(app: String)
        /// No known meeting app has a Core Audio process object.
        case noMeetingApp
        /// Several meeting apps are in a call: the user picks one (menu › 会议来源).
        case needsChoice([String])
        /// System audio recording is not allowed (System Settings › Privacy & Security ›
        /// Screen & System Audio Recording).
        case tccDenied
        /// The locale's speech assets are not installed (the UI offers the system download).
        case speechAssetsMissing(Lang)
        /// Speech recognition permission was denied.
        case speechNotAuthorized
        case failed(String)
    }

    /// HUD hints (§11 PTT HUD warnings that belong to LISTEN).
    public enum Hint: String, Sendable, Equatable {
        case meetingSilent = "所选应用当前没有声音" // l10n-ignore
        case audioRestarting = "音频系统重启中" // l10n-ignore
        case meetingSeemsOver = "应用长时间没有声音" // l10n-ignore
        case tccUnconfirmed = "没能确认系统录音权限" // l10n-ignore

        /// Display text is localized independently of the stable event identifiers above.
        public var localizedDescription: String {
            switch self {
            case .meetingSilent: String(appLocalized: "所选应用当前没有声音")
            case .audioRestarting: String(appLocalized: "音频系统重启中")
            case .meetingSeemsOver: String(appLocalized: "应用长时间没有声音")
            case .tccUnconfirmed: String(appLocalized: "没能确认系统录音权限")
            }
        }
    }

    /// Builds the meeting's engines; gets the meeting's EventLog (the cloud MT logs into it).
    public typealias EngineFactory = @Sendable (Direction, EventLog, UInt64) async -> ListenPipeline.Engines

    public private(set) var state: State = .idle
    public private(set) var app: MeetingApp?
    public private(set) var startedAt: Date?
    public private(set) var listenLanguage: Lang?
    public private(set) var listenTarget: Lang?
    /// Factory callbacks must carry this value; it changes before old work is cancelled.
    public private(set) var listenConfigurationID: UInt64 = 0
    public let mode: MeetingMode
    public let events: MeetingEvents
    public let onSubtitle: @MainActor @Sendable (SubtitleUpdate) -> Void
    /// Observed Phone microphone activity, not a telephony connection/hangup notification.
    /// Output alone (a ringtone or voicemail playback) must not claim a live call.
    public private(set) var phoneAudioActive = false
    public var onPhoneAudioActivity: (@MainActor @Sendable (Bool) -> Void)?
    private var phoneAudioReported = false

    private let profile: PolicyProfile
    private let onRemoteAudio: @Sendable ([Float], HostTime) -> Void
    private let onTranscript: @MainActor @Sendable (String, String, HostTime) -> Void
    private let onAnalysis: (@MainActor @Sendable (ListenAnalysisEvent, UInt64) -> Void)?
    private let onListenFailure: @MainActor @Sendable (Lang, String) -> Void
    private let onListenReset: @MainActor @Sendable () -> Void
    private let glossary: @Sendable () -> [GlossaryEntry]
    private let makeEngines: EngineFactory
    public let jobs: JobIDSequence
    private let resolver = MeetingSourceResolver()
    private let watcher = DeviceWatcher()
    private var pipeline: ListenPipeline?
    private var ingest = AudioIngest()
    private var requestedListenLanguage: Lang?
    private var requestedListenTarget: Lang = .zh
    private var listenTask: Task<Void, Error>?
    private var listenTaskConfigurationID: UInt64?
    private var sessionGeneration: UInt64 = 0
    private var stopping = false
    private enum EchoRecord: Sendable {
        case played(String, HostTime, HostTime), passthrough(HostTime, HostTime)
        var end: HostTime { switch self { case .played(_, _, let end), .passthrough(_, let end): end } }
        func replay(to pipeline: ListenPipeline) async {
            switch self {
            case let .played(text, start, end): await pipeline.recordPlayed(text: text, startHost: start, endHost: end)
            case let .passthrough(start, end): await pipeline.recordPassthrough(startHost: start, endHost: end)
            }
        }
    }
    private var echoRecords: [EchoRecord] = []
    private var tap: MeetingTap?
    private var echoReference: EnvelopeHistory?
    private var draftsPaused = false
    private var appleForThisMeeting = false
    private let echoWorker = MeetingEchoWorker()
    private var echoTask: Task<Void, Never>?
    public private(set) var usesGlobalFallback = false
    public static var globalFallbackWarning: String { String(appLocalized: "将采集所有应用的声音（排除 TalkTalk、readread 及其子进程）；其他应用的声音也可能被转写。仅在会议来源采集失败时使用。") }
    private var processes: [AudioObjectID] = []
    private var log: EventLog?
    private var timer: Timer?
    private var noticeTask: Task<Void, Never>?
    private var watchdog = TapWatchdog()
    private var autoEnd = MeetingAutoEnd()
    private var lifecycle = MeetingLifecycle()
    private var activity: NSObjectProtocol?
    private var lockObservers: [NSObjectProtocol] = []
    private var startHost: HostTime = 0
    private var hint: Hint?
    /// The one stop in progress: later callers (auto end racing the user, a stop after sleep)
    /// await it instead of ending a second time.
    private var stopTask: Task<Void, Never>?

    public init(profile: PolicyProfile, mode: MeetingMode = .meeting, makeEngines: @escaping EngineFactory, events: MeetingEvents = MeetingEvents(),
                jobs: JobIDSequence = JobIDSequence(),
                onRemoteAudio: @escaping @Sendable ([Float], HostTime) -> Void = { _, _ in },
                onTranscript: @escaping @MainActor @Sendable (String, String, HostTime) -> Void = { _, _, _ in },
                onAnalysis: (@MainActor @Sendable (ListenAnalysisEvent, UInt64) -> Void)? = nil,
                glossary: @escaping @Sendable () -> [GlossaryEntry] = { [] },
                onListenFailure: @escaping @MainActor @Sendable (Lang, String) -> Void = { _, _ in },
                onListenReset: @escaping @MainActor @Sendable () -> Void = {},
                onSubtitle: @escaping @MainActor @Sendable (SubtitleUpdate) -> Void) {
        self.profile = profile
        self.mode = mode
        self.glossary = glossary
        self.onRemoteAudio = onRemoteAudio
        self.onTranscript = onTranscript
        self.onAnalysis = onAnalysis
        self.onListenReset = onListenReset
        self.onListenFailure = onListenFailure
        self.events = events
        self.makeEngines = makeEngines
        self.jobs = jobs
        self.onSubtitle = onSubtitle
    }

    var nowMs: Int { HostClock.ms(startHost, to: HostClock.now()) }

    /// The active meeting's log; SPEAK uses the same session rather than creating a second one.
    public var eventLog: EventLog? { log }

    public func recordPlayed(text: String, startHost: HostTime, endHost: HostTime) async {
        echoRecords.append(.played(text, startHost, endHost)); pruneEchoRecords()
        await pipeline?.recordPlayed(text: text, startHost: startHost, endHost: endHost)
    }

    public func recordPassthrough(startHost: HostTime, endHost: HostTime) async {
        guard endHost >= startHost else { return }
        if let last = echoRecords.last, case let .passthrough(start, end) = last,
           startHost <= end, endHost >= start {
            echoRecords[echoRecords.count - 1] = .passthrough(min(start, startHost), max(end, endHost))
        } else { echoRecords.append(.passthrough(startHost, endHost)) }
        pruneEchoRecords()
        await pipeline?.recordPassthrough(startHost: startHost, endHost: endHost)
    }

    private func pruneEchoRecords() {
        let now = HostClock.now(), window = UInt64(profile.listen.echoFilter.windowS + profile.listen.echoFilter.afterPlayS) * 1_000_000_000
        echoRecords.removeAll { now >= $0.end && now - $0.end > window }
    }

    public enum ListenConfigurationError: Error, Sendable { case unsupportedDirection }

    /// Compatibility entry point for callers that only change the source.
    public func switchListenLanguage(to lang: Lang, forceRebuild: Bool = false) async throws {
        try await switchListenDirection(source: lang, target: requestedListenTarget, forceRebuild: forceRebuild)
    }

    /// Changes only LISTEN. No meeting lifecycle event is emitted. Pending starts and
    /// suspended sessions remember the complete pair; target-only changes also cancel old work.
    public func switchListenDirection(source lang: Lang, target: Lang, forceRebuild: Bool = false) async throws {
        try Task.checkCancellation()
        guard MTSession.listen(source: lang, target: target) != nil else { throw ListenConfigurationError.unsupportedDirection }
        guard !stopping else { throw CancellationError() }
        switch state { case .starting, .running, .suspended: break; default: throw CancellationError() }
        if requestedListenLanguage == lang, requestedListenTarget == target, !forceRebuild, pipeline != nil || listenTask != nil { return }
        requestedListenLanguage = lang; requestedListenTarget = target
        switch state {
        case .starting:
            // startFresh's loop follows the newest configuration after its current await.
            listenConfigurationID &+= 1; listenTask?.cancel(); onListenReset()
        case .suspended:
            try await replaceListenPipeline(open: false).value
        case .running:
            try await replaceListenPipeline(open: true).value
        default: throw CancellationError()
        }
    }

    private func acceptsListenCallbacks(_ configuration: UInt64) -> Bool {
        guard !stopping, listenConfigurationID == configuration else { return false }
        switch state { case .starting, .running: return true; default: return false }
    }

    /// All UI callbacks make exactly one MainActor hop, checked after the hop, so an already
    /// queued old-language subtitle cannot arrive after the board was reset.
    private func makePipeline(lang: Lang, target: Lang, engines: ListenPipeline.Engines, log: EventLog,
                              configuration: UInt64) -> ListenPipeline {
        let analysis: (@Sendable (ListenAnalysisEvent) -> Void)?
        if let callback = onAnalysis {
            analysis = { [weak self] observation in
                Task { @MainActor in
                    guard let self, self.acceptsListenCallbacks(configuration) else { return }
                    callback(observation, configuration)
                }
            }
        } else { analysis = nil }
        return ListenPipeline(lang: lang, target: target, profile: mode == .captions ? profile.listen.forVideoCaptions : profile.listen, engines: engines, log: log, ingest: ingest,
            jobs: jobs, onTranscript: { [weak self] source, target, at in
                Task { @MainActor in
                    guard let self, self.acceptsListenCallbacks(configuration) else { return }
                    self.onTranscript(source, target, at)
                }
            }, onAnalysis: analysis, glossary: glossary, onUpdate: { [weak self] update in
                Task { @MainActor in
                    guard let self, self.acceptsListenCallbacks(configuration) else { return }
                    self.onSubtitle(update)
                }
            }, onTranslation: { [weak self] translation in
                Task { @MainActor in
                    guard let self, self.acceptsListenCallbacks(configuration) else { return }
                    self.events.emit(.translation(translation))
                }
            })
    }

    private func replaceListenPipeline(open: Bool) -> Task<Void, Error> {
        listenConfigurationID &+= 1
        let configuration = listenConfigurationID, session = sessionGeneration
        let previous = listenTask, old = pipeline, lang = requestedListenLanguage, target = requestedListenTarget, log = self.log
        let resetStarted = HostClock.now()
        previous?.cancel(); pipeline = nil; listenLanguage = nil; listenTarget = nil
        ingest.prepareForRecognizerReplacement()
        onListenReset()
        log?.event("listen.prepare", ["stage": .tag("reset"), "generation": .int(Int(configuration)),
            "ms": .int(HostClock.ms(resetStarted, to: HostClock.now()))])
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            await old?.stop()
            guard let self else { throw CancellationError() }
            defer {
                if self.listenTaskConfigurationID == configuration {
                    self.listenTask = nil; self.listenTaskConfigurationID = nil
                }
            }
            guard session == self.sessionGeneration, configuration == self.listenConfigurationID,
                  !self.stopping, !Task.isCancelled else { throw CancellationError() }
            guard open else { return }
            guard let lang, let log, self.acceptsListenCallbacks(configuration) else { throw CancellationError() }
            let factoryStarted = HostClock.now()
            let engines = await self.makeEngines(Direction(source: lang, target: target), log, configuration)
            log.event("listen.prepare", ["stage": .tag("factory"), "generation": .int(Int(configuration)),
                "ms": .int(HostClock.ms(factoryStarted, to: HostClock.now()))])
            guard self.acceptsListenCallbacks(configuration), !Task.isCancelled else { throw CancellationError() }
            let pipelineStarted = HostClock.now()
            let next = self.makePipeline(lang: lang, target: target, engines: engines, log: log, configuration: configuration)
            log.event("listen.prepare", ["stage": .tag("pipeline"), "generation": .int(Int(configuration)),
                "ms": .int(HostClock.ms(pipelineStarted, to: HostClock.now()))])
            do { try await next.start() }
            catch { await next.stop(); throw error }
            guard self.acceptsListenCallbacks(configuration), !Task.isCancelled else {
                await next.stop(); throw CancellationError()
            }
            self.pipeline = next; self.listenLanguage = lang; self.listenTarget = target
            await next.setDraftsPaused(self.draftsPaused)
            if self.appleForThisMeeting { await next.useAppleForThisMeeting() }
            self.pruneEchoRecords()
            let records = self.echoRecords
            for record in records { await record.replay(to: next) }
            guard self.acceptsListenCallbacks(configuration), !Task.isCancelled else { throw CancellationError() }
            log.event("listen.configuration", ["lang": .tag(lang.rawValue), "target": .tag(target.rawValue), "generation": .int(Int(configuration))])
        }
        listenTask = task; listenTaskConfigurationID = configuration
        return task
    }

    private func startLatestListenPipeline() async throws {
        while !stopping {
            let configuration = listenConfigurationID
            let task: Task<Void, Error>
            if let pending = listenTask, listenTaskConfigurationID == configuration { task = pending }
            else { task = replaceListenPipeline(open: true) }
            let awaited = listenTaskConfigurationID
            do { try await task.value }
            catch {
                if !stopping, awaited != listenConfigurationID { continue }
                throw error
            }
            if pipeline != nil, awaited == listenConfigurationID { return }
            try Task.checkCancellation()
        }
        throw CancellationError()
    }

    public func recentRemoteText(withinS seconds: Double) async -> [String] {
        await pipeline?.recentRemoteText(withinS: seconds) ?? []
    }

    public func remoteVADOverlap(from start: HostTime, to end: HostTime) -> Double? {
        pipeline?.ingest.remoteVADOverlap(from: start, to: end)
    }

    public func setEchoReference(_ reference: EnvelopeHistory?) {
        guard echoReference !== reference else { return }
        echoReference = reference
        let p = pipeline
        Task { await p?.setEchoScore(nil, at: HostClock.now()) }
    }

    public func setDraftsPaused(_ paused: Bool) async {
        draftsPaused = paused
        await pipeline?.setDraftsPaused(paused)
    }

    public func useAppleForThisMeeting() async {
        appleForThisMeeting = true
        await pipeline?.useAppleForThisMeeting()
    }

    public func remoteSpeechSnapshot(at now: HostTime) async -> RemoteSpeechSnapshot {
        guard case .running = state, let p = pipeline else { return .unknown }
        let activity = p.ingest.activity(at: now)
        let echo = await p.echoScore(at: now), text = await p.volatileText
        guard pipeline === p, case .running = state else { return .unknown }
        return RemoteSpeechSnapshot(vadSpeech: activity.vadSpeech, energyDb: activity.energyDb,
                                    echoScore: echo, volatileText: text)
    }

    /// UI calls only after the user explicitly accepts globalFallbackWarning. Never automatic.
    public func setGlobalFallback(_ enabled: Bool) throws {
        if enabled, !mode.allowsGlobalFallback { throw SourceError.phoneRequiresPhoneAudio }
        guard case .running = state, enabled != usesGlobalFallback else { return }
        if enabled { _ = try AudioProcessList.current() } // fail closed if exclusions cannot be resolved
        let previous = usesGlobalFallback
        usesGlobalFallback = enabled
        do { try buildTap() }
        catch { usesGlobalFallback = previous; try? buildTap(); throw error }
        log?.event("tap.global_fallback", ["enabled": .bool(enabled)])
    }

    public enum SourceError: Error, LocalizedError, Equatable {
        case phoneRequiresPhoneAudio

        public var errorDescription: String? {
            String(appLocalized: "电话同传只收听 Phone，不能启用全局采集。")
        }
    }

    func updatePhoneAudioActivity(_ source: MeetingCandidate?) {
        guard mode == .phone else { return }
        let active: Bool
        if case .running = state {
            active = source?.app.id == MeetingMode.phoneAppID && source?.isRunningInput == true
        } else { active = false }
        guard !phoneAudioReported || active != phoneAudioActive else { return }
        phoneAudioReported = true
        phoneAudioActive = active
        onPhoneAudioActivity?(active)
    }

    private func sampleEcho() async {
        guard case .running = state, let p = pipeline, let t = tap, let remote = t.envelope,
              let reference = echoReference else { return }
        let now = HostClock.now()
        let score = await echoWorker.score(feed: reference, tap: remote, at: now)
        guard pipeline === p, tap === t, echoReference === reference, case .running = state else { return }
        await p.setEchoScore(score, at: now)
    }

    private func set(_ s: State) {
        state = s
        if case .running = s { } else { updatePhoneAudioActivity(nil) }
        events.emit(.state(s))
    }

    private func setHint(_ h: Hint?) {
        guard h != hint else { return }
        hint = h
        events.emit(.hint(h))
    }

    // MARK: - start / stop

    /// `choice`: the bundle id the user picked; `preferred`: the last choice (remembered).
    public func start(lang: Lang, target: Lang = .zh, choice: String? = nil, preferred: String? = nil,
                      requestedAt: HostTime? = nil) async -> StartResult {
        switch state {
        case .idle, .ended: break
        default: return .failed("already running")
        }
        guard MTSession.listen(source: lang, target: target) != nil else { return .failed("unsupported subtitle direction") }
        return await startFresh(lang: lang, target: target, choice: choice, preferred: preferred, requestedAt: requestedAt ?? HostClock.now())
    }

    private func startFresh(lang: Lang, target: Lang, choice: String?, preferred: String?, requestedAt: HostTime) async -> StartResult {
        let candidates = mode.sourceCandidates(in: (try? resolver.currentCandidates()) ?? [])
        let picked = mode.source(in: candidates, choice: choice, preferred: preferred)
        guard let source = picked else {
            return mode == .phone || choice != nil || candidates.isEmpty
                ? .noMeetingApp : .needsChoice(candidates.map(\.app.id))
        }
        sessionGeneration &+= 1
        let session = sessionGeneration
        stopping = false; requestedListenLanguage = lang; requestedListenTarget = target
        listenConfigurationID &+= 1; listenTaskConfigurationID = nil
        set(.starting)
        startHost = HostClock.now()
        let log = (try? EventLog(sessionID: String(UUID().uuidString.prefix(8)))) ?? EventLog(inMemory: HostClock.now)
        self.log = log
        // Metadata only: includes controller preparation before the session log was created.
        log.event("meeting.start_requested", ["mode": .tag(mode.rawValue)], at: requestedAt)

        // TCC first: silence in a meeting never means "denied" (§3.1), only the probe decides.
        let probeStartedAt = HostClock.now()
        var probe = await Task.detached { TCCProbe.run() }.value
        guard session == sessionGeneration, !stopping else { return .failed("cancelled") }
        if probe.verdict == .inconclusive { probe = await Task.detached { TCCProbe.run() }.value }
        guard session == sessionGeneration, !stopping else { return .failed("cancelled") }
        log.event("tcc.probe", ["verdict": .tag(probe.verdict.rawValue), "tap_start_ms": .int(probe.tapStartMs ?? -1),
                                "chunks": .int(probe.chunks), "first_audio_ms": .int(probe.firstAudioMs ?? -1),
                                "elapsed_ms": .int(HostClock.ms(probeStartedAt, to: HostClock.now()))])
        if probe.verdict == .denied {
            log.close()
            set(.idle)
            return .tccDenied
        }

        do { try await startLatestListenPipeline() }
        catch {
            guard session == sessionGeneration, !stopping else { return .failed("cancelled") }
            log.event("listen.start_failed", ["error": .tag(String(describing: type(of: error)))])
            log.close(); self.log = nil
            set(.idle)
            switch error as? AppleSpeechASR.Failure {
            case .assetsNotInstalled?: return .speechAssetsMissing(requestedListenLanguage ?? lang)
            case .notAuthorized?: return .speechNotAuthorized
            default: return .failed("\(error)")
            }
        }
        guard session == sessionGeneration, !stopping, let p = pipeline else { return .failed("cancelled") }
        processes = source.objectIDs
        app = source.app
        do { try buildTap() } catch {
            await p.stop()
            pipeline = nil; listenLanguage = nil; listenTarget = nil
            listenTask = nil; listenTaskConfigurationID = nil
            log.close(); self.log = nil
            set(.idle)
            return .failed("\(error)")
        }
        log.event("meeting.start", ["app": .tag(source.app.id), "mode": .tag(mode.rawValue), "processes": .int(processes.count),
                                    "lang": .tag((listenLanguage ?? lang).rawValue), "target": .tag((listenTarget ?? target).rawValue),
                                    "startup_ms": .int(HostClock.ms(requestedAt, to: HostClock.now()))])
        watchdog.reset()
        autoEnd = MeetingAutoEnd()
        lifecycle = MeetingLifecycle()
        startedAt = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                         reason: "TalkTalk meeting mode")
        watcher.startTimed { [weak self] e, observedAt in
            Task { @MainActor in self?.handle(e, observedAt: observedAt) }
        }
        observeScreenLock()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.everySecond() }
        }
        if probe.verdict == .inconclusive { setHint(.tccUnconfirmed) }
        set(.running(app: source.app.name))
        updatePhoneAudioActivity(source)
        echoTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleEcho()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        events.emit(.started(appID: source.app.id, appName: source.app.name, lang: listenLanguage ?? lang, mode: mode))
        return .started(app: source.app.name)
    }

    /// Single-shot: the check and the hand-over to `stopTask` happen before the first suspension
    /// point, so a second caller (even one arriving during `await pipeline.stop()`) only waits.
    public func stop(_ reason: EndReason = .user) async {
        if let t = stopTask { await t.value; return }
        switch state {
        case .starting, .running, .suspended: break
        default: return
        }
        stopping = true; sessionGeneration &+= 1; listenConfigurationID &+= 1
        updatePhoneAudioActivity(nil)
        listenTask?.cancel(); ingest.detach()
        let t = Task { await self.performStop(reason) }
        stopTask = t
        // After the hand-over: a subscriber re-entering stop() only waits on `t`.
        events.emit(.stopping(reason))
        await t.value
        stopTask = nil
    }

    private func performStop(_ reason: EndReason) async {
        let stopStartedAt = HostClock.now()
        log?.event("meeting.stopping", ["reason": .tag(reason.rawValue)], at: stopStartedAt)
        timer?.invalidate(); timer = nil
        echoTask?.cancel(); echoTask = nil
        noticeTask?.cancel()
        await noticeTask?.value; noticeTask = nil
        MeetingAutoEndNotification.clear()
        usesGlobalFallback = false
        appleForThisMeeting = false
        echoReference = nil
        watcher.stop()
        for o in lockObservers { DistributedNotificationCenter.default().removeObserver(o) }
        lockObservers.removeAll()
        tap?.stop(); tap = nil
        log?.event("meeting.capture_stopped", ["elapsed_ms": .int(HostClock.ms(stopStartedAt, to: HostClock.now()))])
        let p = pipeline, pending = listenTask
        pipeline = nil; listenTask = nil; listenTaskConfigurationID = nil; listenLanguage = nil; listenTarget = nil
        if let p { await p.stop() }
        _ = await pending?.result
        ingest.reset(); echoRecords.removeAll()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        log?.event("meeting.end", ["reason": .tag(reason.rawValue), "minutes": .double(Double(nowMs) / 60_000),
                                   "stop_ms": .int(HostClock.ms(stopStartedAt, to: HostClock.now()))])
        log?.close(); log = nil
        startedAt = nil
        setHint(nil)
        set(.ended(reason))
        events.emit(.ended(reason))
        set(.idle)
    }

    /// The user answered "还在开会" to the auto-end question.
    public func stillInMeeting() {
        autoEnd.stillInMeeting(nowMs: nowMs)
        cancelAutoEndNotice()
        setHint(nil)
    }

    #if DEBUG
    /// Tests: a running session around a given pipeline, without a tap, probe or watcher.
    func runForTesting(app: String, pipeline: ListenPipeline) {
        self.pipeline = pipeline
        self.ingest = pipeline.ingest
        self.log = EventLog(inMemory: HostClock.now)
        requestedListenLanguage = pipeline.lang; listenLanguage = pipeline.lang
        requestedListenTarget = pipeline.target; listenTarget = pipeline.target
        stopping = false; sessionGeneration &+= 1
        startHost = HostClock.now()
        set(.running(app: app))
    }
    /// Uses the real replacement coordinator with fake ASR engines, without Core Audio or TCC.
    func startListenForTesting(app: String = "Test meeting", lang: Lang, target: Lang = .zh) async throws {
        guard MTSession.listen(source: lang, target: target) != nil else { throw ListenConfigurationError.unsupportedDirection }
        sessionGeneration &+= 1; stopping = false; requestedListenLanguage = lang; requestedListenTarget = target
        listenConfigurationID &+= 1
        log = EventLog(inMemory: HostClock.now); startHost = HostClock.now()
        set(.starting)
        try await startLatestListenPipeline()
        guard !stopping else { throw CancellationError() }
        set(.running(app: app))
    }
    func suspendListenForTesting() { suspend(.sleep) }
    func resumeListenForTesting() async throws {
        guard case let .suspended(app) = state else { return }
        _ = lifecycle.clear(.sleep, meetingHasAudio: true)
        set(.running(app: app))
        try await replaceListenPipeline(open: true).value
    }
    func feedListenForTesting(_ samples: [Float], at: HostTime) { ingest.push(samples, host: at) }
    #endif

    // MARK: - tap

    private func buildTap() throws {
        tap?.stop()
        let ids = usesGlobalFallback ? resolver.globalTapExclusions(try AudioProcessList.current()) : processes
        let t = MeetingTap(processes: ids, muteBehavior: .unmuted, excludingProcesses: usesGlobalFallback)
        let ingest = self.ingest
        let log = self.log
        let onRemoteAudio = self.onRemoteAudio
        try t.start(onChunk: { [weak self] c in
            if let gap = ingest.prepareAnalyzerRestart(ifGapBefore: c.hostTime) {
                Task { @MainActor in
                    guard let self, let p = self.pipeline else { return }
                    do { try await p.restartAnalyzer(afterGapMs: gap) }
                    catch {
                        log?.event("listen.restart_failed", ["error": .tag(String(describing: type(of: error)))])
                        await self.analyzerFailed(p)
                    }
                }
            }
            onRemoteAudio(c.samples, c.hostTime)
            ingest.push(c.samples, host: c.hostTime)
        },
                    onEvent: { e in
                        switch e {
                        case let .gapFilled(ms): log?.event("tap.gap_filled", ["ms": .int(ms)])
                        case let .restartNeeded(ms): log?.event("tap.restart_gap", ["ms": .int(ms)])
                        case let .droppedStamps(n): log?.event("tap.dropped_stamps", ["n": .int(n)])
                        }
                    })
        tap = t
    }

    private func rebuildTap(_ why: String) {
        log?.event("tap.rebuild", ["why": .tag(why)])
        do { try buildTap() } catch { log?.event("tap.rebuild_failed", ["why": .tag(why)]) }
    }

    /// Re-resolve the app's process objects (helpers come and go; coreaudiod restarts renumber).
    private func refreshProcesses() -> MeetingCandidate? {
        guard let app else { return nil }
        let all = try? AudioProcessList.current()
        let c = all.flatMap { resolver.candidates($0).first { $0.app.id == app.id } }
        if usesGlobalFallback {
            guard let all else {
                tap?.stop(); tap = nil
                log?.event("tap.global_exclusions_unavailable")
                return nil
            }
            do {
                if tap == nil { try buildTap() }
                else { try tap?.update(processes: resolver.globalTapExclusions(all)) }
            } catch { tap?.stop(); tap = nil }
            if let c { processes = c.objectIDs }
            return c
        }
        if let c, Set(c.objectIDs) != Set(processes) {
            processes = c.objectIDs
            do { try tap?.update(processes: processes) } catch { rebuildTap("update_failed") }
            log?.event("tap.processes", ["n": .int(processes.count)])
        }
        return c
    }

    // MARK: - periodic

    private func everySecond() {
        guard case .running = state else { return }
        let c = usesGlobalFallback ? refreshProcesses() : (try? resolver.currentCandidates())?.first { $0.app.id == app?.id }
        updatePhoneAudioActivity(c)
        let running = c?.isRunningOutput ?? false
        let anyAudio = running || (c?.isRunningInput ?? false)
        let lastNZ = tap?.lastNonZeroHostTime.map { HostClock.ms(startHost, to: $0) }
        switch watchdog.observe(nowMs: nowMs, runningOutput: running, lastNonZeroMs: lastNZ) {
        case let .rebuild(n):
            log?.event("tap.zero_watchdog", ["attempt": .int(n)])
            rebuildTap("all_zero")
        case .noAudioYet: if hint == nil || hint == .meetingSilent { setHint(.meetingSilent) }
        case .ok, .backingOff: if hint == .meetingSilent { setHint(nil) }
        }
        switch autoEnd.observe(nowMs: nowMs, anyAudio: anyAudio) {
        case .ok: if hint == .meetingSeemsOver, !autoEnd.asking { setHint(nil); cancelAutoEndNotice() }
        case .ask:
            log?.event("meeting.auto_end_ask")
            setHint(.meetingSeemsOver)
            noticeTask = Task { await MeetingAutoEndNotification.postIfAuthorized(mode: mode) }
        case .end: Task { await stop(.autoEnd) }
        }
    }

    private func cancelAutoEndNotice() {
        let pending = noticeTask; noticeTask = nil; pending?.cancel()
        Task { await pending?.value; MeetingAutoEndNotification.clear() }
    }

    private func analyzerFailed(_ p: ListenPipeline?) async {
        guard let p, pipeline === p else { return }
        await stop(.failed)
    }

    // MARK: - system events

    private func handle(_ e: DeviceWatcher.Event, observedAt: HostTime = HostClock.now()) {
        switch e {
        case .processListChanged:
            guard case .running = state else { return }
            updatePhoneAudioActivity(refreshProcesses())
        case .serviceRestarted:
            guard case .running = state else { return }
            setHint(.audioRestarting)
            log?.event("audio.service_restarted")
            _ = refreshProcesses()
            rebuildTap("service_restarted")
            setHint(nil)
            events.emit(.audioServiceRestarted(at: observedAt))
        case .defaultOutputChanged:
            guard case .running = state else { return }
            // The aggregate has no sub-device, but the meeting's output route (and so the tap's
            // format) moved: rebuild. Not on devicesChanged: our own aggregate changes that list.
            rebuildTap("output_route")
        case .devicesChanged, .deviceDied, .deviceSampleRateChanged, .deviceFormatChanged, .defaultInputChanged:
            break
        case .willSleep: suspend(.sleep)
        case .sessionResigned: suspend(.session)
        case .didWake: clearSuspend(.sleep)
        case .sessionActivated: clearSuspend(.session)
        }
    }

    private func observeScreenLock() {
        let dnc = DistributedNotificationCenter.default()
        lockObservers = [
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend(.lock) }
            },
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.clearSuspend(.lock) }
            },
        ]
    }

    private func suspend(_ why: MeetingLifecycle.Reason) {
        switch state {
        case .running, .suspended: break
        default: return
        }
        log?.event("meeting.suspend", ["why": .tag(why.rawValue)])
        guard lifecycle.suspend(why) == .suspend, case let .running(name) = state else { return }
        tap?.stop(); tap = nil
        set(.suspended(app: name))
        _ = replaceListenPipeline(open: false)
        events.emit(.suspended(why))
    }

    /// After wake / unlock / switching back: once no reason is left, carry on only if the meeting
    /// process is still sending or receiving audio (MeetingLifecycle).
    private func clearSuspend(_ why: MeetingLifecycle.Reason) {
        guard case let .suspended(name) = state else { return }
        let c = refreshProcesses()
        let audio = c.map { $0.isRunningInput || $0.isRunningOutput } ?? false
        switch lifecycle.clear(why, meetingHasAudio: audio) {
        case let .resume(afterSleep):
            watchdog.reset()
            rebuildTap("resume")
            log?.event("meeting.resume")
            set(.running(app: name))
            updatePhoneAudioActivity(c)
            let task = replaceListenPipeline(open: true), configuration = listenConfigurationID
            Task { [weak self] in
                do { try await task.value }
                catch is CancellationError { }
                catch {
                    guard let self, self.acceptsListenCallbacks(configuration), let lang = self.requestedListenLanguage else { return }
                    self.log?.event("listen.resume_failed", ["error": .tag(String(describing: type(of: error)))])
                    self.onListenFailure(lang, String(describing: error))
                }
            }
            events.emit(.resumed(afterSleep: afterSleep))
        case .end:
            Task { await stop(.afterSleep) }
        case .none, .suspend:
            break
        }
    }
}

/// Unknown observations remain nil so a stopped tap cannot trigger a floor claim.
public struct RemoteSpeechSnapshot: Sendable, Equatable {
    public let vadSpeech: Bool?
    public let energyDb: Double?
    public let echoScore: Double?
    public let volatileText: String
    public static let unknown = RemoteSpeechSnapshot(vadSpeech: nil, energyDb: nil, echoScore: nil, volatileText: "")
}

/// Serial actor keeps correlation work off MainActor and the capture's real-time IO thread.
private actor MeetingEchoWorker {
    private let scorer = EchoScorer()
    func score(feed: EnvelopeHistory, tap: EnvelopeHistory, at: HostTime) -> Double? {
        scorer.estimate(feed: feed, tap: tap, through: at)?.score
    }
}
