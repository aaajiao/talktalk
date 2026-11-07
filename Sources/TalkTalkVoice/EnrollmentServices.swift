// l10n: zh-Hans (scripts/check-strings.sh)
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import TalkTalkCore

/// Transcribes an enrollment take for the CER check (§9.2 step 4). Returns nil when no
/// recognizer is available; the check is then `pending` rather than failed.
public protocol EnrollmentTranscriber: Sendable {
    func transcribe(_ samples: [Float], sampleRate: Double) async -> String?
    /// Short name recorded with the result ("apple-zh-CN", "qwen3-asr").
    var name: String { get }
}

/// The engine half of enrollment (§9.2 steps 6–7), as the controller sees it. `EngineVoiceServices`
/// implements it on top of a `VoiceEngineBackend` (the real one talks to the engine host). Without
/// an engine the controller is given nil, saves reference.wav + script.txt + profile.json only,
/// marks the audition "待引擎", and the conditioning cache is built at engine warm-up (§9.3).
public protocol VoiceEngineServices: Sendable {
    /// `/v1/voice/build` once per TTS model of the current tier and per clone mode in `modes`.
    func buildConditioning(referenceWAV: Data, scriptText: String, modes: [CloneMode]) async throws -> [ConditioningBlob]
    /// Loads the candidate conditioning, synthesizes the en and de sentences through `/v1/tts` and
    /// checks them (`AuditionCheck`), regenerating a failing sentence once.
    func audition(conditioning: [ConditioningBlob], modes: [Lang: CloneMode], profileID: String,
                  referenceWAV: Data) async throws -> AuditionResult
    /// Loads a saved profile's conditioning (after a discarded candidate replaced it in the engine).
    func loadVoice(_ conditioning: [ConditioningBlob], mode: CloneMode, profileID: String) async throws
    /// `/v1/voice/unload`. false when the engine could not be told (not running: nothing loaded).
    func unloadVoice() async -> Bool
    /// Qwen3-ASR zh, for the transcript row. Answers only while the engine is already READY with
    /// ASR loaded (it never cold-starts the engine); otherwise nil, so Apple zh-CN takes over.
    var transcriber: (any EnrollmentTranscriber)? { get }
    /// Runtime, mlx-audio version and TTS model revisions of the running engine (starts it).
    func identity() async throws -> ConditioningIdentity
    /// What the engine can do right now, without starting it.
    func readiness() async -> EngineReadiness
    /// Enrollment is over: the engine may idle-exit (§7.6 `idleAfterEnrollment`).
    func enrollmentFinished() async
    /// A recording or a save starts: cancel an idle exit scheduled by an earlier `enrollmentFinished`.
    func enrollmentStarted() async
}

extension VoiceEngineServices {
    /// The saved profile's conditioning that matches the running engine (`ConditioningIdentity`);
    /// stale or missing blobs are not returned. Empty means "rebuild".
    public func currentConditioning(_ p: VoiceProfile, store: VoiceStore) async throws -> [ConditioningBlob] {
        let id = try await identity()
        return store.loadConditioning(p).filter { id.isCurrent(key: $0.key, model: $0.model) && p.cloneModes.contains($0.mode) }
            .coveringAll(models: id.modelKeys, modes: p.cloneModes)
    }
}

extension Array where Element == ConditioningBlob {
    /// Self when every model × mode has a blob, else empty (a partial set is rebuilt as a whole).
    func coveringAll(models: [String], modes: [CloneMode]) -> [ConditioningBlob] {
        for m in models { for mode in modes where !contains(where: { $0.model == m && $0.mode == mode }) { return [] } }
        return self
    }
}

/// Which conditioning blobs the running engine can use (§9.3 cache key
/// `<runtime>-mlxaudio<version>-<tts key>@<rev12>-<mode>-<pcm fingerprint 16>`). A blob from another
/// runtime, mlx-audio version, model or revision is stale: it is rebuilt, never loaded.
public struct ConditioningIdentity: Sendable, Equatable {
    public var runtime: String
    /// From READY; nil = unknown (then only runtime, model and revision are compared, as §7.5 does).
    public var mlxAudio: String?
    /// TTS model key → revision, of the current tier (first = main model).
    public var models: [(key: String, rev: String)]

