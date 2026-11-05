import CAudioCore

/// The real-time IOProcs' host-time event ring (tt_event_ring.h, ARCHITECTURE.md §12.2): feedIOProc
/// and monitorIOProc push (several producers are allowed), the audio worker alone drains. One ring
/// for both IOProcs, so the worker drains in one place and hands out.* events to
/// `ClauseQueue.pump` (`PlayoutRingEvent(_:)`) and the rest to the EventLog. Events carry
/// numbers only, never audio or text.
public final class EventRing: @unchecked Sendable {
    /// For the IOProc contexts (tt_feed_ctx, tt_monitor_ctx) in this module.
    let raw: OpaquePointer

    /// `minCapacity` is rounded up to a power of two. A push into a full ring is dropped and
    /// counted (`dropped`); the worker drains every 10 ms, and a busy second has a few dozen events.
    public init?(minCapacity: Int = 1024) {
        guard minCapacity > 0, minCapacity <= Int(UInt32.max), let r = tt_event_ring_create(UInt32(minCapacity)) else {
            return nil
        }
        raw = r
    }

    deinit { tt_event_ring_destroy(raw) }

    public var capacity: Int { Int(tt_event_ring_capacity(raw)) }
    public var pushed: UInt64 { tt_event_pushed(raw) }
    public var dropped: UInt64 { tt_event_dropped(raw) }

    /// Consumer side, the audio worker only (single consumer): up to `max` events, oldest first.
    /// Host ticks are converted by the receiver (`PlayoutRingEvent(_:)`, HostClock).
    public func drain(max: Int = 256) -> [tt_event] {
        guard max > 0 else { return [] }
        return [tt_event](unsafeUninitializedCapacity: max) { buf, count in
            count = Int(tt_event_drain(raw, buf.baseAddress!, UInt32(clamping: max)))
        }
    }
}
