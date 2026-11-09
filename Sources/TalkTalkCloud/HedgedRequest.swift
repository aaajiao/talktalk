import Foundation
import TalkTalkCore

/// One sentence's cloud MT request with hedging (§4.1, §16 decision 13). It only sends, reads
/// and cancels; every decision (when B goes out, the deadline, who wins, breaker accounting) is
/// HedgePolicy's. The two legs use OpenAIClient's sessions A and B with the same body bytes
/// (each attempt gets its own X-Client-Request-Id). Also handles §5.4's newline rule: text after
/// the first newline is dropped, the stream is read on for at most `afterNewlineGraceMs`, then
/// cancelled and only the response.created echo is validated (mt.validate_partial).
public struct HedgedRequest: Sendable {
    public let client: OpenAIClient
    public let policy: HedgePolicy
    public let afterNewlineGraceMs: Int
    public let sink: CloudEventSink

    public init(client: OpenAIClient, policy: HedgePolicy, afterNewlineGraceMs: Int, sink: @escaping CloudEventSink = { _ in }) {
        self.client = client; self.policy = policy; self.afterNewlineGraceMs = afterNewlineGraceMs; self.sink = sink
    }

    public struct LegReport: Sendable, Equatable {
        public var clientRequestID: String?
        public var sentMs: Int?
        public var headersMs: Int?
        public var firstDeltaMs: Int?
        public var endMs: Int?
        public var result: LegResult?
        public var validation: ResponseValidation?
        public var partialValidation = false
        public var cancelled = false
        public var echo: ResponseEcho?
        /// The response.created echo (T4 ①: is effort/tier/store already there?).
        public var createdEcho: ResponseEcho?
        public var headers: OpenAIResponseHeaders?
        public var error: OpenAIErrorInfo?
        /// Time from the first newline to the end of the stream (T4 ②).
        public var newlineToEndMs: Int?
        public var maxGapAfterDeltaMs: Int?
    }

    public struct Outcome: Sendable {
        public var decision: HedgeDecision
        /// The winner's first line; nil when no cloud leg won.
        public var text: String?
        public var legs: [Leg: LegReport]
        /// B got a 429: no hedging for this many seconds.
        public var hedgePauseS: Int?
        public var cancelledByCaller: Bool
        public var winnerEcho: ResponseEcho? {
            switch decision.outcome.winner { case .A: legs[.A]?.echo; case .B: legs[.B]?.echo; case .apple: nil }
        }
    }

    enum Input: Sendable {
        case item(Leg, OpenAIClient.StreamItem)
        case ended(Leg, (any Error)?)
        case tick
        case callerCancelled
    }

