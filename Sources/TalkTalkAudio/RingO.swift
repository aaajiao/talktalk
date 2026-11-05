import CAudioCore
import TalkTalkCore

/// ringO / ringO2 as a `PlayoutRing`: the producer half of CAudioCore's tt_ring Playout section,
/// one member per C call (tt_ring.h). The consumer half is feedIOProc (ringO) or monitorIOProc
/// (ringO2), which read `raw` with tt_ring_playout_read on their IO threads.
///
/// Producer calls come from the audio worker only (ClauseQueue under its lock): a jump snapshots
/// the write index at the call, so control and writes must be serialized (tt_ring.h "Roles").
public final class RingO: PlayoutRing {
    /// The C ring, for the IOProc contexts (tt_feed_ctx, tt_monitor_ctx).
    public let raw: OpaquePointer

    /// `minCapacityFrames` is rounded up to a power of two by tt_ring_create (96 000 → 131 072).
    /// `maxLeadFrames`: the writer may be at most this far ahead of the reader (0.5 s for ringO).
    public init?(minCapacityFrames: Int = 96_000, maxLeadFrames: Int = 24_000) {
        guard minCapacityFrames > 0, minCapacityFrames <= Int(UInt32.max),
              let r = tt_ring_create(UInt32(minCapacityFrames)) else { return nil }
        raw = r
        tt_ring_set_max_lead(r, UInt32(clamping: maxLeadFrames))
    }

    deinit { tt_ring_destroy(raw) }

    public var capacityFrames: Int { Int(tt_ring_capacity(raw)) }
    public var availableFrames: Int { Int(tt_ring_available(raw)) }
    public var writtenFrames: UInt64 { tt_ring_written_frames(raw) }
    public var leadRoom: Int { Int(tt_ring_lead_room(raw)) }

    public func writeClause(_ src: UnsafeBufferPointer<Float>?, frames: Int, marks: PlayoutMarks, tag: UInt32) -> Int {
        precondition(frames >= 0 && (src == nil || src!.count >= frames))
        return Int(tt_ring_write_clause(raw, src?.baseAddress, UInt32(clamping: frames), marks.rawValue, tag))
    }

    public func setPause(_ paused: Bool) { tt_ring_set_pause(raw, paused) }
    public var isParked: Bool { tt_ring_is_parked(raw) }

    @discardableResult
    public func requestJump(_ kind: PlayoutJump) -> Bool {
        tt_ring_request_jump(raw, kind == .nextStart ? TT_RING_JUMP_NEXT_START : TT_RING_JUMP_WRITE_INDEX)
    }

    public var jumpPending: Bool { tt_ring_jump_pending(raw) }
    public var playoutState: PlayoutState {
        switch tt_ring_playout_state(raw) {
        case TT_RING_STATE_PLAYING: .playing
        case TT_RING_STATE_UNDERRUN: .underrun
        case TT_RING_STATE_PARKED: .parked
        default: .idle
        }
    }
    public var underruns: UInt64 { tt_ring_playout_underruns(raw) }
    public var markOverflows: UInt64 { tt_ring_mark_overflows(raw) }
    public func reset() { tt_ring_playout_reset(raw) }
}

extension PlayoutRingEvent {
    /// A feedIOProc out.* event drained from the event ring (tt_event_ring.h). nil for other
    /// sources (monitor) and types (passthrough). Host ticks → HostTime with HostClock.
    public init?(_ e: tt_event) {
        guard UInt32(e.source) == TT_EV_SRC_FEED else { return nil }
        let at = HostClock.nanos(fromMachTicks: e.host_ticks)
        let skipped = Int(clamping: e.b)
        switch UInt32(e.type) {
        case TT_EV_OUT_FIRST_SAMPLE: self = .firstSample(tag: e.a, at: at)
        case TT_EV_OUT_UNDERRUN: self = .underrun(at: at)
        case TT_EV_OUT_RESUMED: self = .resumed(at: at)
        case TT_EV_OUT_CLAUSE_CUT: self = .clauseCut(tag: e.a, skipped: skipped, at: at)
        case TT_EV_OUT_FLUSHED: self = .flushed(tag: e.a, skipped: skipped, at: at)
        case TT_EV_OUT_PARKED: self = .parked(at: at)
        case TT_EV_OUT_ENDED: self = .ended(at: at)
        default: return nil
        }
    }
}
