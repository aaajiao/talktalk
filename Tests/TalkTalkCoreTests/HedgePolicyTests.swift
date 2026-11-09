import Testing
@testable import TalkTalkCore

/// HedgePolicy on a virtual clock (ms since A was sent). §13's list, plus breaker accounting.
@Suite struct HedgePolicyTests {
    let policy: HedgePolicy
    let profile: PolicyProfile

    init() throws {
        profile = try TestResources.profile()
        policy = profile.speakHedgePolicy
    }

    /// Runs a scripted event list; ticks every 10 ms in between so time-based rules fire.
    func run(_ events: [HedgeEvent], deadline: Int = 2500, kind: HedgeRun.Kind = .normal, until end: Int = 6000,
             policy p: HedgePolicy? = nil, paused: Bool = false, appleLate: Bool = false,
             replyBy: Int? = nil) -> (HedgeRun, [(Int, HedgeAction)]) {
        let p = p ?? policy
        let (start, first) = p.begin(kind: kind, deadlineMs: deadline, replyByMs: replyBy, hedgingPaused: paused, appleLate: appleLate)
        var r = start
        var log: [(Int, HedgeAction)] = first.map { (0, $0) }
        var queue = events.sorted { $0.now < $1.now }
        var t = 0
        while t <= end, !r.isDone {
            while let e = queue.first, e.now <= t {
                queue.removeFirst()
                log += p.step(&r, e).map { (e.now, $0) }
            }
            if r.isDone { break }
            log += p.step(&r, .tick(t)).map { (t, $0) }
            t += 10
        }
        return (r, log)
    }

    func sends(_ log: [(Int, HedgeAction)], _ leg: Leg) -> [(Int, HedgeReason?)] {
        log.compactMap { if case .send(let l, let why) = $0.1, l == leg { ($0.0, why) } else { nil } }
    }
    func decision(_ r: HedgeRun) -> HedgeDecision { r.decision! }

    @Test func firstDeltaBeforeOneSecondMeansNoHedge() {
        let (r, log) = run([.headers(.A, 300), .delta(.A, 700), .event(.A, 800), .finished(.A, 900, .valid)])
        #expect(sends(log, .B).isEmpty)
        #expect(decision(r).outcome == HedgeOutcome(fired: false, winner: .A, reason: nil, ms: 900))
        #expect(!log.contains { $0.1 == .startApple })
    }

    @Test func noDeltaByOneSecondSendsExactlyOneHedgeAndStartsApple() {
        let (r, log) = run([.headers(.A, 400), .delta(.A, 1800), .finished(.A, 1900, .valid)])
        let b = sends(log, .B)
        #expect(b.count == 1)
        #expect(b.first?.0 == 1000)
        #expect(b.first?.1 == .noDelta)
        #expect(log.contains { $0 == (1000, .startApple) })
        #expect(decision(r).outcome.fired)
        #expect(decision(r).outcome.winner == .A)
        #expect(log.contains { $0.1 == .cancel(.B) })     // the loser is cancelled at once
    }

    @Test func hedgeWinsAndPrimaryIsCancelled() {
        let (r, log) = run([.headers(.B, 1300), .delta(.B, 1600), .finished(.B, 1700, .valid)])
        #expect(decision(r).outcome == HedgeOutcome(fired: true, winner: .B, reason: .noDelta, ms: 1700))
        #expect(log.contains { $0 == (1700, .cancel(.A)) })
    }

    @Test func primaryFailingFastSendsBImmediately() {
        let (r, log) = run([.finished(.A, 300, .failed(.http5xx(503))), .delta(.B, 900), .finished(.B, 1000, .valid)])
        #expect(sends(log, .B).map(\.0) == [300])
        #expect(sends(log, .B).first?.1 == .fastFail)
        #expect(decision(r).outcome.winner == .B)
        #expect(decision(r).outcome.reason == .fastFail)
        #expect(!decision(r).breakerFailure)
    }