    /// Runs one sentence. `sentEffort` must be the effort in `body`. `onStartApple` is called
    /// at most once, when the policy wants the Apple fallback started (hedge time or the end).
    /// `sentTier` must be the service tier in `body` when it is not the profile's.
    public func run(body: Data, sentEffort: String, sentTier: String? = nil, kind: HedgeRun.Kind = .normal, deadlineMs: Int,
                    hedgingPaused: Bool = false, appleLate: Bool = false,
                    onStartApple: @escaping @Sendable () -> Void = {}) async -> Outcome {
        let (inputs, cont) = AsyncStream<Input>.makeStream()
        let t0 = ContinuousClock.now
        func now() -> Int { Int((ContinuousClock.now - t0) / .milliseconds(1)) }

        var pumps: [Leg: Task<Void, Never>] = [:]
        var acc: [Leg: ResponseAccumulator] = [.A: .init(), .B: .init()]
        var reports: [Leg: LegReport] = [.A: .init(), .B: .init()]
        var grace: [Leg: Int] = [:]
        var lastDelta: [Leg: Int] = [:]
        var timer: Task<Void, Never>?
        var hedgePause: Int?
        var decision: HedgeDecision?
        var cancelledByCaller = false

        let client = self.client
        func send(_ leg: Leg) {
            reports[leg]!.sentMs = now()
            pumps[leg] = Task {
                do {
                    for try await item in client.stream(leg: leg, body: body) { cont.yield(.item(leg, item)) }
                    cont.yield(.ended(leg, nil))
                } catch {
                    cont.yield(.ended(leg, error))
                }
            }
        }
        func cancel(_ leg: Leg) {
            reports[leg]!.cancelled = reports[leg]!.result == nil
            reports[leg]!.createdEcho = acc[leg]!.created   // finishLeg never runs for this leg
            pumps[leg]?.cancel()
        }

        var (state, actions) = policy.begin(kind: kind, deadlineMs: deadlineMs, hedgingPaused: hedgingPaused, appleLate: appleLate)

        func perform(_ list: [HedgeAction]) {
            for a in list {
                switch a {
                case .send(let leg, _): send(leg)
                case .startApple: onStartApple()
                case .cancel(let leg): cancel(leg)
                case .pauseHedging(let s): hedgePause = s
                case .finish(let d): decision = d
                }
            }
        }
        func finishLeg(_ leg: Leg, _ result: LegResult, validation: ResponseValidation?, partial: Bool) {
            guard reports[leg]!.result == nil, !reports[leg]!.cancelled else { return }
            let t = now()
            reports[leg]!.result = result
            reports[leg]!.endMs = t
            reports[leg]!.validation = validation
            reports[leg]!.partialValidation = partial
            reports[leg]!.echo = partial ? acc[leg]!.created : acc[leg]!.final
            reports[leg]!.createdEcho = acc[leg]!.created
            if let g = grace[leg] { reports[leg]!.newlineToEndMs = t - (g - afterNewlineGraceMs) }
            grace[leg] = nil
            if let v = validation {
                sink(.validation(leg: leg, reject: v.rejectReason, storeEchoMissing: v.storeEchoMissing, partial: partial))
            }
            pumps[leg]?.cancel()
            perform(policy.step(&state, .finished(leg, t, result)))
        }
        func reschedule() {
            timer?.cancel()
            guard decision == nil else { return }
            var w = policy.nextWakeup(state)
            for g in grace.values { w = min(w ?? g, g) }
            guard let at = w else { return }
            timer = Task {
                try? await Task.sleep(until: t0 + .milliseconds(max(at, 0)), clock: .continuous)
                if !Task.isCancelled { cont.yield(.tick) }
            }
        }

        perform(actions)
        actions = []
        reschedule()

        await withTaskCancellationHandler {
            for await input in inputs {
                let t = now()
                switch input {
                case .callerCancelled:
                    cancelledByCaller = true
                case .tick:
                    for (leg, g) in grace where g <= t {
                        let (r, v) = acc[leg]!.partialResult(sentEffort: sentEffort, cloud: client.cloud, sentTier: sentTier)
                        finishLeg(leg, r, validation: v, partial: true)
                    }
                    if decision == nil { perform(policy.step(&state, .tick(t))) }
                case .item(let leg, let item):
                    guard reports[leg]!.result == nil, !reports[leg]!.cancelled else { break }
                    switch item {
                    case .started(let id):
                        reports[leg]!.clientRequestID = id
                    case .headers(let h):
                        reports[leg]!.headersMs = t
                        reports[leg]!.headers = h
                        perform(policy.step(&state, .headers(leg, t)))
                    case .httpError(let h, let info):
                        reports[leg]!.headersMs = t
                        reports[leg]!.headers = h
                        reports[leg]!.error = info
                        let f = OpenAIErrorClassifier.classify(status: h.status, error: info, retryAfterS: h.retryAfterS, cloud: client.cloud)
                        finishLeg(leg, .failed(f), validation: nil, partial: false)
                    case .sse(let e):
                        for s in acc[leg]!.consume(e) {
                            switch s {
                            case .delta:
                                if reports[leg]!.firstDeltaMs == nil { reports[leg]!.firstDeltaMs = t }
                                if let last = lastDelta[leg] {
                                    reports[leg]!.maxGapAfterDeltaMs = max(reports[leg]!.maxGapAfterDeltaMs ?? 0, t - last)
                                }
                                lastDelta[leg] = t
                                if decision == nil { perform(policy.step(&state, .delta(leg, t))) }
                            case .progress:
                                if decision == nil { perform(policy.step(&state, .event(leg, t))) }
                            case .firstLineComplete:
                                grace[leg] = t + afterNewlineGraceMs
                            case .terminal:
                                reports[leg]!.error = acc[leg]!.error
                                let (r, v) = acc[leg]!.terminalResult(sentEffort: sentEffort, cloud: client.cloud, sentTier: sentTier)
                                finishLeg(leg, r, validation: v, partial: false)
                            }
                        }
                    }
                case .ended(let leg, let error):
                    guard reports[leg]!.result == nil, !reports[leg]!.cancelled else { break }
                    // Our own cancels are filtered above; a URLError.cancelled here comes from a
                    // session rebuild (§6.4 step 6) and counts as a connection error.
                    if error is CancellationError { break }
                    if grace[leg] != nil, error == nil {
                        let (r, v) = acc[leg]!.partialResult(sentEffort: sentEffort, cloud: client.cloud, sentTier: sentTier)
                        finishLeg(leg, r, validation: v, partial: true)
                    } else {
                        finishLeg(leg, .failed(.connectionError), validation: nil, partial: false)
                    }
                }
                if cancelledByCaller || decision != nil { break }
                reschedule()
            }
        } onCancel: {
            cont.yield(.callerCancelled)
        }

        // AsyncStream ends iteration as soon as the consuming task is cancelled, so the
        // .callerCancelled input may never be read.
        if Task.isCancelled { cancelledByCaller = true }
        timer?.cancel()
        for leg in Leg.allCases where reports[leg]!.result == nil && reports[leg]!.sentMs != nil { cancel(leg) }
        cont.finish()

        let final: HedgeDecision
        if let d = decision {
            final = d
        } else {
            final = HedgeDecision(outcome: HedgeOutcome(fired: reports[.B]!.sentMs != nil, winner: .apple, reason: nil, ms: now()),
                                  fallback: nil, breakerFailure: false, timedOut: false, primaryRateLimited: false,
                                  retryAfterS: nil, pauseReason: nil)
        }
        sink(.hedge(final.outcome))
        let text: String? = switch final.outcome.winner {
        case .A: acc[.A]!.firstLine.trimmed
        case .B: acc[.B]!.firstLine.trimmed
        case .apple: nil
        }
        return Outcome(decision: final, text: text, legs: reports, hedgePauseS: hedgePause, cancelledByCaller: cancelledByCaller)
    }
}
