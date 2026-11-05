import CAudioCore
import TalkTalkCore

/// One 10 ms envelope point (tt_envelope_point), time in ns.
public struct EnvelopePoint: Sendable, Equatable {
    /// 0, 1, 2, ... with no gaps on the producer side.
    public let seq: UInt64
    /// Host time of the window's first frame. For the Feed envelope: when it reaches TalkTalk Mic.
    public let at: HostTime
    /// Linear RMS of the window.
    public let rms: Float
    /// Max |sample| in the window.
    public let peak: Float

    public init(seq: UInt64, at: HostTime, rms: Float, peak: Float) {
        self.seq = seq; self.at = at; self.rms = rms; self.peak = peak
    }
}

/// The RMS envelope history for the acoustic echo score (tt_envelope.h, ARCHITECTURE.md §3.5,
/// §3.8 "Feed 输出包络"): a real-time producer publishes a point per 10 ms window, the history
/// keeps the latest 512 (5.12 s). One consumer (EchoScorer on the audio worker) reads it.
public final class EnvelopeHistory: @unchecked Sendable {
    /// For the IOProc context that pushes (tt_feed_ctx) in this module.
    let raw: OpaquePointer

    /// `windowFrames` per point (480 = 10 ms at 48 kHz); `hostTicksPerFrame` dates each point.
    init?(windowFrames: UInt32, hostTicksPerFrame: Double) {
        guard let e = tt_envelope_create(windowFrames, hostTicksPerFrame) else { return nil }
        raw = e
    }

    deinit { tt_envelope_destroy(raw) }

    public static let capacity = Int(TT_ENVELOPE_POINTS)

    /// Points published so far.
    public var count: UInt64 { tt_envelope_count(raw) }
    /// Points the consumer's cursor skipped because they were overwritten before it read them.
    public var lostPoints: UInt64 { tt_envelope_lost_points(raw) }

    /// Consumer: up to `max` points from seq `cursor` on, oldest first; advances `cursor` past
    /// them (and over points already overwritten, counted in `lostPoints`).
    public func read(cursor: inout UInt64, max: Int = EnvelopeHistory.capacity) -> [EnvelopePoint] {
        fill(max) { tt_envelope_read(raw, &cursor, $0, $1) }
    }

    /// Consumer: the latest min(max, available) points, oldest first (the last 3 s for echoScore).
    public func recent(max: Int = EnvelopeHistory.capacity) -> [EnvelopePoint] {
        fill(max) { tt_envelope_read_recent(raw, $0, $1) }
    }

    private func fill(_ max: Int, _ read: (UnsafeMutablePointer<tt_envelope_point>, UInt32) -> UInt32) -> [EnvelopePoint] {
        let n = Swift.min(Swift.max(max, 0), Self.capacity)
        guard n > 0 else { return [] }
        let points = [tt_envelope_point](unsafeUninitializedCapacity: n) { buf, count in
            count = Int(read(buf.baseAddress!, UInt32(n)))
        }
        return points.map {
            EnvelopePoint(seq: $0.seq, at: HostClock.nanos(fromMachTicks: $0.host_ticks), rms: $0.rms, peak: $0.peak)
        }
    }
}