    public init(runtime: String, mlxAudio: String?, models: [(key: String, rev: String)]) {
        self.runtime = runtime
        self.mlxAudio = mlxAudio
        self.models = models
    }

    public var modelKeys: [String] { models.map(\.key) }

    public func isCurrent(key: String, model: String) -> Bool {
        guard let m = models.first(where: { $0.key == model }) else { return false }
        let prefix = mlxAudio.map { "\(runtime)-mlxaudio\($0)-" } ?? "\(runtime)-mlxaudio"
        return key.hasPrefix(prefix) && key.contains("-\(m.key)@\(m.rev.prefix(12))-")
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.runtime == b.runtime && a.mlxAudio == b.mlxAudio && a.models.map(\.key) == b.models.map(\.key)
            && a.models.map(\.rev) == b.models.map(\.rev)
    }
}

/// The engine's state as far as "my voice" cares. Never starts the engine to find out.
public struct EngineReadiness: Sendable, Equatable {
    public enum ASR: Sendable, Equatable { case absent, loading, ready }
    /// READY (TTS loaded).
    public var running: Bool
    /// From the configured roles, not from the running process: `absent` only when the install
    /// has no ASR role (compact16); a configured ASR on an engine that is not READY, or still in
    /// staged readiness, is `loading`.
    public var asr: ASR

    public init(running: Bool, asr: ASR) {
        self.running = running
        self.asr = asr
    }

    /// Not running, ASR role configured.
    public static let stopped = EngineReadiness(running: false, asr: .loading)
}

/// One conditioning cache entry returned by the engine; the app writes it to
/// `conditioning/<key>.safetensors` (§9.3). `key` is the full cache key (engine `key_material`).
public struct ConditioningBlob: Sendable, Equatable {
    public let key: String
    public let data: Data
    public let model: String
    public let mode: CloneMode
    public let samplingKey: String?

    public init(key: String, data: Data, model: String = "", mode: CloneMode = .icl, samplingKey: String? = nil) {
        self.key = key
        self.data = data
        self.model = model
        self.mode = mode
        self.samplingKey = samplingKey
    }
}

/// One audition sentence after the checks.
public struct AuditionClip: Sendable, Equatable {
    public var lang: Lang
    public var text: String
    /// 24 kHz mono, of the last attempt. Kept in memory only, never written (§9.5).
    public var samples: [Float]
    public var attempts: Int
    public var failure: AuditionCheck.Failure?
    public var wer: Double?
    /// Speaker-encoder cosine to the reference (§9.2 step 7, shown on the diagnostics page).
    public var similarity: Double?
    /// The engine has no ASR role (compact16): WER was not measured and does not block.
    public var werPending = false

    public var passed: Bool { failure == nil }
    public var seconds: Double { Double(samples.count) / 24_000 }
}

public struct AuditionResult: Sendable, Equatable {
    public var clips: [AuditionClip]
    /// PlayoutStage fixed gain from the clips' loudness (§3.3), nil if not measurable.
    public var playoutGainDb: Double?

    public var passed: Bool { !clips.isEmpty && clips.allSatisfy(\.passed) }
    public func clip(_ lang: Lang) -> AuditionClip? { clips.first { $0.lang == lang } }

    /// Statuses and numbers only (no samples, no text): for profile.json, `--out` and diagnostics.
    public var summary: Summary {
        Summary(passed: passed, playoutGainDb: playoutGainDb,
                clips: clips.map { .init(lang: $0.lang, attempts: $0.attempts, failure: $0.failure, wer: $0.wer,
                                         similarity: $0.similarity, seconds: ($0.seconds * 100).rounded() / 100,
                                         werPending: $0.werPending ? true : nil) })
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var passed: Bool
        public var playoutGainDb: Double?
        public var clips: [ClipSummary]

        public struct ClipSummary: Codable, Sendable, Equatable {
            public var lang: Lang
            public var attempts: Int
            public var failure: AuditionCheck.Failure?
            public var wer: Double?
            public var similarity: Double?
            public var seconds: Double
            /// true when WER could not be measured (no ASR role); absent otherwise.
            public var werPending: Bool? = nil

            enum CodingKeys: String, CodingKey { case lang, attempts, failure, wer, similarity, seconds, werPending = "wer_pending" }
        }

        enum CodingKeys: String, CodingKey { case passed, playoutGainDb = "playout_gain_db", clips }

        /// The user-facing reason of the first failing sentence.
        public var failureText: String? {
            clips.first { $0.failure != nil }.map { String(appLocalized: "\($0.lang.title)试听：\($0.failure!.text)") }
        }
    }
}

