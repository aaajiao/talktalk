/// The all-zero watchdog for the macOS 26.x tap bug (ARCHITECTURE.md). Pure; the meeting
/// session feeds it once per second (or faster) and acts on the result.
///
///  - The tap is rebuilt only after this meeting process already delivered non-zero audio in this
///    meeting, and then `IsRunningOutput` stayed true with exact zeros for `zeroSeconds` (10 s).
///    Rebuilds back off 60 s, 120 s, 240 s, … (no rebuild sooner than that after the previous one).
///  - If it never delivered non-zero audio, nothing is rebuilt; the HUD shows "会议当前没有声音".
///    Silence is never taken as a TCC verdict (only TCCProbe decides that).
public struct TapWatchdog: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case ok
        /// Running output but no sound yet this meeting: show the hint, do not rebuild.
        case noAudioYet
        /// Rebuild tap + aggregate now (the n-th rebuild of this meeting).
        case rebuild(attempt: Int)
        /// Stuck at zeros, but inside the backoff window.
        case backingOff(untilMs: Int)
    }

    public let zeroSeconds: Double
    public let firstBackoffS: Double
    public let maxBackoffS: Double
    public private(set) var everNonZero = false
    public private(set) var rebuilds = 0
    private var zerosSinceMs: Int?
    private var outputSinceMs: Int?
    private var lastRebuildMs: Int?

    public init(zeroSeconds: Double = 10, firstBackoffS: Double = 60, maxBackoffS: Double = 960) {
        self.zeroSeconds = zeroSeconds
        self.firstBackoffS = firstBackoffS
        self.maxBackoffS = maxBackoffS
    }

    /// `lastNonZeroMs`: when the tap last carried a non-zero sample (nil = never).
    public mutating func observe(nowMs: Int, runningOutput: Bool, lastNonZeroMs: Int?) -> Verdict {
        if let nz = lastNonZeroMs, nowMs - nz < 1000 {
            everNonZero = true
            zerosSinceMs = nil
            if runningOutput, outputSinceMs == nil { outputSinceMs = nowMs }
            return .ok
        }
        if lastNonZeroMs != nil { everNonZero = true }
        guard runningOutput else {
            zerosSinceMs = nil
            outputSinceMs = nil
            return .ok
        }
        if outputSinceMs == nil { outputSinceMs = nowMs }
        guard everNonZero else { return .noAudioYet }
        // Zeros count from the later of the last sound and the moment output (re)started.
        let since = zerosSinceMs ?? max(lastNonZeroMs ?? nowMs, outputSinceMs ?? nowMs)
        zerosSinceMs = since
        guard Double(nowMs - since) >= zeroSeconds * 1000 else { return .ok }
        if let last = lastRebuildMs {
            let backoff = min(maxBackoffS, firstBackoffS * Double(1 << min(rebuilds - 1, 10)))
            let until = last + Int(backoff * 1000)
            if nowMs < until { return .backingOff(untilMs: until) }
        }
        rebuilds += 1
        lastRebuildMs = nowMs
        zerosSinceMs = nowMs   // give the new tap a fresh 10 s
        return .rebuild(attempt: rebuilds)
    }

    /// A new meeting (or a different meeting process): forget history.
    public mutating func reset() {
        everNonZero = false
        rebuilds = 0
        zerosSinceMs = nil
        outputSinceMs = nil
        lastRebuildMs = nil
    }
}
