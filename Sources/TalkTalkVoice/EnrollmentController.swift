import Foundation
import Observation
import TalkTalkAudio
import TalkTalkCore

/// Drives one "my voice" enrollment (ARCHITECTURE.md §9.2) for `EnrollmentView`. Owns the
/// MicCapture while recording, runs the checks, and saves through VoiceStore. The same
/// controller backs the dev entry `--bench enroll` (M0), the first-run onboarding (M1) and the
/// settings page (M2), so it knows nothing about windows or the bench.
///
/// Privacy (§9.5): the take, the transcript and the reference stay in memory or in `voice/`;
/// nothing here logs them. `outcomeSummary` carries only statuses and numbers.
@MainActor
@Observable
public final class EnrollmentController {
    public struct DeviceRow: Identifiable, Sendable, Equatable {
        public let info: InputDeviceInfo
        public let verdict: RecordingDevicePolicy.Verdict
        public var id: String { info.uid }

        public init(info: InputDeviceInfo, verdict: RecordingDevicePolicy.Verdict) {
            self.info = info
            self.verdict = verdict
        }
    }

    public private(set) var machine = VoiceEnrollment()
    public var phase: VoiceEnrollment.Phase { machine.phase }
    public private(set) var devices: [DeviceRow] = []
    public var selectedUID: String?
    /// Input level of the latest 10 ms chunk, dBFS (for the meter).
    public private(set) var levelDb: Double = Levels.floorDb
    public private(set) var recordingSeconds: Double = 0
    public private(set) var noiseProgress: Double = 0
    public private(set) var hasExistingProfile: Bool
    public private(set) var savedProfile: VoiceProfile?
    public private(set) var lastReport: EnrollmentReport?
    /// "待引擎" until an engine is connected (§9.2 steps 6–7).
    public private(set) var engineAvailable: Bool
    /// The checked en/de audition of the candidate (§9.2 step 7); samples stay in memory only.
    public private(set) var audition: AuditionResult?
    /// Set while an audition clip plays (the monitor output, never TalkTalk Mic).
    public private(set) var playingAudition: Lang?
    public private(set) var auditionPlaybackError: String?
    public let script: EnrollmentScript
    public let store: VoiceStore

    private let transcriber: (any EnrollmentTranscriber)?
    private let engine: (any VoiceEngineServices)?
    private let monitor: any AuditionMonitor
    private let routing: SpeakVoiceRouting?
    private let passthroughGains: (any PassthroughGainStore)?
    /// The built-and-auditioned candidate waiting for 保存 (staging dir + what goes into it).
    private var candidate: Candidate?
    /// Voice slot / profile.json operations, shared with `VoiceLifecycle`.
    private let queue: VoiceSlotQueue
    /// The running build-and-audition of 保存; cancelled by 放弃 / 重录.
    private var saveTask: Task<Void, Never>?
    /// The latest 保存 attempt, kept after 放弃 (tests await its end: the drop, the restore).
    private(set) var lastSaveAttempt: Task<Void, Never>?
    /// Bumped by every 保存, 放弃 and 重录: a save attempt whose generation is no longer current
    /// drops its result (and puts the saved voice back), whatever phase the machine is in.
    private var generation = 0
    /// enrollmentStarted / enrollmentFinished calls, chained so they reach the engine in order.
    private var engineHook: Task<Void, Never>?
    private var capture: MicCapture?
    private var captureDevice: InputDeviceInfo?
    private var noise: [Float] = []
    private var take: [Float] = []
    private var detector: AutoStopDetector?
    private var countdownTask: Task<Void, Never>?
    private var chunkCounter = 0