    @Test func rateLimitAuthAndQuotaNeverTriggerB() {
        for f in [LegFailure.rateLimited(retryAfterS: 7), .pause("http401"), .pause("insufficient_quota")] {
            let (r, log) = run([.finished(.A, 200, .failed(f))])
            #expect(sends(log, .B).isEmpty, "\(f)")
            #expect(decision(r).outcome.winner == .apple)
            #expect(decision(r).fallback == .allFailed)
            #expect(!decision(r).breakerFailure, "\(f)")
            #expect(log.contains { $0.1 == .startApple })
        }
        let (r429, _) = run([.finished(.A, 200, .failed(.rateLimited(retryAfterS: 7)))])
        #expect(decision(r429).primaryRateLimited)
        #expect(decision(r429).retryAfterS == 7)
        let (r401, _) = run([.finished(.A, 200, .failed(.pause("http401")))])
        #expect(decision(r401).pauseReason == "http401")
    }

    @Test func failureAfterFirstDeltaSendsBOnlyWithEnoughTimeLeft() {
        // delta at 400, failure at 1500: 1000 ms left ≥ 800 → B + Apple.
        let (r1, log1) = run([.delta(.A, 400), .event(.A, 450), .event(.A, 900), .event(.A, 1350),
                              .finished(.A, 1500, .failed(.connectionError))])
        #expect(sends(log1, .B).first?.1 == .failAfterDelta)
        #expect(log1.contains { $0 == (1500, .startApple) })
        #expect(r1.hedgeFired)
        // failure at 1800: 700 ms left < 800 → Apple, no B.
        let (r2, log2) = run([.delta(.A, 400), .event(.A, 800), .event(.A, 1200), .event(.A, 1600),
                              .finished(.A, 1800, .failed(.responseFailed))])
        #expect(sends(log2, .B).isEmpty)
        #expect(decision(r2).fallback == .failAfterDeltaNoTime)
        #expect(decision(r2).breakerFailure)           // the only leg hard-failed
    }

    @Test func stallAfterDeltaSendsBEvenBeforeOneSecond() {
        let (_, log) = run([.headers(.A, 100), .delta(.A, 200), .finished(.A, 2000, .valid)])
        #expect(sends(log, .B).map(\.0) == [700])
        #expect(sends(log, .B).first?.1 == .stall)
    }

    @Test func atMostTwoRequestsPerSentence() {
        let (_, log) = run([.delta(.A, 200), .finished(.B, 900, .failed(.http5xx(500)))])
        #expect(sends(log, .B).count == 1)
        #expect(sends(log, .A).count == 1)
    }

    @Test func invalidFirstFinisherWaitsForTheOther() {
        let (r, log) = run([.finished(.A, 1200, .failed(.validationReject("effort:low"))), .delta(.B, 1500),
                            .finished(.B, 1600, .valid)])
        #expect(decision(r).outcome.winner == .B)
        #expect(!log.contains { if case .finish = $0.1 { $0.0 < 1600 } else { false } })
    }

    @Test func deadlineFallsBackToApple() {
        let (r, log) = run([])
        #expect(decision(r).outcome == HedgeOutcome(fired: true, winner: .apple, reason: .noDelta, ms: 2500))
        #expect(decision(r).fallback == .deadline)
        #expect(decision(r).timedOut)
        #expect(!decision(r).breakerFailure)              // timeouts never feed the shared breaker
        #expect(log.contains { $0 == (2500, .cancel(.A)) })
        #expect(log.contains { $0 == (2500, .cancel(.B)) })
    }

    @Test func bothHardFailuresCountOnceForTheBreaker() {
        let (r, _) = run([.finished(.A, 1100, .failed(.http5xx(502))), .finished(.B, 1300, .failed(.connectionError))])
        #expect(decision(r).breakerFailure)
        #expect(decision(r).outcome.winner == .apple)
        #expect(decision(r).fallback == .allFailed)
        // One hard failure and one 429: not a breaker failure (429 is not hard).
        let (r2, log2) = run([.finished(.B, 1100, .failed(.rateLimited(retryAfterS: nil))), .finished(.A, 1300, .failed(.http5xx(500)))])
        #expect(!decision(r2).breakerFailure)
        #expect(log2.contains { $0.1 == .pauseHedging(seconds: 30) })
        #expect(!decision(r2).primaryRateLimited)
    }

