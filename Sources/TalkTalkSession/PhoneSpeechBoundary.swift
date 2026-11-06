/// Tracks definite Phone microphone-reader changes without treating silence or an unknown
/// observation as a call boundary. Local speech can run before the first Phone reader appears;
/// only cancellation of work from an observed reader transition creates a temporary barrier.
public struct PhoneSpeechBoundary: Sendable, Equatable {
    public private(set) var resetPending = false
    private var lastReader: Bool?
    private var token: UInt64 = 0

    public init() {}

    /// The first known reader state establishes a baseline. Each subsequent definite change
    /// returns a new cancellation token, superseding any reset that is still in flight.
    /// Pass nil when the audio process/device observation is unavailable, never for silence.
    public mutating func observe(reader: Bool?) -> UInt64? {
        guard let reader else { return nil }
        guard let previous = lastReader else {
            lastReader = reader
            return nil
        }
        guard previous != reader else { return nil }
        lastReader = reader
        token += 1
        resetPending = true
        return token
    }

    /// Check before starting destructive cancellation: a queued reset from an earlier
    /// lifecycle must not suspend a newly prepared pipeline, even if its session is the same.
    public func isPendingReset(token requested: UInt64) -> Bool {
        resetPending && requested == token
    }

    /// Only completion of the latest pending reset permits local speech to resume. A late or
    /// repeated completion cannot release a newer barrier, including after invalidation.
    @discardableResult
    public mutating func completeReset(token completed: UInt64) -> Bool {
        guard isPendingReset(token: completed) else { return false }
        resetPending = false
        return true
    }

    /// Begin/end/suspend discard the observed baseline and revoke pending completions. Keep
    /// advancing the token so a completion from an earlier lifecycle can never match a new one.
    public mutating func invalidate() {
        token += 1
        resetPending = false
        lastReader = nil
    }
}