    /// `engine` given: the transcript row uses Qwen3-ASR when the engine is already READY with ASR
    /// loaded (Apple zh-CN otherwise; enrollment never cold-starts the engine for it), and 保存
    /// first builds the conditioning and runs the audition in staging. `routing` /
    /// `passthroughGains`: the app-wide SPEAK voice and passthrough gain store, updated on save.
    public init(store: VoiceStore = .product,
                transcriber: (any EnrollmentTranscriber)? = AppleZhTranscriber(),
                engine: (any VoiceEngineServices)? = nil,
                monitor: any AuditionMonitor = UnavailableAuditionMonitor(),
                routing: SpeakVoiceRouting? = nil,
                passthroughGains: (any PassthroughGainStore)? = nil,
                queue: VoiceSlotQueue = VoiceSlotQueue(),
                script: EnrollmentScript = .current) {
        self.store = store
        self.queue = queue
        if let qwen = engine?.transcriber {
            self.transcriber = transcriber.map { FallbackTranscriber(primary: qwen, fallback: $0) } ?? qwen
        } else {
            self.transcriber = transcriber
        }
        self.engine = engine
        self.monitor = monitor
        self.routing = routing
        self.passthroughGains = passthroughGains
        self.script = script
        self.engineAvailable = engine != nil
        self.hasExistingProfile = store.hasProfile
        store.removeStaleStaging()
        refreshDevices()
    }

    public var selectedDevice: DeviceRow? { devices.first { $0.id == selectedUID } }
    public var sampleRate: Double { captureDevice?.nominalSampleRate ?? 0 }

    public func refreshDevices() {
        let infos = InputDeviceCatalog.inputDevices()
        devices = infos.map { DeviceRow(info: $0, verdict: RecordingDevicePolicy.evaluate($0)) }
        if selectedUID == nil || !(selectedDevice?.verdict.isAccepted ?? false) {
            selectedUID = RecordingDevicePolicy.preferred(infos)?.uid
        }
    }

    // MARK: - user actions

    public func start() {
        guard machine.send(.start) else { return }
        beginTake()
    }

    public func retake() {
        guard machine.send(.retake) else { return }
        abandonSave()
        dropCandidate()
        beginTake()
    }

    /// The "完成" button while recording.
    public func finishRecording() {
        guard phase == .recording else { return }
        stopRecording()
    }

    /// The 保存 button. Without an engine (or from the audition review) it commits; with an engine
    /// in review it first builds the candidate and runs the audition (§9.2 steps 6–7).
    public func save() {
        if case .auditionReview = phase {
            guard let c = candidate, machine.send(.save) else { return }
            candidate = nil
            commit(c)
            return
        }
        guard let report = lastReport, let device = captureDevice else { return }
        let take = self.take, rate = device.nominalSampleRate
        let script = self.script, store = self.store, checker = self.transcriber?.name
        guard let engine else {
            guard machine.send(.save) else { return }
            do {
                commit(try Self.prepareCandidate(take: take, sampleRate: rate, report: report, micUID: device.uid,
                                                 script: script, store: store, transcriberName: checker))
            } catch {
                machine.send(.failed("保存失败：\(error)"))
            }
            return
        }
        guard machine.send(.audition) else { return }
        // Reopened within the idle window of an earlier enrollment: keep the engine up.
        hook { await $0.enrollmentStarted() }
        generation += 1
        let gen = generation, queue = self.queue, routing = self.routing
        saveTask = Task {
            let c0: Candidate
            do {
                c0 = try Self.prepareCandidate(take: take, sampleRate: rate, report: report, micUID: device.uid,
                                               script: script, store: store, transcriberName: checker)
            } catch {
                if gen == self.generation { self.machine.send(.failed("保存失败：\(error)")) }
                return
            }
            let outcome = await Self.auditionAttempt(c0, engine: engine, script: script, store: store, routing: routing,
                                                     queue: queue) { await MainActor.run { gen == self.generation } }
            // Re-checked here, on the main actor in the same job as the switch: a 放弃 / 关窗
            // between `stillWanted` and now must not leave a candidate behind (review C1).
            let current = gen == self.generation && !Task.isCancelled
            switch outcome {
            case .dropped:
                break
            case let .review(c):
                guard current, self.machine.send(.auditioned(c.audition?.summary ?? AuditionResult(clips: []).summary)) else {
                    Self.dropLate(c.staging, store: store, engine: engine, routing: routing, queue: queue)
                    return
                }
                self.candidate = c
                self.audition = c.audition
            case let .saveWithoutAudition(c):
                guard current else {
                    Self.dropLate(c.staging, store: store, engine: engine, routing: routing, queue: queue)
                    return
                }
                if store.hasProfile {
                    // A failed replacement audition is not permission to overwrite the saved voice.
                    store.discard(c.staging)
                    _ = await queue.runAlways { await VoiceSync.restore(store: store, engine: engine, routing: routing) }
                    if gen == self.generation, !Task.isCancelled {
                        self.machine.send(.failed("试听未完成，原来的声音已保留，请重录"))
                    }
                    return
                }
                guard self.machine.send(.auditionSkipped) else {
                    Self.dropLate(c.staging, store: store, engine: engine, routing: routing, queue: queue)
                    return
                }
                self.commit(c)
            case .cancelled:
                if current { self.machine.send(.failed("保存被取消")) }
            }
        }
        lastSaveAttempt = saveTask
    }