    @Test func rateLimitOnHedgePausesHedgingWithRetryAfter() {
        let (r, log) = run([.finished(.B, 1100, .failed(.rateLimited(retryAfterS: 45))), .delta(.A, 1400), .finished(.A, 1500, .valid)])
        #expect(log.contains { $0 == (1100, .pauseHedging(seconds: 45)) })
        #expect(decision(r).outcome.winner == .A)
    }

    private var doubleSend: HedgePolicy {
        var p = profile.listenHedgePolicy
        p.hedge.enabled = true
        return p
    }

    @Test func aRateLimitOnTheFirstLegOfADoubleSendPausesIt() {
        let (r, log) = run([.finished(.A, 100, .failed(.rateLimited(retryAfterS: 20))), .delta(.B, 300), .finished(.B, 400, .valid)],
                           policy: doubleSend)
        #expect(log.contains { $0 == (100, .pauseHedging(seconds: max(doubleSend.hedge.pauseAfter429S, 20))) })
        #expect(decision(r).outcome.winner == .B)
    }

    @Test func aRateLimitOnALateFirstLegLeavesSpeakHedgingOn() {
        let (r, log) = run([.finished(.A, 1100, .failed(.rateLimited(retryAfterS: 20))), .delta(.B, 1300), .finished(.B, 1400, .valid)])
        #expect(!log.contains { if case .pauseHedging = $0.1 { true } else { false } })
        #expect(decision(r).outcome.winner == .B)
    }

    @Test func aRequestNothingHasAnsweredStopsAtTheReplyTimeAndIsNotATimeout() {
        let listen = profile.listenHedgePolicy
        let (begun, _) = listen.begin(deadlineMs: 3000, replyByMs: 2000)
        #expect(listen.nextWakeup(begun) == 2000)
        let (r, log) = run([], deadline: 3000, policy: listen, replyBy: 2000)
        #expect(decision(r).fallback == .noReply && decision(r).outcome.ms == 2000)
        #expect(!decision(r).timedOut && !decision(r).breakerFailure)
        #expect(log.contains { $0.1 == .cancel(.A) })
    }

    @Test func aRequestThatHasStartedToAnswerGetsTheFullDeadline() {
        let listen = profile.listenHedgePolicy
        let (won, _) = run([.headers(.A, 900), .delta(.A, 2400), .finished(.A, 2600, .valid)], deadline: 3000, policy: listen, replyBy: 2000)
        #expect(decision(won).outcome == HedgeOutcome(fired: false, winner: .A, reason: nil, ms: 2600))
        let (late, _) = run([.headers(.A, 900)], deadline: 3000, policy: listen, replyBy: 2000)
        #expect(decision(late).fallback == .deadline && decision(late).outcome.ms == 3000 && decision(late).timedOut)
    }

    @Test func onlyALegStillRunningCountsAsAnswering() {
        let (r, _) = run([.headers(.A, 900), .finished(.A, 2200, .failed(.http5xx(500)))], deadline: 3000, policy: doubleSend, replyBy: 2000)
        #expect(decision(r).fallback == .noReply && decision(r).outcome.ms == 2200)
    }

    @Test func lateResultAfterCancelIsIgnored() {
        var r = policy.begin(deadlineMs: 2500).0
        _ = policy.step(&r, .finished(.A, 900, .valid))
        #expect(r.decision?.outcome.winner == .A)
        let late = policy.step(&r, .finished(.B, 950, .valid))
        #expect(late.isEmpty)
        #expect(r.decision?.outcome.winner == .A)
    }

    @Test func pausedHedgingAndDisabledHedgingNeverSendB() {
        let (_, log) = run([.finished(.A, 2000, .valid)], paused: true)
        #expect(sends(log, .B).isEmpty)
        let listen = profile.listenHedgePolicy
        let (r2, log2) = run([.finished(.A, 1400, .valid)], deadline: listen.totalDeadlineMs, policy: listen)
        #expect(sends(log2, .B).isEmpty)
        #expect(decision(r2).outcome.winner == .A)
    }

