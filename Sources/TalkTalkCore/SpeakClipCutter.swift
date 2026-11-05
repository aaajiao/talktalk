import Foundation

/// M2 release/tail cutter; audio stays in SpeakMicRing. All boundaries use capture host time.
public struct SpeakClipCutter: Sendable {
    public struct Cut: Sendable {
        public let start, end: HostTime
        public let isFinal: Bool
        public let speechMs: Int
        public let reason: SpeakClip.CutReason
    }
    private struct Frame: Sendable { var start, end: HostTime; var voiced: Bool; var energy: Double }
    private var frames: [Frame] = []
    private var next: HostTime
    private var observed: HostTime
    private var releasedAt: HostTime?
    private let cap, tail, dip, energyWindow: UInt64
    public private(set) var finished = false
    public init(start: HostTime, profile: PolicyProfile.Speak) {
        next = start; observed = start
        cap = UInt64(profile.forceCut.clipMaxSUntilSteppedASR * 1e9)
        tail = UInt64(profile.ptt.tailMs) * 1_000_000
        dip = UInt64(profile.forceCut.dipMs) * 1_000_000
        energyWindow = UInt64(profile.forceCut.minEnergyWindowMs) * 1_000_000
    }
    public mutating func release(at host: HostTime, trailingSilenceMs: Int) -> [Cut] {
        let silence = UInt64(max(0, trailingSilenceMs)) * 1_000_000
        releasedAt = host + (tail > silence ? tail - silence : 0)
        return drain()
    }
    public mutating func push(start: HostTime, end: HostTime, voiced: Bool, rmsDb: Double) -> [Cut] {
        guard !finished, end > start else { return [] }
        frames.append(Frame(start: start, end: end, voiced: voiced, energy: rmsDb))
        observed = max(observed, end)
        return drain()
    }
    /// Format/death interruption: no tail from a different device/rate is ever added.
    public mutating func finish(at host: HostTime) -> [Cut] { observed = max(host, observed); releasedAt = host; return drain() }

    private mutating func drain() -> [Cut] {
        var cuts: [Cut] = []
        let available = min(observed, releasedAt ?? observed)
        while available > next {
            if let release = releasedAt, observed >= release, available - next <= cap {
                let speech = speechMs(from: next, to: available)
                if speech >= 400 { cuts.append(Cut(start: next, end: available, isFinal: true, speechMs: speech, reason: .release)) }
                next = available; finished = true; frames.removeAll(); break
            }
            guard available - next >= cap else { break }
            let limit = next + cap
            let selected = boundary(through: limit)
            let speech = speechMs(from: next, to: selected.0)
            // A full window may be silent. Advancing still prevents an unbounded press buffer.
            if speech >= 400 { cuts.append(Cut(start: next, end: selected.0, isFinal: false, speechMs: speech, reason: selected.1)) }
            next = selected.0
            frames.removeAll { $0.end <= next }
        }
        if let release = releasedAt, observed >= release, available <= next { finished = true }
        return cuts
    }
    private func speechMs(from start: HostTime, to end: HostTime) -> Int {
        let ns = frames.filter(\.voiced).reduce(UInt64(0)) { total, f in
            let lo = max(start, f.start), hi = min(end, f.end)
            return total + (hi > lo ? hi - lo : 0)
        }
        return Int(ns / 1_000_000)
    }
    private func boundary(through limit: HostTime) -> (HostTime, SpeakClip.CutReason) {
        let lower = next + 400_000_000
        var quietStart: HostTime?, bestDip: HostTime?
        for f in frames where f.start < limit && f.end > next {
            if !f.voiced { quietStart = quietStart ?? max(f.start, next) }
            if let start = quietStart {
                let end = min(f.voiced ? f.start : f.end, limit)
                if end >= start + dip {
                    let middle = start + (end - start) / 2
                    if middle >= lower { bestDip = middle }
                }
            }
            if f.voiced { quietStart = nil }
        }
        if let bestDip { return (bestDip, .vadDip) }
        var best: (HostTime, Double)?
        for f in frames where f.start >= lower && f.start + energyWindow <= limit {
            let end = f.start + energyWindow
            let group = frames.filter { $0.end > f.start && $0.start < end }
            let energy = group.reduce(0.0) { $0 + pow(10, $1.energy / 10) } / Double(max(1, group.count))
            if best == nil || energy <= best!.1 { best = (f.start + energyWindow / 2, energy) }
        }
        return best.map { ($0.0, .energyMinimum) } ?? (limit, .limit)
    }
}
