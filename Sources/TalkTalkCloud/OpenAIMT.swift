import Foundation
import TalkTalkCore

/// The OpenAI MT backend (ARCHITECTURE.md §4.1, §5.4, §6.4, §13): `MTEngine` with placement
/// `.network`. One sentence = one `HedgedRequest` (A first; B per the hedge policy: SPEAK yes,
/// LISTEN off by default, `listen.finalMT.hedge`). The deadline comes from the caller
/// (`MTRequest.deadline`, host time); without one, the policy's `totalDeadlineMs` applies.
///
/// It never produces Apple text itself: when the cloud has no usable result (breaker open,
/// paused, offline, deadline, 429, transport error, gate reject) `translate` throws
/// `MTError.cloudUnavailable(reason)` and the caller (ListenPipeline, FallbackMT) uses Apple.
/// A result that only arrives after the caller's deadline is discarded and logged as `mt.late`.
///
/// Logs only codes, timings and ids (`log`), never source or target text, never the key and
/// never `error.message` (OpenAIErrorInfo does not decode it).
public actor OpenAIMT: SpeakCloudMT {
    public struct Configuration: Sendable, Equatable {
        public var model: String
        /// "none" (normal) or "low" (yellow path, §11).
        public var effort: String
        /// Added to `max_output_tokens` when effort is not none (§11; M0-T4 ⑦: 0 reasoning tokens
        /// at effort low on one sentence per tier, so a small budget).
        public var reasoningBudget: Int
        /// Settings › 翻译: send requests with OpenAI's Fast mode.
        public var fastMode: Bool

        public init(model: String, effort: String, reasoningBudget: Int = 64, fastMode: Bool = false) {
            self.model = model; self.effort = effort; self.reasoningBudget = reasoningBudget
            self.fastMode = fastMode
        }
    }

    static let fastTier = "fast"

    public nonisolated let id: EngineID
    public nonisolated let client: OpenAIClient

    private let profile: PolicyProfile
    private let builder: OpenAIRequestBuilder
    private let config: Configuration
    private let gate: TargetTextGate?
    private let log: EventLog?
    private var health: CloudHealth
    private var resets: SessionResetPolicy
    private var glossaries: [MTSession: [GlossaryEntry]] = [:]
    private var inFlight: [JobID: Task<HedgedRequest.Outcome, Never>] = [:]
    private var activeJobs: Set<JobID> = []
    private var cancelledJobs: Set<JobID> = []
    private let t0 = ContinuousClock.now
    public private(set) var keepWarm: KeepWarm?
    private var pressWarm: (id: UUID, task: Task<Void, Never>)?
    private let keyCache: MeetingKeyCache?
    private var fastModeOn: Bool

    /// - Parameters:
    ///   - client: the app's OpenAIClient (two `.ephemeral` sessions A/B, key from the Keychain).
    ///   - gate: TargetTextGate for SPEAK results (en/de); nil skips the gate (tests, LISTEN-only).
    ///   - log: the session's EventLog; nil = no events.
    ///   - keyCache: the meeting's copy of the key behind `client`, closed by `endMeeting`.
    public init(client: OpenAIClient, profile: PolicyProfile, prompts: MTPrompts, configuration: Configuration,
                gate: TargetTextGate? = nil, log: EventLog? = nil, keyCache: MeetingKeyCache? = nil) {
        self.client = client
        self.profile = profile
        self.builder = OpenAIRequestBuilder(cloud: profile.cloud, prompts: prompts)
        self.config = configuration
        self.gate = gate
        self.log = log
        self.health = CloudHealth(cloud: profile.cloud)
        self.resets = SessionResetPolicy(config: profile.cloud.sessionReset)
        self.id = EngineID(name: "openai", revision: configuration.model, placement: .network)
        self.keyCache = keyCache
        self.fastModeOn = configuration.fastMode
    }

    /// For the running app: the bundle's key item, the bundled PolicyProfile / prompts / gate
    /// patterns, and the selected model and effort from Settings › 翻译 (`TranslationPreferences`).
    /// Returns nil when there is no key (the caller then uses Apple only, §11).
    /// `forMeeting` holds the key for the meeting, reading it now rather than during a sentence.
    public static func forCurrentApp(bundleID: String? = Bundle.main.bundleIdentifier, model: String, effort: String,
                                     log: EventLog?, knownPresence: Bool? = nil, forMeeting: Bool = false,
                                     fastMode: Bool = false) throws -> OpenAIMT? {
        func measured<T>(_ stage: String, _ operation: () throws -> T) rethrows -> T {
            let started = HostClock.now()
            defer {
                log?.event("cloud.prepare", ["stage": .tag(stage),
                    "ms": .int(HostClock.ms(started, to: HostClock.now()))])
            }
            return try operation()
        }
        let secret: KeychainSecret? = measured("key_exists") {
            guard let bid = bundleID, let secret = KeychainSecret.openAI(bundleID: bid),
                  resolveKeyPresence(knownPresence, query: { secret.exists() }) else { return nil }
            return secret
        }
        guard let secret else { return nil }
        let profile = try measured("profile") { try PolicyProfile.loadDefault() }
        let readKey: @Sendable () throws -> String = { String(decoding: try secret.read(), as: UTF8.self) }
        let keyCache = forMeeting ? MeetingKeyCache(read: readKey) : nil
        let keyProvider: @Sendable () throws -> String
        if let keyCache { keyProvider = { try keyCache.value() } } else { keyProvider = readKey }
        let client = measured("client") {
            OpenAIClient(cloud: profile.cloud, keyProvider: keyProvider, sink: OpenAIMT.eventSink(log))
        }
        let (gate, prompts) = try measured("resources") {
            let gate = try? TargetTextGate(config: profile.speak.mt.targetGate, patterns: try GatePatterns.loadDefault())
            return (gate, try MTPrompts.loadDefault())
        }
        if let keyCache {
            // Off the caller's thread: a Keychain prompt must not hold up session setup.
            Task.detached(priority: .userInitiated) {
                let started = HostClock.now()
                let ok = (try? keyCache.value()) != nil
                log?.event("cloud.prepare", ["stage": .tag("key_read"), "ok": .bool(ok),
                                             "ms": .int(HostClock.ms(started, to: HostClock.now()))])
            }
        }
        return OpenAIMT(client: client, profile: profile, prompts: prompts,
                        configuration: Configuration(model: model, effort: effort, fastMode: fastMode),
                        gate: gate, log: log, keyCache: keyCache)
    }

    /// Reuse only current presence metadata; this says nothing about the key's value.
    /// Callers without resolved metadata retain the original existence check.
    static func resolveKeyPresence(_ known: Bool?, query: () -> Bool) -> Bool {
        known ?? query()
    }

    /// CloudEvent → EventLog, codes and timings only.
    public static func eventSink(_ log: EventLog?) -> CloudEventSink {
        guard let log else { return { _ in } }
        return { e in
            switch e {
            case .error(let leg, let status, let info):
                log.event("cloud.error", ["leg": .tag(leg.rawValue), "status": .int(status),
                                          "code": .tag(info?.code ?? "-"), "type": .tag(info?.type ?? "-")])
            case .hedge(let h):
                log.event("mt.hedge", ["fired": .bool(h.fired), "winner": .tag(h.winner.rawValue),
                                       "reason": .tag(h.reason?.rawValue ?? "-"), "ms": .int(h.ms)])
            case .validation(let leg, let reject, let missing, let partial):
                if let reject { log.event("mt.validate", ["leg": .tag(leg.rawValue), "reject": .tag(reject), "partial": .bool(partial)]) }
                if missing { log.event("mt.store_echo_missing", ["leg": .tag(leg.rawValue)]) }
            case .keepWarm(let leg, let ok, let ms):
                log.event("cloud.keepwarm", ["leg": .tag(leg.rawValue), "ok": .bool(ok), "ms": .double(ms)])
            case .sessionReset(let leg, let reason):
                log.event("cloud.session_reset", ["leg": .tag(leg.rawValue), "reason": .tag(reason)])
            case .breaker(let s):
                log.event("cloud.breaker", ["state": .tag(s)])
            case .fallback(let s):
                log.event("mt.fallback", ["reason": .tag(s)])
            case .request(let leg, let path, let id, let keyReadMs):
                log.event("cloud.request", ["leg": .tag(leg.rawValue), "req": .tag(id),
                                            "kind": .tag(path.hasSuffix("/responses") ? "responses" : "models"),
                                            "key_read_ms": .double(keyReadMs)])
            case .metrics(let m):
                log.event("cloud.metrics", metricsFields(m))
            case .response:
                break
            }
        }
    }

    /// Connection timing for one attempt, joined to `mt.request` by `req`. Absent values stay absent.
    static func metricsFields(_ m: RequestMetrics) -> [String: EventLog.Value] {
        var fields: [String: EventLog.Value] = ["leg": .tag(m.leg.rawValue)]
        if let id = m.clientRequestID { fields["req"] = .tag(id) }
        if let name = m.protocolName { fields["protocol"] = .tag(name.replacingOccurrences(of: "/", with: "_")) }
        if let reused = m.reusedConnection { fields["reused"] = .bool(reused) }
        for (name, value) in [("connect_ms", m.connectMs), ("tls_ms", m.tlsMs), ("fetch_to_request_ms", m.fetchToRequestMs),
                              ("request_to_response_ms", m.requestToResponseStartMs), ("task_ms", m.taskMs)] {
            if let value { fields[name] = .double(value) }
        }
        return fields
    }

    private func nowMs() -> Int { Int((ContinuousClock.now - t0) / .milliseconds(1)) }

    // MARK: keep-warm and network state (meeting start / end, NetworkHealth)

    /// Starts keep-warm on A (and B when SPEAK hedging is on) while `isEnabled` (meeting mode,
    /// a cloud direction on, key present) holds (§6.4).
    public func startKeepWarm(isEnabled: @escaping @Sendable () -> Bool, warmB: @escaping @Sendable () -> Bool) async {
        if keepWarm == nil {
            let kw = KeepWarm(client: client, cloud: profile.cloud, model: config.model, isEnabled: isEnabled, warmB: warmB,
                              onResult: { [weak self] leg, ok in
                                  guard let self else { return }
                                  Task { await self.keepWarmResult(leg, ok: ok) }
                              }, sink: Self.eventSink(log))
            keepWarm = kw
        }
        await keepWarm?.start()
    }

    public func stopKeepWarm() async {
        pressWarm?.task.cancel(); pressWarm = nil
        await keepWarm?.stop()
    }

    /// The key leaves memory first; keep-warm can take a moment to wind down.
    public func endMeeting() async {
        keyCache?.close()
        await stopKeepWarm()
    }

    /// Scheduling the re-warm must not hold up the press's ASR/session setup.
    public func keyDown() async {
        guard pressWarm == nil, let warm = keepWarm else { return }
        let id = UUID()
        let task = Task {
            await warm.onKeyDown()
            if self.pressWarm?.id == id { self.pressWarm = nil }
        }
        pressWarm = (id, task)
    }

    private func keepWarmResult(_ leg: Leg, ok: Bool) {
        apply(resets.recordKeepWarm(leg, ok: ok))
    }

    /// NetworkHealth changes (§6.4): offline → straight to Apple; path change / wake → rebuild.
    public func network(_ change: NetworkHealth.Change) {
        switch change {
        case .offline: health.setOffline(true)
        case .online: health.setOffline(false)
        case .pathChanged: health.setOffline(false); apply(resets.onPathChange())
        }
    }

    public func didWake() { apply(resets.onWake()) }

    /// A fixed key or a new meeting clears the sticky pause (401/403/quota).
    public func clearPause() { health.clearPause() }

    private func apply(_ rs: [SessionResetPolicy.Reset]) {
        for r in rs {
            client.rebuild(r.leg)
            log?.event("cloud.session_reset", ["leg": .tag(r.leg.rawValue), "reason": .tag(r.reason)])
        }
    }

    // MARK: MTEngine

    public func setContext(_ s: MTSession, glossary: [GlossaryEntry]) async throws {
        glossaries[s] = Array(glossary.prefix(30))   // ≤30 entries take effect (§11 术语表)
    }

    public func cancel(_ job: JobID) async {
        if activeJobs.contains(job) { cancelledJobs.insert(job) }
        inFlight[job]?.cancel()
    }

    public func translate(_ r: MTRequest) async throws -> MTResult {
        try await translateRequest(r, speak: nil)
    }

    public func translate(_ r: MTRequest, speak: SpeakCloudContext) async throws -> MTResult {
        var request = r
        if request.deadline == nil {
            let ms = profile.speakHedgePolicy.deadlineMs(precedingAudioMs: speak.precedingAudioMs,
                ttsFirstChunkP95Ms: speak.ttsFirstChunkP95Ms, appleP95Ms: speak.appleP95Ms, appleLate: speak.appleLate)
            request.deadline = HostClock.now() + UInt64(max(0, ms)) * 1_000_000
        }
        return try await translateRequest(request, speak: speak)
    }

    private func translateRequest(_ r: MTRequest, speak: SpeakCloudContext?) async throws -> MTResult {
        try Task.checkCancellation()
        activeJobs.insert(r.job)
        defer { activeJobs.remove(r.job); cancelledJobs.remove(r.job) }
        let received = HostClock.now()
        let dir: CloudHealth.Direction = r.session.isSpeak ? .speak : .listen
        let tag: Int = Int(r.job)

        if case .apple(let why) = health.gate(dir, now: nowMs()) {
            log?.event("mt.gate", ["job": .int(tag), "session": .tag(r.session.rawValue), "apple": .tag(why)])
            throw MTError.cloudUnavailable(why)
        }

        var policy = r.session.isSpeak ? profile.speakHedgePolicy : profile.listenHedgePolicy
        if config.effort != "none" { policy.hedge.enabled = false }   // yellow path: SPEAK hedging off (§11)
        let deadlineMs: Int
        if let d = r.deadline {
            deadlineMs = HostClock.ms(received, to: d)
            guard deadlineMs > 0 else {
                log?.event("mt.late", ["job": .int(tag), "session": .tag(r.session.rawValue), "before_send": .bool(true)])
                health.releaseProbes(dir)
                throw MTError.cloudUnavailable("deadline")
            }
        } else {
            deadlineMs = policy.totalDeadlineMs
        }

        var acceptedDeadline = r.deadline
        var keptFirstAfterRetry = false
        var outputStarted = received
        var outcome = try await run(r, policy: policy, deadlineMs: deadlineMs, kind: .normal, speak: speak)
        var text = outcome.text?.trimmingCharacters(in: .whitespacesAndNewlines)

        // SPEAK checks (§5.4): TargetTextGate, then NumberGuard. One retry, double-sent.
        if r.session.isSpeak, let t = text, outcome.decision.outcome.winner != .apple {
            let target = r.session.direction.target
            var retryReason: String?
            if let gate {
                switch gate.check(t, target: target) {
                case .pass(let clean): text = clean
                case .skip: text = TargetTextGate.noneMarker
                case .reject(let why): retryReason = "gate:" + why.rawValue
                }
            }
            if retryReason == nil, let t2 = text, !t2.isEmpty, t2 != TargetTextGate.noneMarker {
                let c = NumberGuard.check(source: r.text, sourceLang: r.session.direction.source, target: t2, targetLang: target, glossary: glossaries[r.session] ?? [])
                if NumberGuard.action(c, backend: .openAI, maskedMs: speak?.maskedMs ?? 0, alreadyRetried: false, policy: policy) == .retry {
                    retryReason = "numberGuard"
                }
            }
            if let why = retryReason {
                log?.event("mt.guard_retry", ["job": .int(tag), "reason": .tag(why)])
                let elapsed = HostClock.ms(received, to: HostClock.now())
                let ahead = speak.map { max(0, $0.precedingAudioMs - elapsed) }
                let retryMs = policy.guardRetryDeadlineMs(precedingAudioMs: ahead,
                                                         ttsFirstChunkP95Ms: speak?.ttsFirstChunkP95Ms ?? 400)
                var rr = r
                rr.deadline = HostClock.now() + UInt64(max(0, retryMs)) * 1_000_000
                rr.strictTerms = Array(Set(r.strictTerms + NumberGuard.sourceMentions(in: r.text, language: r.session.direction.source).map(\.text)))
                // A failed number retry retains the first translation with a warning. A text
                // gate retry can still recover short Han names locally before giving up.
                let firstOutcome = outcome
                let retryStarted = HostClock.now()
                keptFirstAfterRetry = true
                do {
                    let retried = try await run(rr, policy: policy, deadlineMs: retryMs, kind: .guardRetry, speak: speak)
                    if retried.decision.outcome.winner != .apple, let candidate = retried.text {
                        outcome = retried
                        outputStarted = retryStarted
                        keptFirstAfterRetry = false
                        text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { outcome = firstOutcome }
                acceptedDeadline = rr.deadline
                if let candidate = text, let gate {
                    var verdict = gate.check(candidate, target: target)
                    if target != .zh, verdict == .reject(.containsCJK), let recovered = gate.transliterateShortHanRuns(candidate) {
                        verdict = gate.check(recovered, target: target)
                    }
                    switch verdict {
                    case .pass(let clean): text = clean
                    case .skip: text = TargetTextGate.noneMarker
                    case .reject(let why): throw MTError.cloudUnavailable("gate:" + why.rawValue)
                    }
                }
                // A remaining number mismatch plays with the HUD warning (caller re-checks).
            }
        }

        let finished = HostClock.now()
        guard outcome.decision.outcome.winner != .apple, let out = text else {
            let reason = outcome.decision.pauseReason.map { "paused:" + $0 }
                ?? outcome.decision.fallback.map { $0.rawValue } ?? "noResult"
            if outcome.decision.fallback == .deadline {
                log?.event("mt.late", ["job": .int(tag), "session": .tag(r.session.rawValue), "deadline_ms": .int(deadlineMs)])
            }
            throw MTError.cloudUnavailable(reason)
        }
        if let d = acceptedDeadline, finished > d, !keptFirstAfterRetry {
            // Arrived after the caller's deadline: never shown (§5.1), only logged.
            log?.event("mt.late", ["job": .int(tag), "session": .tag(r.session.rawValue),
                                   "over_ms": .int(HostClock.ms(d, to: finished))])
            throw MTError.cloudUnavailable("late")
        }
        let echo = outcome.winnerEcho
        let w = outcome.decision.outcome.winner == .B ? outcome.legs[.B] : outcome.legs[.A]
        let firstOutput: HostTime? = w?.firstDeltaMs.map { outputStarted + UInt64(max(0, $0)) * 1_000_000 }
        return MTResult(text: out, tokens: echo?.outputTokens ?? 0, reasoningTokens: echo?.reasoningTokens ?? 0,
                        engine: id, hedge: outcome.decision.outcome,
                        timing: StageTiming(received: received, started: received, firstOutput: firstOutput, finished: finished))
    }

    /// One HedgedRequest, cancellable through `cancel(job)` and through task cancellation.
    private func run(_ r: MTRequest, policy: HedgePolicy, deadlineMs: Int, kind: HedgeRun.Kind,
                     speak: SpeakCloudContext?) async throws -> HedgedRequest.Outcome {
        try Task.checkCancellation()
        if cancelledJobs.contains(r.job) { throw CancellationError() }
        let dir: CloudHealth.Direction = r.session.isSpeak ? .speak : .listen
        let soft = r.session.isSpeak ? profile.speak.mt.contextTokensSoft : profile.listen.finalMT.contextTokensSoft
        let hard = r.session.isSpeak ? profile.speak.mt.contextTokensHard : profile.listen.finalMT.contextTokensHard
        let tier = fastModeOn ? Self.fastTier : profile.cloud.serviceTier
        let body: Data
        do {
            body = try builder.body(for: r, glossary: glossaries[r.session] ?? [],
                                    options: .init(model: config.model, effort: config.effort,
                                                   reasoningBudget: config.effort == "none" ? 0 : config.reasoningBudget,
                                                   contextTokensSoft: soft, contextTokensHard: hard, serviceTier: tier))
        } catch {
            health.releaseProbes(dir)
            throw MTError.cloudUnavailable("body")
        }
        let hedged = HedgedRequest(client: client, policy: policy, afterNewlineGraceMs: profile.speak.mt.afterNewlineGraceMs,
                                   sink: Self.eventSink(log))
        let paused = health.hedgingPaused(now: nowMs())
        let effort = config.effort
        let startApple: @Sendable () -> Void = speak?.onStartApple ?? { @Sendable in }
        let appleLate = speak?.appleLate ?? false
        let task = Task<HedgedRequest.Outcome, Never> {
            await hedged.run(body: body, sentEffort: effort, sentTier: tier, kind: kind, deadlineMs: deadlineMs,
                             hedgingPaused: paused, appleLate: appleLate, onStartApple: startApple)
        }
        inFlight[r.job] = task
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inFlight[r.job] = nil
        logRequest(r, tier: tier, deadlineMs: deadlineMs, outcome: outcome)

        if outcome.cancelledByCaller || Task.isCancelled || cancelledJobs.contains(r.job) {
            health.releaseProbes(dir)
            log?.event("mt.cancelled", ["job": .int(Int(r.job))])
            throw CancellationError()
        }
        if fastModeRefused(tier: tier, outcome: outcome) {
            health.releaseProbes(dir)
            var refused = outcome
            // Don't name the key or quota for a tier refusal. A 403 that really is the key
            // pauses on the next standard-tier sentence.
            refused.decision.pauseReason = nil
            return refused
        }
        for line in health.record(dir, decision: outcome.decision, hedgePauseS: outcome.hedgePauseS, now: nowMs()) {
            log?.event("cloud.breaker", ["state": .tag(line)])
        }
        // Connection health (§6.4): a hedge that wins while the loser never got headers, or a
        // LISTEN request whose headers come late, rebuilds that connection.
        let d = outcome.decision.outcome
        if d.fired, d.winner != .apple {
            let loser: Leg = d.winner == .A ? .B : .A
            apply(resets.recordHedgeWin(winner: d.winner == .A ? .A : .B, loserHadHeaders: outcome.legs[loser]?.headersMs != nil))
        }
        if !r.session.isSpeak, let a = outcome.legs[.A], a.sentMs != nil {
            apply(resets.recordListenRequest(headersAfterMs: a.headersMs.flatMap { h in a.sentMs.map { h - $0 } }))
        }
        if let kw = keepWarm {
            for leg in Leg.allCases where outcome.legs[leg]?.sentMs != nil { await kw.noteActivity(leg, reused: nil) }
        }
        return outcome
    }

    /// If this account or model cannot use Fast mode, that costs one sentence, not the meeting:
    /// the rest of the meeting uses the standard tier and the refusal never reaches the breaker
    /// or the sticky pause.
    private func fastModeRefused(tier: String, outcome: HedgedRequest.Outcome) -> Bool {
        guard tier == Self.fastTier else { return false }
        let status = outcome.legs.values.compactMap { $0.headers?.status }.first { (400..<500).contains($0) && $0 != 429 && $0 != 401 }
        let badEcho = outcome.legs.values.contains { $0.validation?.rejectReason?.hasPrefix("serviceTier:") == true }
        guard status != nil || badEcho else { return false }
        if fastModeOn {
            fastModeOn = false
            log?.event("mt.fast_off", ["status": .int(status ?? 0), "bad_echo": .bool(badEcho)])
        }
        return true
    }

    /// One numeric line per leg sent. It runs before the cancellation exit in `run`: a request
    /// abandoned at the deadline is the one whose timing matters most.
    private func logRequest(_ r: MTRequest, tier: String, deadlineMs: Int, outcome: HedgedRequest.Outcome) {
        guard let log else { return }
        let decided = outcome.decision.outcome
        for leg in Leg.allCases {
            guard let report = outcome.legs[leg], report.sentMs != nil else { continue }
            let echo = report.echo ?? report.createdEcho
            var fields: [String: EventLog.Value] = [
                "job": .int(Int(r.job)), "session": .tag(r.session.rawValue), "leg": .tag(leg.rawValue), "tier": .tag(tier),
                "deadline_ms": .int(deadlineMs), "elapsed_ms": .int(decided.ms),
                "won": .bool(decided.winner.rawValue == leg.rawValue), "cancelled": .bool(report.cancelled),
            ]
            let numbers = [("sent_ms", report.sentMs), ("headers_ms", report.headersMs), ("first_delta_ms", report.firstDeltaMs),
                           ("end_ms", report.endMs), ("status", report.headers?.status), ("processing_ms", report.headers?.processingMs),
                           ("input_tokens", echo?.inputTokens), ("output_tokens", echo?.outputTokens), ("cached_tokens", echo?.cachedTokens)]
            for case let (name, value?) in numbers { fields[name] = .int(value) }
            if let id = report.clientRequestID { fields["req"] = .tag(id) }
            if let echoed = echo?.serviceTier { fields["tier_echo"] = .tag(echoed) }
            log.event("mt.request", fields)
        }
    }
}