// MARK: - the engine wire, as enrollment needs it

/// The engine calls enrollment makes. `RemoteQwenVoiceBackend` is the real one; tests use a fake.
public protocol VoiceEngineBackend: Sendable {
    /// TTS model keys of the current tier (one at max: no 0.6B hot spare, m0-results).
    func build(reference24k: [Float], refText: String, model: String, mode: CloneMode) async throws -> (key: String, blob: Data)
    /// Returns once the engine reports the voice ready.
    func load(blob: Data, model: String, key: String, mode: CloneMode, profileID: UUID) async throws
    func unload() async throws -> Bool
    func synthesize(text: String, lang: Lang, seed: Int) async throws -> VoiceSynthesis
    func transcribe(samples16k: [Float], hint: Lang) async throws -> String
    /// nil when a clip is too short for the speaker encoder.
    func speakerSimilarity(reference24k: [Float], sample24k: [Float]) async throws -> Double?
    func identity() async throws -> ConditioningIdentity
    func readiness() async -> EngineReadiness
    func enrollmentFinished() async
    func enrollmentStarted() async
}

public struct VoiceSynthesis: Sendable, Equatable {
    public var samples: [Float]
    public var runaway: Bool
    public var short: Bool
    public var expectedSeconds: Double?

    public init(samples: [Float], runaway: Bool = false, short: Bool = false, expectedSeconds: Double? = nil) {
        self.samples = samples
        self.runaway = runaway
        self.short = short
        self.expectedSeconds = expectedSeconds
    }
}

public enum VoiceEngineError: Error, Equatable, CustomStringConvertible {
    case noTTSModel
    case unsupportedMode(CloneMode)
    case badReference
    case noConditioning(CloneMode)
    /// ASR is still loading after the wait: an engine state, not a failed check.
    case asrNotReady

    public var description: String {
        switch self {
        case .asrNotReady: "ASR model did not become ready"
        case .noTTSModel: "engine reports no TTS model"
        case .unsupportedMode(let m): "the engine builds only ICL conditioning (asked for \(m.rawValue))"
        case .badReference: "reference.wav is not 24 kHz mono PCM16"
        case .noConditioning(let m): "no conditioning blob for mode \(m.rawValue)"
        }
    }
}

/// `VoiceEngineServices` over any backend: the build loop and the audition rules (§9.2 steps 6–7).
public struct EngineVoiceServices: VoiceEngineServices {
    public let backend: any VoiceEngineBackend
    /// 24 kHz → 16 kHz for read-back. Injected so tests can skip AVAudioConverter.
    public let to16k: @Sendable ([Float], Double) -> [Float]
    /// How long the audition waits for a loading ASR model before calling it an engine error.
    public let asrWait: Duration
    public let asrPoll: Duration

    public init(backend: any VoiceEngineBackend,
                to16k: @escaping @Sendable ([Float], Double) -> [Float] = { (try? Resampler.resample($0, from: $1, to: 16_000)) ?? [] },
                asrWait: Duration = .seconds(30), asrPoll: Duration = .milliseconds(250)) {
        self.backend = backend
        self.to16k = to16k
        self.asrWait = asrWait
        self.asrPoll = asrPoll
    }

    public var transcriber: (any EnrollmentTranscriber)? { EngineZhTranscriber(backend: backend, to16k: to16k) }
    public func identity() async throws -> ConditioningIdentity { try await backend.identity() }
    public func readiness() async -> EngineReadiness { await backend.readiness() }
    public func enrollmentFinished() async { await backend.enrollmentFinished() }
    public func enrollmentStarted() async { await backend.enrollmentStarted() }

