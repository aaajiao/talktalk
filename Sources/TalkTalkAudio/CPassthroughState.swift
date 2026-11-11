import CAudioCore
import TalkTalkCore

/// `PassthroughStateSink` over CAudioCore's tt_pt_state (ARCHITECTURE.md, "实时音频与生命周期约束"):
/// the seqlock state feedIOProc reads once per IO cycle. The gate is the only writer and calls
/// under its own lock (the protocol's contract), so writes never interleave; the IOProc only reads.
///
/// Times arrive in ns (HostTime) and are stored in mach ticks, converted here with
/// `HostClock.machTicks(fromNanos:)` (§12.2: no conversion on the real-time thread). The
/// semantics are `InMemoryPassthroughStateSink`'s; `CPassthroughStateTests` runs both side by side.
public final class CPassthroughState: PassthroughStateSink, @unchecked Sendable {
    /// For tt_feed_ctx (FeedOutput) in this module.
    let raw: OpaquePointer

    /// A new state is closed, generation 0.
    public init?() {
        guard let s = tt_pt_state_create() else { return nil }
        raw = s
    }

    deinit { tt_pt_state_destroy(raw) }

    public func open(source: PassthroughSource, openAt: HostTime, leaseUntil: HostTime, deadline: HostTime) -> UInt32 {
        tt_pt_state_open(raw, Self.cSource(source), HostClock.machTicks(fromNanos: openAt),
                         HostClock.machTicks(fromNanos: leaseUntil), HostClock.machTicks(fromNanos: deadline))
    }

    @discardableResult
    public func renew(generation: UInt32, leaseUntil: HostTime) -> Bool {
        tt_pt_state_renew(raw, generation, HostClock.machTicks(fromNanos: leaseUntil))
    }

    @discardableResult
    public func close(generation: UInt32, at: HostTime) -> Bool {
        tt_pt_state_close(raw, generation, HostClock.machTicks(fromNanos: at))
    }

    /// What feedIOProc reads now, times back in ns (diagnostics, tests). nil: no consistent read
    /// (the IOProc treats that as closed).
    public var current: PassthroughState? {
        let s = tt_pt_state_read(raw)
        guard s.valid != 0 else { return nil }
        return PassthroughState(open: s.open != 0, generation: s.generation,
                                source: s.source == TT_PT_SOURCE_SELF_TEST ? .selfTest : .mic,
                                openAt: HostClock.nanos(fromMachTicks: s.open_ticks),
                                leaseUntil: HostClock.nanos(fromMachTicks: s.lease_until_ticks),
                                deadline: HostClock.nanos(fromMachTicks: s.deadline_ticks))
    }

    public var failedReads: UInt64 { tt_pt_state_failed_reads(raw) }

    /// The C source id. Which Feed channel a source goes to is decided by tt_pt_source_channel
    /// in the IOProc (and named only in PassthroughGate on the Swift side), not here.
    static func cSource(_ s: PassthroughSource) -> UInt32 {
        switch s {
        case .mic: TT_PT_SOURCE_MIC
        case .selfTest: TT_PT_SOURCE_SELF_TEST
        }
    }
}
