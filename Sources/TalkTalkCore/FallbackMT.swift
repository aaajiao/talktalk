import Foundation
import Synchronization

/// SPEAK's cloud/Apple combination (§4.2, §5.4). Cloud stays preferred until it fails or
/// reaches its deadline; Apple starts at hedge time and its result waits as the fallback.
/// Both outputs pass the same text gate. Apple number/term mismatches never reach TTS.
public actor FallbackMT: SpeakTranslator {
    private let cloud: (any SpeakCloudMT)?
    private let apple: (any MTEngine)?
    private let profile: PolicyProfile
    private let gate: TargetTextGate
    private let glossary: @Sendable () -> [GlossaryEntry]
    private let prepareApple: @Sendable (MTSession) async throws -> Void
    private let log: EventLog?
    private var appleLatency = RollingP95()
    private struct Running {
        let task: Task<SpeakMTOutcome, Error>
        let apple: AppleAttempt
    }
    private var running: [JobID: Running] = [:]

    /// `prepareApple` is supplied by the app (AppleTranslationMT.prepare), keeping Core
    /// independent of Apple's framework. The glossary snapshot is shared with OpenAIMT.
    public init(cloud: (any SpeakCloudMT)?, apple: (any MTEngine)?, profile: PolicyProfile,
                gate: TargetTextGate, glossary: @escaping @Sendable () -> [GlossaryEntry] = { [] },
                prepareApple: @escaping @Sendable (MTSession) async throws -> Void = { _ in },
                log: EventLog? = nil) {
        self.cloud = cloud; self.apple = apple; self.profile = profile; self.gate = gate
        self.glossary = glossary; self.prepareApple = prepareApple; self.log = log
    }

    public func pressBegan() async { await cloud?.keyDown() }

    public func prepare(targets: [Lang]) async { await prepare(source: .zh, targets: targets) }

    public func prepare(source: Lang, targets: [Lang]) async {
        for target in Set(targets) {
            guard let session = MTSession.speak(source: source, target: target) else { continue }
            try? await prepareApple(session)
        }
    }

    public func translate(_ request: SpeakMTRequest) async throws -> SpeakMTOutcome {
        try Task.checkCancellation()
        guard let session = MTSession.speak(source: request.source, target: request.target), running[request.job] == nil else { return .blocked(.unavailable) }
        let terms = Array(glossary().prefix(30))
        let policy = profile.speakHedgePolicy
        let appleP95 = appleLatency.value.map { Int($0.rounded()) }
        let deadlineMs = policy.deadlineMs(precedingAudioMs: request.precedingAudioMs,
                                          ttsFirstChunkP95Ms: request.ttsFirstChunkP95Ms, appleP95Ms: appleP95,
                                          appleLate: request.appleLate)
        let mt = MTRequest(job: request.job, session: session, text: request.text, isFinalChunk: true, mode: request.mode,
                           priority: .p1Speak, deadline: HostClock.now() + UInt64(max(0, deadlineMs)) * 1_000_000,
                           maxOutputTokens: profile.speak.mt.maxOutputTokens(for: request.target) ?? 56,
                           history: request.history)
        let attempt = AppleAttempt(backend: apple, request: mt)
        let context = SpeakCloudContext(precedingAudioMs: request.precedingAudioMs, maskedMs: request.maskedMs,
                                        ttsFirstChunkP95Ms: request.ttsFirstChunkP95Ms, appleP95Ms: appleP95,
                                        appleLate: request.appleLate, onStartApple: { attempt.start() })
        let cloud = self.cloud, gate = self.gate, log = self.log
        let task = Task {
            try await Self.run(request, mt: mt, cloud: cloud, apple: attempt, context: context,
                               glossary: terms, gate: gate, log: log)
        }
        running[request.job] = Running(task: task, apple: attempt)
        defer {
            running[request.job] = nil
            if let elapsed = attempt.elapsedMs { appleLatency.record(elapsed) }
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel()
                attempt.cancel()
            }
            attempt.cancel()
            await apple?.cancel(request.job)
            try Task.checkCancellation()
            return result
        } catch {
            task.cancel(); attempt.cancel()
            await cloud?.cancel(request.job)
            await apple?.cancel(request.job)
            throw error
        }
    }

    public func cancel(_ job: JobID) async {
        guard let active = running[job] else { return }
        active.task.cancel(); active.apple.cancel()
        await cloud?.cancel(job)
        await apple?.cancel(job)
    }

    private static func run(_ request: SpeakMTRequest, mt: MTRequest, cloud: (any SpeakCloudMT)?,
                            apple: AppleAttempt, context: SpeakCloudContext, glossary: [GlossaryEntry],
                            gate: TargetTextGate, log: EventLog?) async throws -> SpeakMTOutcome {
        if let cloud {
            do {
                try await cloud.setContext(mt.session, glossary: glossary)
                let result = try await cloud.translate(mt, speak: context)
                try Task.checkCancellation()
                return checked(result, request: request, backend: .openAI, glossary: glossary, gate: gate)
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        // Only codes/IDs enter the event log; provider errors may contain source text.
        log?.event("mt.fallback", ["job": .int(Int(request.job)), "reason": .tag(cloud == nil ? "noCloud" : "cloudUnavailable")])
        do {
            let result = try await apple.value()
            try Task.checkCancellation()
            return checked(result, request: request, backend: .apple, glossary: glossary, gate: gate)
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return .blocked(.unavailable) }
    }

    private static func checked(_ result: MTResult, request: SpeakMTRequest, backend: HUDModel.MTSource,
                                glossary: [GlossaryEntry], gate: TargetTextGate) -> SpeakMTOutcome {
        var verdict = gate.check(result.text, target: request.target)
        if request.target != .zh, verdict == .reject(.containsCJK), let recovered = gate.transliterateShortHanRuns(result.text) {
            verdict = gate.check(recovered, target: request.target)
        }
        let text: String
        switch verdict {
        case .pass(let clean): text = clean
        case .skip:
            // P5 treats an empty successful result as a silent skip, never as a TTS request.
            return .text("", backend: backend, numberWarning: nil, hedge: result.hedge)
        case .reject: return .blocked(.gateRejected)
        }
        let numbers = NumberGuard.check(source: request.text, sourceLang: request.source, target: text, targetLang: request.target, glossary: glossary)
        guard numbers.isOK || backend == .openAI else { return .blocked(.numberMismatch) }
        let warning = numbers.isOK ? nil : (numbers.sourceTexts + numbers.missingTerms).joined(separator: "、")
        return .text(text, backend: backend, numberWarning: warning, hedge: result.hedge)
    }
}

/// The hedge callback is synchronous. This small owner starts Apple once without hopping to
/// an actor, and retains cancellation even if it arrives before the callback.
private final class AppleAttempt: Sendable {
    private struct State {
        var task: Task<MTResult, Error>?
        var cancelled = false
        var elapsedMs: Double?
    }
    private let state = Mutex(State())
    private let backend: (any MTEngine)?
    private let request: MTRequest
    init(backend: (any MTEngine)?, request: MTRequest) { self.backend = backend; self.request = request }
    var elapsedMs: Double? { state.withLock { $0.elapsedMs } }

    func start() {
        state.withLock { s in
            guard s.task == nil, !s.cancelled, let backend else { return }
            let request = request
            s.task = Task {
                try Task.checkCancellation()
                let start = ContinuousClock.now
                let result = try await backend.translate(request)
                let elapsed = Double((ContinuousClock.now - start) / .microseconds(1)) / 1000
                self.state.withLock { $0.elapsedMs = elapsed }
                return result
            }
        }
    }

    func value() async throws -> MTResult {
        start()
        guard let task = state.withLock({ $0.task }) else {
            try Task.checkCancellation()
            throw MTError.cloudUnavailable("appleUnavailable")
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { self.cancel() }
    }

    func cancel() {
        state.withLock { s in s.cancelled = true; s.task?.cancel() }
    }
}