    /// ASR for the read-back: `.absent` → skip WER; `.loading` → wait up to `asrWait`; still
    /// loading → `VoiceEngineError.asrNotReady` (an engine error: saved as pending_engine).
    func readbackAvailable() async throws -> Bool {
        let end = ContinuousClock.now + asrWait
        while true {
            switch await backend.readiness().asr {
            case .absent: return false
            case .ready: return true
            case .loading:
                guard ContinuousClock.now < end else { throw VoiceEngineError.asrNotReady }
                try await Task.sleep(for: asrPoll)
            }
        }
    }

    public func buildConditioning(referenceWAV: Data, scriptText: String, modes: [CloneMode]) async throws -> [ConditioningBlob] {
        guard let ref = Self.reference(referenceWAV) else { throw VoiceEngineError.badReference }
        let models = try await backend.identity().modelKeys
        guard !models.isEmpty else { throw VoiceEngineError.noTTSModel }
        var out: [ConditioningBlob] = []
        for model in models {
            for mode in Self.unique(modes) {
                let r = try await backend.build(reference24k: ref, refText: scriptText, model: model, mode: mode)
                out.append(ConditioningBlob(key: r.key, data: r.blob, model: model, mode: mode))
            }
        }
        return out
    }

    public func audition(conditioning: [ConditioningBlob], modes: [Lang: CloneMode], profileID: String,
                         referenceWAV: Data) async throws -> AuditionResult {
        let ref = Self.reference(referenceWAV) ?? []
        let id = UUID(uuidString: profileID) ?? UUID()
        var clips: [AuditionClip] = []
        var loaded: ConditioningBlob?
        var measureWER = false
        for lang in AuditionCheck.languages {
            let mode = modes[lang] ?? .icl
            // The current tier's main model is the first one built.
            guard let blob = conditioning.first(where: { $0.mode == mode }) else { throw VoiceEngineError.noConditioning(mode) }
            if loaded != blob {
                let first = loaded == nil
                try await backend.load(blob: blob.data, model: blob.model, key: blob.key, mode: mode, profileID: id)
                loaded = blob
                // Asked once the load has started the engine: before READY a configured ASR role
                // reads as loading, never as "no ASR" (second review, item 7).
                if first { measureWER = try await readbackAvailable() }
            }
            let text = AuditionCheck.sentences[lang]!
            let handle = VoiceHandle(profileID: id, conditioningKey: blob.key, mode: mode,
                                     model: EngineID(name: blob.model, revision: "", placement: .engineGPU),
                                     samplingKey: blob.samplingKey)
            var seed = TTSSeed.make(voice: handle, language: lang)
            var clip = AuditionClip(lang: lang, text: text, samples: [], attempts: 0)
            for attempt in 0..<AuditionCheck.maxAttempts {
                if attempt > 0 { seed = TTSSeed.next(seed, attempt: attempt) }
                let s = try await backend.synthesize(text: text, lang: lang, seed: Int(seed))
                // A read-back error is an engine error (thrown), not a failed check.
                let readback: String? = measureWER && !s.samples.isEmpty
                    ? try await backend.transcribe(samples16k: to16k(s.samples, 24_000), hint: lang) : nil
                let take = AuditionCheck.Take(audioSeconds: Double(s.samples.count) / 24_000,
                                              expectedSeconds: s.expectedSeconds, engineRunaway: s.runaway,
                                              engineShort: s.short, readback: readback)
                let verdict = AuditionCheck.evaluate(take, text: text)
                clip.samples = s.samples
                clip.attempts = attempt + 1
                clip.failure = verdict.failure
                clip.wer = verdict.wer
                clip.werPending = !measureWER
                if verdict.failure == nil { break }
            }
            if !ref.isEmpty, !clip.samples.isEmpty {
                clip.similarity = try? await backend.speakerSimilarity(reference24k: ref, sample24k: clip.samples)
            }
            clips.append(clip)
        }
        let passing = clips.filter(\.passed).map(\.samples)
        return AuditionResult(clips: clips, playoutGainDb: VoiceGains.playoutGainDb(auditionClips: passing))
    }

    public func loadVoice(_ conditioning: [ConditioningBlob], mode: CloneMode, profileID: String) async throws {
        guard let blob = conditioning.first(where: { $0.mode == mode }) else { throw VoiceEngineError.noConditioning(mode) }
        try await backend.load(blob: blob.data, model: blob.model, key: blob.key, mode: mode,
                               profileID: UUID(uuidString: profileID) ?? UUID())
    }