    @Test func listenDoubleSendWhenEnabled() {
        var listen = profile.listenHedgePolicy
        listen.hedge.enabled = true
        let (r, log) = run([.finished(.B, 900, .valid)], deadline: 1500, policy: listen)
        #expect(sends(log, .B).map(\.0) == [0])
        #expect(decision(r).outcome.winner == .B)
    }

    @Test func guardRetryDoubleSendsFromTheStart() {
        let d = policy.guardRetryDeadlineMs(precedingAudioMs: nil, ttsFirstChunkP95Ms: 300)
        #expect(d == 1200)
        let (r, log) = run([.finished(.A, 1000, .valid)], deadline: d, kind: .guardRetry)
        #expect(sends(log, .A).map(\.0) == [0])
        #expect(sends(log, .B).map(\.0) == [0])
        #expect(sends(log, .B).first?.1 == .guardRetry)
        #expect(log.filter { $0.1 == .startApple }.map(\.0) == [0])
        #expect(decision(r).outcome.reason == .guardRetry)
        // Masked by preceding audio: extended, at most maxMs.
        #expect(policy.guardRetryDeadlineMs(precedingAudioMs: 2200, ttsFirstChunkP95Ms: 300) == 1800)
        #expect(policy.guardRetryDeadlineMs(precedingAudioMs: 9000, ttsFirstChunkP95Ms: 300) == 2500)
        let (r2, _) = run([], deadline: 1200, kind: .guardRetry)
        #expect(decision(r2).outcome.ms == 1200)
        #expect(decision(r2).fallback == .deadline)
    }

    @Test func guardRetryApplePreparationRespectsLateAndDisabledPolicies() {
        let (_, late) = run([], deadline: 1200, kind: .guardRetry, appleLate: true)
        #expect(!late.contains { $0.1 == .startApple })
        var p = policy
        p.hedge.startAppleAtHedge = false
        let (_, disabled) = run([], deadline: 1200, kind: .guardRetry, policy: p)
        #expect(!disabled.contains { $0.1 == .startApple })
        p.hedge.startAppleAtHedge = true
        p.hedge.maxInFlight = 1
        let (_, single) = run([], deadline: 1200, kind: .guardRetry, policy: p)
        #expect(sends(single, .B).isEmpty)
        #expect(single.filter { $0.1 == .startApple }.map(\.0) == [0])
    }

    @Test func deadlineExtendsToTheDrainCappedAtFiveSeconds() {
        #expect(policy.deadlineMs(precedingAudioMs: nil, ttsFirstChunkP95Ms: 300) == 2500)
        #expect(policy.deadlineMs(precedingAudioMs: 2000, ttsFirstChunkP95Ms: 300) == 2500)
        #expect(policy.deadlineMs(precedingAudioMs: 4000, ttsFirstChunkP95Ms: 300) == 3600)
        #expect(policy.deadlineMs(precedingAudioMs: 9000, ttsFirstChunkP95Ms: 300) == 5000)
        // GPU step 3: Apple starts at the deadline, so the extension loses Apple's p95; never below 2.5 s.
        #expect(policy.deadlineMs(precedingAudioMs: 4000, ttsFirstChunkP95Ms: 300, appleP95Ms: 600, appleLate: true) == 3000)
        #expect(policy.deadlineMs(precedingAudioMs: 3000, ttsFirstChunkP95Ms: 300, appleP95Ms: 600, appleLate: true) == 2500)
        // Drain estimate: rendered fully, unrendered at 0.7, in-flight at 0.
        #expect(policy.precedingAudioMs(renderedMs: 1000, unrenderedExpectedMs: 2000, inFlightSourceMs: 3000) == 2400)
    }