    /// A result that arrived after 放弃 / 关窗: drop its staging, put the saved voice back.
    nonisolated static func dropLate(_ staging: URL, store: VoiceStore, engine: any VoiceEngineServices,
                                     routing: SpeakVoiceRouting?, queue: VoiceSlotQueue) {
        store.discard(staging)
        Task { _ = await queue.runAlways { await VoiceSync.restore(store: store, engine: engine, routing: routing) } }
    }

    /// 放弃 / 重录 while 保存 is building or auditioning: the attempt is cancelled and its result
    /// will be dropped (generation), with the saved voice put back.
    private func abandonSave() {
        generation += 1
        saveTask?.cancel()
        saveTask = nil
    }

    /// The enrollment window is done (closed, saved, or cancelled): the engine started for it may
    /// idle-exit (§7.6). The settings page calls it when the window closes.
    public func finish() {
        hook { await $0.enrollmentFinished() }
    }

    /// Runs an engine idle hook after the previous one (a close right after a start must not
    /// reach the engine first and leave the idle exit cancelled).
    private func hook(_ body: @escaping @Sendable (any VoiceEngineServices) async -> Void) {
        guard let engine else { return }
        let prev = engineHook
        engineHook = Task { await prev?.value; await body(engine) }
    }

    /// Plays one audition sentence through the monitor output (never TalkTalk Mic, §9.2 step 7).
    public func playAudition(_ lang: Lang) {
        guard let clip = audition?.clip(lang), !clip.samples.isEmpty else { return }
        let monitor = self.monitor
        playingAudition = lang
        auditionPlaybackError = nil
        Task {
            do {
                try await monitor.play(clip.samples)
            } catch {
                self.auditionPlaybackError = "\(error)"
            }
            if self.playingAudition == lang { self.playingAudition = nil }
        }
    }

    public func stopAudition() {
        let monitor = self.monitor
        playingAudition = nil
        Task { await monitor.stop() }
    }