    public func unloadVoice() async -> Bool {
        (try? await backend.unload()) ?? false
    }

    static func reference(_ wav: Data) -> [Float]? {
        guard let d = WAVFile.decodePCM16(wav), d.sampleRate == 24_000 else { return nil }
        return d.samples
    }

    static func unique(_ modes: [CloneMode]) -> [CloneMode] {
        var seen: [CloneMode] = []
        for m in modes where !seen.contains(m) { seen.append(m) }
        return seen.isEmpty ? [.icl] : seen
    }
}

/// Qwen3-ASR (engine) for the enrollment transcript row. Only used once the engine is installed;
/// the take stays on this Mac either way (§9.5).
public struct EngineZhTranscriber: EnrollmentTranscriber {
    public let name = "qwen3-asr"
    let backend: any VoiceEngineBackend
    let to16k: @Sendable ([Float], Double) -> [Float]

    public func transcribe(_ samples: [Float], sampleRate: Double) async -> String? {
        // Never cold-starts the engine for a transcript: only an engine already READY with ASR.
        let r = await backend.readiness()
        guard r.running, r.asr == .ready else { return nil }
        let s = sampleRate == 16_000 ? samples : to16k(samples, sampleRate)
        guard !s.isEmpty else { return nil }
        return try? await backend.transcribe(samples16k: s, hint: .zh)
    }
}

/// §9.2 "实现补充": a transcript row saved as `pending` (no on-device recognizer at recording time)
/// is checked again with Qwen3-ASR once the engine is ready. Rewrites only profile.json (0600, via a
/// temporary file and rename). A failing re-check keeps the profile but marks it, so settings can
/// suggest re-recording; it never deletes anything.
public enum TranscriptRecheck {
    public enum Outcome: Equatable, Sendable {
        case notNeeded
        case unavailable
        case checked(CheckStatus, cer: Double)
    }

    public static func run(store: VoiceStore, transcriber: any EnrollmentTranscriber) async -> Outcome {
        guard var profile = try? store.loadProfile(), profile.checks.status[CheckID.transcript.rawValue] == .pending else {
            return .notNeeded
        }
        let expected = profile.identity
        let dir = store.voiceURL
        guard let wav = try? Data(contentsOf: dir.appendingPathComponent(VoiceStore.referenceName)),
              let ref = WAVFile.decodePCM16(wav),
              let script = try? store.loadScript(profile),
              let text = await transcriber.transcribe(ref.samples, sampleRate: Double(ref.sampleRate)) else {
            return .unavailable
        }
        let c = TranscriptComparison.compare(transcript: text, script: script)
        let row = EnrollmentChecks.transcriptCheck(c)
        profile.checks.status[CheckID.transcript.rawValue] = row.status
        profile.checks.measurements.cer = c.cer
        profile.checks.measurements.hanShare = c.hanShare
        profile.checks.measurements.missingClauses = c.missingClauses
        profile.transcriptChecker = transcriber.name
        do {
            // Re-recorded or deleted while we were waiting on the ASR: leave the new state alone.
            try store.replaceProfile(profile, expecting: expected)
        } catch {
            return .unavailable
        }
        return .checked(row.status, cer: c.cer)
    }
}

/// Apple on-device zh-CN recognition (SFSpeechRecognizer with `requiresOnDeviceRecognition`).
/// Never uses the server path: the take is personal data and does not leave the Mac (§9.5).
/// No contextual strings: biasing toward the script would hide real misreadings.
public struct AppleZhTranscriber: EnrollmentTranscriber {
    public let name = "apple-zh-CN"
    public let timeoutSeconds: Double

    public init(timeoutSeconds: Double = 30) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Asks for speech-recognition permission once (the system prompt names TalkTalk-Dev.app).
    public static func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status != .notDetermined { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    public func transcribe(_ samples: [Float], sampleRate: Double) async -> String? {
        guard await Self.requestAuthorization() else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = false
        request.taskHint = .dictation
        request.append(buffer)
        request.endAudio()

        let once = Once()
        let timeout = timeoutSeconds
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { cont.resume(returning: nil) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run {
                    task.cancel()
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
