import TalkTalkCore

/// App-lifetime audio owner; one ClauseQueue per meeting or onboarding SPEAK session (§3.3,
/// remaining-work decision G). Session depends only on this seam, Core and Apple.
public protocol SpeakPlayoutHost: AnyObject, Sendable {
    /// Throws if a session is already active. Runs on the owner's serial queue, never blocks
    /// the main actor/key thread in HAL. Config carries the meeting app's leadInMs. The owner
    /// immediately initializes the new queue's monitor flag from actual self-listen audibility.
    func beginSession(config: ClauseQueue.Config) async throws -> ClauseQueue
    /// Caller first cancels the pipeline. Completion is a barrier: stop pumping, clear the
    /// event sink, queue.teardown, clear wantFeed, detach Feed, reset ringO with both ends
    /// stopped, release the queue. Suspension does NOT call this: it keeps the session queue.
    func endSession() async
    /// Called synchronously on the audio worker; the sink only enqueues work, never waits or
    /// awaits an actor. No old-session events may be delivered after endSession completes.
    func setEventSink(_ sink: (@Sendable ([ClauseQueue.Event]) -> Void)?)
    var isFeedAttached: Bool { get }
    /// Maintains the ≤10 ms pump cadence during passthrough yielding.
    func setFastPump(_ enabled: Bool)
}