    public func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        capture?.stop()
        capture = nil
        machine.send(.cancel)
        abandonSave()
        dropCandidate()
    }

    /// Statuses and numbers only — for `--bench enroll --out` and diagnostics (§9.5, §12.1).
    public var outcomeSummary: [String: Any] {
        var out: [String: Any] = ["phase": phase.name, "takes": machine.takes,
                                  "profile_present": store.hasProfile, "engine_available": engineAvailable]
        if let r = lastReport {
            var statuses: [String: String] = [:]
            for c in r.results { statuses[c.id.rawValue] = c.status.rawValue }
            out["checks"] = statuses
            if let data = try? JSONEncoder().encode(r.measurements),
               let obj = try? JSONSerialization.jsonObject(with: data) { out["measurements"] = obj }
        }
        if let p = savedProfile {
            out["saved_profile"] = ["id": p.id, "duration_s": p.durationSeconds,
                                    "speaking_rate_cps": p.speakingRateCharsPerSecond, "mic_uid_hash": p.micUIDHash,
                                    "conditioning": p.conditioning, "audition": p.audition]
        }
        if let a = audition?.summary, let data = try? JSONEncoder().encode(a),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            out["audition"] = obj
        }
        return out
    }

    // MARK: - candidate (staging) lifecycle

    struct Candidate: Sendable {
        var staging: URL
        var wav: Data
        var profile: VoiceProfile
        var blobs: [ConditioningBlob] = []
        var audition: AuditionResult?
        var passthroughGainDb: Double
    }

    /// Step 8 in the queue, then the engine and SPEAK are aligned with the new profile on disk:
    /// conditioning present → load it, then route; pending_engine with the engine running → build
    /// now (`VoiceSync.align`), "pending" meanwhile; engine not running → "pending" until READY.
    private func commit(_ c: Candidate) {
        let store = self.store, script = self.script, engine = self.engine, routing = self.routing
        let queue = self.queue, gains = self.passthroughGains
        Task {
            do {
                let p = try await Self.commitAndAlign(c, script: script, store: store, engine: engine, routing: routing,
                                                      gains: gains, queue: queue) { await MainActor.run { _ = self.machine.send(.saved) } }
                self.savedProfile = p
                self.hasExistingProfile = true
            } catch {
                self.machine.send(.failed("保存失败：\(error)"))
            }
        }
    }

    /// Leaving the audition review (retake, cancel, closing the window): the staging directory goes,
    /// and the engine gets the saved profile's voice back (the candidate replaced it for the audition).
    private func dropCandidate() {
        stopAudition()
        audition = nil
        guard let c = candidate else { return }
        candidate = nil
        store.discard(c.staging)
        // buildAndAudition already put the saved voice back after synthesis; reload only if
        // something changed since (engine down, deleted, never restored).
        if let engine, !VoiceSync.alreadyRestored(store: store, routing: routing) {
            let store = self.store, routing = self.routing, queue = self.queue
            Task { _ = try? await queue.run { await VoiceSync.restore(store: store, engine: engine, routing: routing) } }
        }
    }

    /// Tests only (`@testable`): a finished take in review without a microphone.
    func seedReview(take: [Float], report: EnrollmentReport, device: InputDeviceInfo) {
        self.take = take
        captureDevice = device
        lastReport = report
        for e: VoiceEnrollment.Event in [.start, .noiseMeasured, .tick, .tick, .tick, .stopped, .analyzed(report)] {
            machine.send(e)
        }
    }

    // MARK: - capture

    private func beginTake() {
        hook { await $0.enrollmentStarted() }
        noise = []
        take = []
        detector = nil
        noiseProgress = 0
        recordingSeconds = 0
        lastReport = nil
        Task {
            guard await MicrophoneAuthorization.request() == .authorized else {
                fail("没有麦克风权限：请在“系统设置 › 隐私与安全性 › 麦克风”里允许 TalkTalk，然后再试")
                return
            }
            if transcriber is AppleZhTranscriber || (transcriber as? FallbackTranscriber)?.fallback is AppleZhTranscriber {
                // Ask now, so the system prompt doesn't appear in the middle of the review.
                _ = await AppleZhTranscriber.requestAuthorization()
            }
            guard phase == .measuringNoise else { return }
            refreshDevices()
            guard let row = selectedDevice else {
                fail("没有可用的麦克风（只支持内建麦克风或 USB 麦克风）")
                return
            }
            if let reason = row.verdict.reason {
                fail("这个麦克风不能用来录声音：\(reason)")
                return
            }
            openCapture(row.info)
        }
    }

    private func openCapture(_ device: InputDeviceInfo) {
        do {
            let capture = try MicCapture(device: device)
            try capture.start(
                onChunk: { [weak self] chunk in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(chunk.samples) } }
                },
                onInterruption: { [weak self] interruption in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.interrupted(interruption) } }
                })
            self.capture = capture
            self.captureDevice = device
        } catch {
            fail("打不开麦克风：\(error)")
        }
    }

    private func consume(_ samples: [Float]) {
        chunkCounter += 1
        if chunkCounter % 3 == 0 { levelDb = Levels.dbfs(Levels.rms(samples)) }
        let rate = sampleRate
        switch phase {
        case .measuringNoise:
            noise.append(contentsOf: samples)
            let needed = Int(VoiceEnrollment.noiseSeconds * rate)
            noiseProgress = min(1, Double(noise.count) / Double(needed))
            if noise.count >= needed {
                noise.removeLast(noise.count - needed)
                machine.send(.noiseMeasured)
                runCountdown()
            }
        case .recording:
            take.append(contentsOf: samples)
            recordingSeconds = Double(take.count) / rate
            if var d = detector {
                let decision = d.feed(samples)
                detector = d
                if decision != .keepGoing { stopRecording() }
            }
        default:
            break   // countdown: the meter moves, samples are dropped
        }
    }

    private func runCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for _ in 0..<VoiceEnrollment.countdownFrom {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, case .countdown = self.phase else { return }
                self.machine.send(.tick)
            }
            guard let self, self.phase == .recording else { return }
            let skip = min(self.noise.count, Int(self.sampleRate * 0.1))
            let floorDb = Levels.dbfs(Levels.rms(self.noise[skip...]))
            self.detector = AutoStopDetector(sampleRate: self.sampleRate, noiseFloorDb: floorDb,
                                             trailingSilenceSeconds: VoiceEnrollment.autoStopSilenceSeconds,
                                             maxSeconds: VoiceEnrollment.maxRecordingSeconds)
        }
    }

    private func stopRecording() {
        capture?.stop()
        capture = nil
        detector = nil
        levelDb = Levels.floorDb
        guard machine.send(.stopped) else { return }
        let take = self.take, noise = self.noise, rate = sampleRate
        let transcriber = self.transcriber, script = self.script
        Task {
            let report = await Self.analyze(take: take, noise: noise, sampleRate: rate, script: script, transcriber: transcriber)
            guard self.phase == .analyzing else { return }
            self.lastReport = report
            self.machine.send(.analyzed(report))
        }
    }

    private func interrupted(_ interruption: MicCapture.Interruption) {
        capture = nil
        countdownTask?.cancel()
        switch interruption {
        case .sampleRateChanged, .formatChanged:
            fail("麦克风的采样率变了（可能有别的 App 打开了它），这一遍作废，请重录")
        case .deviceDied:
            fail("麦克风断开了，请重新选择后重录")
        }
    }

    private func fail(_ message: String) {
        capture?.stop()
        capture = nil
        machine.send(.failed(message))
    }

    // MARK: - work off the main actor

    nonisolated static func analyze(take: [Float], noise: [Float], sampleRate: Double, script: EnrollmentScript,
                                    transcriber: (any EnrollmentTranscriber)?) async -> EnrollmentReport {
        let skip = min(noise.count, Int(sampleRate * 0.1))
        let floorDb = Levels.dbfs(Levels.rms(noise[skip...]))
        let seg = SpeechSegmentation(samples: take, sampleRate: sampleRate, noiseFloorDb: floorDb)
        var comparison: TranscriptComparison.Result?
        if seg.hasSpeech, let transcriber, let text = await transcriber.transcribe(take, sampleRate: sampleRate) {
            comparison = TranscriptComparison.compare(transcript: text, script: script.text)
        }
        return EnrollmentChecks.evaluate(take: take, noise: noise, sampleRate: sampleRate, script: script,
                                         transcript: comparison)
    }

    /// §9.2 step 5 and the start of step 6: post-process the take, open the staging directory, and
    /// compute the passthrough gain from the raw speech RMS (before normalization, §3.8).
    nonisolated static func prepareCandidate(take: [Float], sampleRate: Double, report: EnrollmentReport,
                                             micUID: String, script: EnrollmentScript, store: VoiceStore,
                                             transcriberName: String? = nil) throws -> Candidate {
        let seg = SpeechSegmentation(samples: take, sampleRate: sampleRate,
                                     noiseFloorDb: report.measurements.noiseFloorDbfs)
        let out = try ReferenceAudio.make(take: take, sampleRate: sampleRate, segmentation: seg)
        let wav = WAVFile.encodePCM16(out.samples, sampleRate: Int(ReferenceAudio.outputSampleRate))
        var profile = VoiceProfile(script: script, wav: wav, report: report, micUID: micUID,
                                   durationSeconds: out.durationSeconds)
        if report.result(.transcript)?.status != .pending { profile.transcriptChecker = transcriberName }
        let staging = try store.makeStaging()
        return Candidate(staging: staging, wav: wav, profile: profile,
                         passthroughGainDb: VoiceGains.passthroughGainDb(rawSpeechRmsDbfs: report.measurements.speechRmsDbfs))
    }

    enum AttemptOutcome: Sendable {
        /// Built and auditioned: show the review.
        case review(Candidate)
        /// The engine failed (build, or audition after a successful build): save as pending_engine
        /// (built + pending_engine when the blobs exist).
        case saveWithoutAudition(Candidate)
        /// 放弃 / 重录 meanwhile (generation moved on, or the task was cancelled): the staging is
        /// gone and the saved voice is back in the engine.
        case dropped
        /// The queue cancelled it (a deletion): staging gone.
        case cancelled
    }

    /// One 保存 attempt with an engine (§9.2 steps 6–7), in the voice queue. `stillWanted` is the
    /// generation check, asked once the engine work is over.
    nonisolated static func auditionAttempt(_ c0: Candidate, engine: any VoiceEngineServices, script: EnrollmentScript,
                                            store: VoiceStore, routing: SpeakVoiceRouting?, queue: VoiceSlotQueue,
                                            stillWanted: @escaping @Sendable () async -> Bool) async -> AttemptOutcome {
        let result: Result<Candidate, Error>
        do {
            result = .success(try await queue.run {
                try await buildAndAudition(c0, engine: engine, script: script, store: store, routing: routing)
            })
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled, await stillWanted() else {
            // The candidate may sit in the engine (its load ran before the error or the cancel):
            // drop the staging and put the saved voice back.
            store.discard(c0.staging)
            _ = await queue.runAlways { await VoiceSync.restore(store: store, engine: engine, routing: routing) }
            return .dropped
        }
        switch result {
        case let .success(c): return c.audition == nil ? .saveWithoutAudition(c) : .review(c)
        case .failure(let e) where e is VoiceSlotQueue.Cancelled:
            // A deletion cancelled it. (An engine that stopped mid-call also surfaces as
            // CancellationError: that is an engine error and saves as pending_engine below.)
            store.discard(c0.staging)
            return .cancelled
        case .failure: return .saveWithoutAudition(c0)
        }
    }

    /// Step 8 in the queue, then the engine and SPEAK are aligned with the new profile on disk:
    /// conditioning present → load it (idempotent), then route; pending_engine with the engine
    /// running → build now (`VoiceSync.align`), "pending" meanwhile; engine not running →
    /// "pending" until the next READY. `saved` runs right after the commit.
    @discardableResult
    nonisolated static func commitAndAlign(_ c: Candidate, script: EnrollmentScript, store: VoiceStore,
                                           engine: (any VoiceEngineServices)?, routing: SpeakVoiceRouting?,
                                           gains: (any PassthroughGainStore)?, queue: VoiceSlotQueue,
                                           saved: @escaping @Sendable () async -> Void = {}) async throws -> VoiceProfile {
        do {
            try await queue.run {
                try commitCandidate(c, script: script, store: store)
                gains?.setGainDb(c.passthroughGainDb, micUIDHash: c.profile.micUIDHash)
            }
        } catch {
            store.discard(c.staging)
            if let engine {
                _ = await queue.runAlways { await VoiceSync.restore(store: store, engine: engine, routing: routing) }
            }
            throw error
        }
        await saved()
        guard let engine else { return c.profile }
        routing?.useMyVoicePending()
        _ = try? await queue.run { () async -> Void in
            if await engine.readiness().running {
                _ = await VoiceSync.align(store: store, engine: engine, routing: routing)
            }
        }
        return (try? store.loadProfile()) ?? c.profile
    }

    /// Step 6 (conditioning per model × mode, into staging) and step 7 (audition checks, playout
    /// gain). Throws when the build fails (engine error). A *failed check* is a normal result
    /// (`audition.passed` false); an engine error during the audition keeps the blobs and returns
    /// the candidate as built + `pending_engine` (`audition == nil`).
    nonisolated static func buildAndAudition(_ c0: Candidate, engine: any VoiceEngineServices, script: EnrollmentScript,
                                             store: VoiceStore, routing: SpeakVoiceRouting? = nil) async throws -> Candidate {
        var c = c0
        let blobs = try await engine.buildConditioning(referenceWAV: c.wav, scriptText: script.text, modes: c.profile.cloneModes)
        try Task.checkCancellation()
        for b in blobs { try store.writeConditioning(b.data, key: b.key, into: c.staging) }
        c.blobs = blobs
        c.profile.conditioningEntries = blobs.map { .init(key: $0.key, model: $0.model, mode: $0.mode) }
        c.profile.conditioning = blobs.isEmpty ? "pending_engine" : "built"
        // The audition puts the unsaved candidate into the engine's one slot. SPEAK must not speak
        // with it under the saved voice's handle and gain (second review, item 6): "pending" while
        // it is in there, and the saved voice goes back right after synthesis (the review plays
        // the clips from memory).
        let hadProfile = store.hasProfile
        if hadProfile { routing?.useMyVoicePending() }
        do {
            let a = try await engine.audition(conditioning: blobs, modes: c.profile.modesByLang, profileID: c.profile.id,
                                              referenceWAV: c.wav)
            c.audition = a
            VoiceSync.apply(a, to: &c.profile)
        } catch where isDeliberateCancel(error) {
            await VoiceSync.restore(store: store, engine: engine, routing: routing)
            throw error
        } catch {
            c.audition = nil
            c.profile.audition = "pending_engine"
        }
        await VoiceSync.restore(store: store, engine: engine, routing: routing)
        try Task.checkCancellation()
        return c
    }

    /// Step 8: write reference + script + profile into staging, then rename / RENAME_SWAP. The
    /// old profile stays valid until the swap succeeds.
    nonisolated static func commitCandidate(_ c: Candidate, script: EnrollmentScript, store: VoiceStore) throws {
        try store.writeReference(c.wav, script: script, profile: c.profile, into: c.staging)
        try store.commit(c.staging)
    }

    /// Kept for `--bench enroll` and tests: prepare + (engine: build + audition) + commit in one go.
    nonisolated static func saveTake(take: [Float], noise: [Float], sampleRate: Double, report: EnrollmentReport,
                                     micUID: String, script: EnrollmentScript, store: VoiceStore,
                                     engine: (any VoiceEngineServices)?) async throws -> VoiceProfile {
        var c = try prepareCandidate(take: take, sampleRate: sampleRate, report: report, micUID: micUID,
                                     script: script, store: store)
        do {
            if let engine, let built = try? await buildAndAudition(c, engine: engine, script: script, store: store) {
                c = built
            }
            try commitCandidate(c, script: script, store: store)
            return c.profile
        } catch {
            store.discard(c.staging)
            throw error
        }
    }
}

/// Qwen3-ASR first, Apple zh-CN when the engine gives nothing (not READY, ASR not loaded).
/// `name` is the one that actually answered last (what `transcript_checker` records).
final class FallbackTranscriber: EnrollmentTranscriber, @unchecked Sendable {
    let primary: any EnrollmentTranscriber
    let fallback: any EnrollmentTranscriber
    private let lock = NSLock()
    private var used: String?

    init(primary: any EnrollmentTranscriber, fallback: any EnrollmentTranscriber) {
        self.primary = primary
        self.fallback = fallback
    }

    var name: String { lock.withLock { used } ?? primary.name }

    func transcribe(_ samples: [Float], sampleRate: Double) async -> String? {
        if let t = await primary.transcribe(samples, sampleRate: sampleRate) {
            lock.withLock { used = primary.name }
            return t
        }
        let t = await fallback.transcribe(samples, sampleRate: sampleRate)
        lock.withLock { used = t == nil ? nil : fallback.name }
        return t
    }
}