    @Test func appleLateDoesNotStartAppleAtHedgeTime() {
        let (_, log) = run([.finished(.A, 1900, .valid)], appleLate: true)
        #expect(sends(log, .B).count == 1)
        #expect(!log.contains { $0.1 == .startApple })
        let (_, log2) = run([], appleLate: true)
        #expect(log2.contains { $0 == (2500, .startApple) })    // only at the deadline
    }

    @Test func numberGuardRetryRule() {
        #expect(policy.shouldRetryNumberGuard(maskedMs: 1500, hardMismatch: false))
        #expect(!policy.shouldRetryNumberGuard(maskedMs: 1499, hardMismatch: false))
        #expect(policy.shouldRetryNumberGuard(maskedMs: 0, hardMismatch: true))
    }

    @Test func nextWakeupFollowsTheRules() {
        var r = policy.begin(deadlineMs: 2500).0
        #expect(policy.nextWakeup(r) == 1000)
        _ = policy.step(&r, .delta(.A, 300))
        #expect(policy.nextWakeup(r) == 800)
        _ = policy.step(&r, .tick(800))
        #expect(r.hedgeFired)
        #expect(policy.nextWakeup(r) == 2500)
    }
}

@Suite struct SessionResetPolicyTests {
    let config: PolicyProfile.Cloud.SessionReset
    init() throws { config = try TestResources.profile().cloud.sessionReset }

    @Test func twoHedgeWinsAgainstAHeaderlessPrimaryRebuildA() {
        var p = SessionResetPolicy(config: config)
        do { let r = p.recordHedgeWin(winner: .B, loserHadHeaders: false); #expect(r.isEmpty) }
        do { let r = p.recordHedgeWin(winner: .B, loserHadHeaders: false); #expect(r == [.init(leg: .A, reason: "hedgeWinsWithoutHeaders")]) }
        // Interrupted streak does not count.
        do { let r = p.recordHedgeWin(winner: .B, loserHadHeaders: false); #expect(r.isEmpty) }
        do { let r = p.recordHedgeWin(winner: .B, loserHadHeaders: true); #expect(r.isEmpty) }
        do { let r = p.recordHedgeWin(winner: .B, loserHadHeaders: false); #expect(r.isEmpty) }
        // And the other way round.
        var q = SessionResetPolicy(config: config)
        _ = q.recordHedgeWin(winner: .A, loserHadHeaders: false)
        do { let r = q.recordHedgeWin(winner: .A, loserHadHeaders: false); #expect(r == [.init(leg: .B, reason: "hedgeWinsWithoutHeaders")]) }
    }

    @Test func listenOnlyRulesRebuildA() {
        var p = SessionResetPolicy(config: config)
        do { let r = p.recordKeepWarm(.A, ok: false); #expect(r.isEmpty) }
        do { let r = p.recordKeepWarm(.A, ok: false); #expect(r == [.init(leg: .A, reason: "keepWarmFailures")]) }
        do { let r = p.recordKeepWarm(.B, ok: false); #expect(r.isEmpty) }
        do { let r = p.recordKeepWarm(.B, ok: true); #expect(r.isEmpty) }
        do { let r = p.recordKeepWarm(.B, ok: false); #expect(r.isEmpty) }

        do { let r = p.recordListenRequest(headersAfterMs: 1200); #expect(r.isEmpty) }
        do { let r = p.recordListenRequest(headersAfterMs: nil); #expect(r == [.init(leg: .A, reason: "listenNoHeaders")]) }
        do { let r = p.recordListenRequest(headersAfterMs: 1500); #expect(r.isEmpty) }
        do { let r = p.recordListenRequest(headersAfterMs: 300); #expect(r.isEmpty) }
        do { let r = p.recordListenRequest(headersAfterMs: 1500); #expect(r.isEmpty) }
    }

    @Test func wakeAndPathChangeRebuildBoth() {
        var p = SessionResetPolicy(config: config)
        do { let r = p.onWake(); #expect(r.map(\.leg) == [.A, .B]) }
        do { let r = p.onPathChange(); #expect(r.map(\.reason) == ["pathChange", "pathChange"]) }
    }
}
