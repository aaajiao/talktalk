import Foundation

/// §5.6's four independent checks. Missing echo/noise evidence never counts as confirmed
/// remote speech. Silence observations maintain a bounded median noise floor in dBFS.
public struct RemoteSpeechDetector: Sendable {
    public struct Observation: Sendable, Equatable {
        public var speaking: Bool
        public var silenceMs: Int
        public var noiseFloorDb: Double?
        public var newWords: Int
    }
    public let config: PolicyProfile.Speak.Floor
    private var quietLevels: [Double] = []
    private var speechSince: HostTime?
    private var silenceSince: HostTime?
    private var previousWords: Set<String> = []
    private var baselineWords: Set<String> = []
    public init(config: PolicyProfile.Speak.Floor) { self.config = config }

    public mutating func observe(vadSpeech: Bool, energyDb: Double, echoScore: Double?,
                                  volatileText: String, playingText: String, at now: HostTime) -> Observation {
        let words = Set(EchoFilter.tokens(volatileText))
        if vadSpeech {
            if speechSince == nil { speechSince = now; baselineWords = previousWords }
            silenceSince = nil
        } else {
            speechSince = nil
            if silenceSince == nil { silenceSince = now }
            if energyDb.isFinite {
                quietLevels.append(energyDb)
                if quietLevels.count > 100 { quietLevels.removeFirst() }
            }
        }
        previousWords = words
        let sorted = quietLevels.sorted()
        let floor = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        let novel = words.subtracting(baselineWords).subtracting(Set(EchoFilter.tokens(playingText))).count
        let durationOK = speechSince.map { HostClock.ms($0, to: now) >= config.ignoreMs } ?? false
        let energyOK = floor.map { energyDb.isFinite && energyDb - $0 >= config.energyAboveFloorDb } ?? false
        let echoOK = echoScore.map { $0.isFinite && $0 >= 0 && $0 < config.echoScoreMax } ?? false
        return Observation(speaking: vadSpeech && durationOK && energyOK && echoOK && novel >= config.minNonEchoWords,
                           silenceMs: silenceSince.map { max(0, HostClock.ms($0, to: now)) } ?? 0,
                           noiseFloorDb: floor, newWords: novel)
    }
}

/// Owns only the floor decision. The caller performs boundary pause/cut, updates the HUD,
/// and notifies the passthrough gate when .passthroughReady is emitted. Never clears a queue.
public struct FloorManager: Sendable {
    public enum Owner: Sendable { case remote, passthrough }
    public enum State: Sendable, Equatable {
        case playing
        case yielding(Owner, deadline: HostTime)
        case paused(since: HostTime)
        case awaitingPassthrough
        case passthrough
        case afterPassthrough(closedAt: HostTime)
    }
    public enum Action: Sendable, Equatable {
        case finishCurrent(until: HostTime)
        case pause
        case cutAndPause
        case passthroughReady
        case resume
        case offerClear
    }
    public let config: PolicyProfile.Speak.Floor
    public private(set) var state: State = .playing
    private var rearmAt: HostTime = 0
    private var offeredClear = false
    public init(config: PolicyProfile.Speak.Floor) { self.config = config }

    public mutating func observe(remoteSpeaking: Bool, remoteSilenceMs: Int,
                                  isPlaying: Bool, atBoundary: Bool, at now: HostTime) -> [Action] {
        switch state {
        case .playing:
            guard isPlaying, remoteSpeaking, now >= rearmAt else { return [] }
            return yield(to: .remote, atBoundary: atBoundary, at: now)
        case .yielding(let owner, let deadline):
            if owner == .remote, remoteSilenceMs >= config.resumeAfterRemoteSilenceMs { return resume(at: now) }
            guard atBoundary || now >= deadline else { return [] }
            return pause(for: owner, cut: !atBoundary, at: now)
        case .paused(let since):
            if remoteSilenceMs >= config.resumeAfterRemoteSilenceMs { return resume(at: now) }
            if !offeredClear, HostClock.ms(since, to: now) >= config.offerClearAfterS * 1000 {
                offeredClear = true; return [.offerClear]
            }
        case .afterPassthrough(let closed):
            if HostClock.ms(closed, to: now) >= config.resumeAfterRemoteSilenceMs,
               remoteSilenceMs >= config.resumeAfterRemoteSilenceMs { return resume(at: now) }
        case .awaitingPassthrough, .passthrough:
            break // detection continues, but cannot resume while the gate owns the floor
        }
        return []
    }

    public mutating func requestPassthrough(atBoundary: Bool, at now: HostTime) -> [Action] {
        switch state {
        case .passthrough, .awaitingPassthrough: return []
        case .paused, .afterPassthrough:
            state = .awaitingPassthrough; return [.passthroughReady]
        default: return yield(to: .passthrough, atBoundary: atBoundary, at: now)
        }
    }

    public mutating func passthroughOpened() { state = .passthrough }

    /// Also used when a prepared passthrough is cancelled before it opens.
    public mutating func passthroughClosed(at now: HostTime) {
        state = .afterPassthrough(closedAt: now); offeredClear = false
    }

    /// The key runtime guarantees this is a clean new PTT press after both keys were released.
    public mutating func newPress(at now: HostTime) -> [Action] {
        if case .afterPassthrough = state { return resume(at: now) }
        return []
    }

    private mutating func yield(to owner: Owner, atBoundary: Bool, at now: HostTime) -> [Action] {
        if atBoundary { return pause(for: owner, cut: false, at: now) }
        let deadline = now + UInt64(max(0, config.finishMaxS) * 1_000_000_000)
        state = .yielding(owner, deadline: deadline)
        return [.finishCurrent(until: deadline)]
    }

    private mutating func pause(for owner: Owner, cut: Bool, at now: HostTime) -> [Action] {
        offeredClear = false
        state = owner == .remote ? .paused(since: now) : .awaitingPassthrough
        return [cut ? .cutAndPause : .pause] + (owner == .passthrough ? [.passthroughReady] : [])
    }

    private mutating func resume(at now: HostTime) -> [Action] {
        state = .playing; offeredClear = false
        rearmAt = now + UInt64(max(0, config.rearmAfterResumeS) * 1_000_000_000)
        return [.resume]
    }
}
