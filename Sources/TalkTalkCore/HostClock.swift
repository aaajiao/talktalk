import Darwin

/// The one host clock (ARCHITECTURE.md, "实时音频与生命周期约束"): nanoseconds of `CLOCK_UPTIME_RAW`, the same
/// source as `AudioTimeStamp.mHostTime` (in mach ticks) and Python's `CLOCK_UPTIME_RAW`.
/// It stops during sleep, so timestamps across a sleep are not subtracted (`sys.wake`).
public enum HostClock {
    public static func now() -> HostTime {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// `mHostTime` (mach absolute ticks) → nanoseconds. On Apple silicon one tick is 125/3 ns.
    public static func nanos(fromMachTicks ticks: UInt64) -> HostTime {
        let (n, d) = timebase
        if n == d { return ticks }
        let (hi, lo) = ticks.multipliedFullWidth(by: n)
        return d.dividingFullWidth((hi, lo)).quotient
    }

    public static func machTicks(fromNanos ns: HostTime) -> UInt64 {
        let (n, d) = timebase
        if n == d { return ns }
        let (hi, lo) = ns.multipliedFullWidth(by: d)
        return n.dividingFullWidth((hi, lo)).quotient
    }

    public static func ms(_ a: HostTime, to b: HostTime) -> Int {
        b >= a ? Int((b - a) / 1_000_000) : -Int((a - b) / 1_000_000)
    }
}
