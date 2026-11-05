import Foundation

/// Drops LISTEN segments that are our own TTS (or passthrough) coming back through the meeting
/// (ARCHITECTURE.md §3.5, `listen.echoFilter`). A segment is dropped only when
///   - its normalized tokens overlap a TTS target text played in the last `windowS` by ≥ `overlap`,
///     AND (the acoustic `echoScore` ≥ `echoScoreMax`, OR the segment started between that
///     clause's playback start and `afterPlayS` after its end);
///   - or, with no text to compare, it started while passthrough was open or within
///     `afterPlayS` of it closing, and `echoScore` ≥ `echoScoreMax`.
/// Text overlap alone never drops ("So, 300,000 euros, right?" is the remote repeating us).
///
/// M1 has no TTS yet, so nothing is recorded and nothing is dropped; SPEAK (M2) calls
/// `recordPlayed` / `recordPassthrough`, and the worker's echo-envelope correlation supplies
/// `echoScore`.
public struct EchoFilter: Sendable {
    public struct Config: Sendable, Equatable {
        public var overlap: Double
        public var windowS: Double
        public var afterPlayS: Double
        public var echoScoreMax: Double

        public init(overlap: Double = 0.6, windowS: Double = 20, afterPlayS: Double = 2, echoScoreMax: Double = 0.5) {
            self.overlap = overlap; self.windowS = windowS; self.afterPlayS = afterPlayS; self.echoScoreMax = echoScoreMax
        }

        public init(_ p: PolicyProfile.Listen.EchoFilter, echoScoreMax: Double = 0.5) {
            self.init(overlap: p.overlap, windowS: Double(p.windowS), afterPlayS: Double(p.afterPlayS), echoScoreMax: echoScoreMax)
        }
    }

    public enum Decision: Sendable, Equatable {
        case keep
        case drop(reason: Reason, overlap: Double)
        public enum Reason: String, Sendable { case ttsEcho, passthroughEcho }
    }

    struct Played: Sendable { var tokens: [String]; var startMs: Int; var endMs: Int }

    public let config: Config
    private var played: [Played] = []
    private var passthrough: [(startMs: Int, endMs: Int)] = []

    public init(config: Config = Config()) {
        self.config = config
    }

    /// A TTS clause whose target text played on the Feed from `startMs` to `endMs`.
    public mutating func recordPlayed(text: String, startMs: Int, endMs: Int) {
        played.append(Played(tokens: Self.tokens(text), startMs: startMs, endMs: endMs))
        prune(nowMs: endMs)
    }

    public mutating func recordPassthrough(startMs: Int, endMs: Int) {
        guard endMs >= startMs else { return }
        // Automatic original audio can remain open for the whole conversation. Its live
        // observations extend one interval instead of accumulating a record on every tick.
        if let last = passthrough.last, startMs <= last.endMs, endMs >= last.startMs {
            passthrough[passthrough.count - 1] = (min(startMs, last.startMs), max(endMs, last.endMs))
        } else { passthrough.append((startMs, endMs)) }
        prune(nowMs: endMs)
    }

    public func decide(text: String, startMs: Int, echoScore: Double?) -> Decision {
        let seg = Self.tokens(text)
        let acoustic = (echoScore ?? 0) >= config.echoScoreMax
        let windowMs = Int(config.windowS * 1000), afterMs = Int(config.afterPlayS * 1000)
        if !seg.isEmpty {
            for p in played where startMs - p.endMs <= windowMs {
                let o = Self.overlap(segment: seg, played: p.tokens)
                guard o >= config.overlap else { continue }
                let duringPlay = startMs >= p.startMs && startMs <= p.endMs + afterMs
                if acoustic || duringPlay { return .drop(reason: .ttsEcho, overlap: o) }
            }
        }
        if acoustic, passthrough.contains(where: { startMs >= $0.startMs && startMs <= $0.endMs + afterMs }) {
            return .drop(reason: .passthroughEcho, overlap: 0)
        }
        return .keep
    }

    private mutating func prune(nowMs: Int) {
        let keep = Int((config.windowS + config.afterPlayS) * 1000)
        played.removeAll { nowMs - $0.endMs > keep }
        passthrough.removeAll { nowMs - $0.endMs > keep }
    }

    /// Lower-cased letter/digit runs; digits inside numbers are kept together ("300,000" → "300000").
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var prev: Character?
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                cur.append(ch)
            } else if (ch == "," || ch == "." || ch == "'"), let p = prev, p.isNumber {
                // thousands separators / decimals stay inside the number
            } else if !cur.isEmpty {
                out.append(cur); cur = ""
            }
            prev = ch
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Share of the segment's tokens (multiset) found in the played clause.
    public static func overlap(segment: [String], played: [String]) -> Double {
        guard !segment.isEmpty else { return 0 }
        var bag: [String: Int] = [:]
        for t in played { bag[t, default: 0] += 1 }
        var hit = 0
        for t in segment where (bag[t] ?? 0) > 0 {
            hit += 1
            bag[t]! -= 1
        }
        return Double(hit) / Double(segment.count)
    }
}
