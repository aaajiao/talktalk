import TalkTalkCore

/// Meeting-mode lifecycle, for several subscribers (system input switching, the SPEAK pipeline,
/// the diagnostics recorder, the menu / subtitle UI). One hub lives as long as the app; each
/// `MeetingSession` (one per meeting) is given it and emits into it, so a subscriber registers
/// once, not per meeting. Delivery is synchronous on the main actor, in subscription order.
///
/// Order within one meeting:
///   started → (suspended(reason) → resumed(afterSleep:) | ended)* … → ended(reason)
/// `suspended` comes once per running→suspended transition (the first reason: sleep / lock /
/// session); further reasons while already suspended raise no event. `resumed` comes when the
/// last reason clears and the meeting process still has audio; otherwise `ended(.afterSleep)`.
/// `afterSleep` is true when the Mac slept at any point of that suspension (lock first, then the
/// lid included): the cloud MT rebuilds its connections then (§6.4).
/// `audioServiceRestarted` comes after coreaudiod restarted and the tap was rebuilt. `state` and
/// `hint` repeat every MeetingSession state / hint change for UI subscribers.
public enum MeetingMode: String, Sendable, Equatable {
    case meeting
    case captions
}

public enum MeetingEvent: Sendable, Equatable {
    case started(appID: String, appName: String, lang: Lang, mode: MeetingMode = .meeting)
    case suspended(MeetingLifecycle.Reason)
    case resumed(afterSleep: Bool)
    case audioServiceRestarted(at: HostTime)
    case ended(MeetingSession.EndReason)
    case state(MeetingSession.State)
    case hint(MeetingSession.Hint?)
    /// Where the finals come from now (OpenAI, Apple fallback and why, Apple only); changes only.
    case translation(ListenTranslation)

    /// The lifecycle events only (start, end, sleep / lock / switch, wake, coreaudiod restart).
    public var isLifecycle: Bool {
        switch self {
        case .state, .hint, .translation: false
        default: true
        }
    }
}

@MainActor
public final class MeetingEvents {
    public typealias Handler = @MainActor (MeetingEvent) -> Void

    private var handlers: [(id: Int, f: Handler)] = []
    private var nextID = 0

    public init() {}

    /// Keep the returned subscription; it unsubscribes on `cancel()` or when released.
    public func subscribe(_ f: @escaping Handler) -> MeetingSubscription {
        nextID += 1
        let id = nextID
        handlers.append((id, f))
        return MeetingSubscription(hub: self, id: id)
    }

    public var subscriberCount: Int { handlers.count }

    func remove(_ id: Int) { handlers.removeAll { $0.id == id } }

    public func emit(_ e: MeetingEvent) {
        // A snapshot: a handler may subscribe or cancel while being called.
        for h in handlers { h.f(e) }
    }
}

@MainActor
public final class MeetingSubscription {
    private weak var hub: MeetingEvents?
    private let id: Int

    init(hub: MeetingEvents, id: Int) {
        self.hub = hub
        self.id = id
    }

    public func cancel() { hub?.remove(id) }

    isolated deinit { hub?.remove(id) }
}
