import Foundation

/// Drops LISTEN segments that are our own TTS (or passthrough) coming back through the meeting
/// (ARCHITECTURE.md, "实时音频与生命周期约束", `listen.echoFilter`). A segment is dropped only when
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
    /// Clauses on the Feed right now, by clause. Finals can be released mid-playback, before
    /// `recordPlayed` exists for the clause they echo.
    private var playing: [UInt64: Played] = [:]
    /// No clause plays this long. A close that never arrived must not suppress speech forever.
    private static let openClauseLimitMs = 60_000
    /// Recognition is paused for a whole speaking turn, then reads up to this much old audio.
    /// That audio is judged against the clauses that played back then, so they are kept longer
    /// than the match window; `decide` still bounds matches by audio time.
    public static let backlogS = 48
    private var passthrough: [(startMs: Int, endMs: Int)] = []

    public init(config: Config = Config()) {
        self.config = config
    }

    /// A TTS clause whose target text played on the Feed from `startMs` to `endMs`.
    public mutating func recordPlayed(text: String, startMs: Int, endMs: Int) {
        played.append(Played(tokens: Self.tokens(text), startMs: startMs, endMs: endMs))
        prune(nowMs: endMs)
    }

    /// A TTS clause whose first sample just reached the Feed. It counts as playing until
    /// `stopPlaying`.
    public mutating func recordPlaying(clause: UInt64, text: String, startMs: Int) {
        playing = playing.filter { startMs - $0.value.startMs <= Self.openClauseLimitMs }
        playing[clause] = Played(tokens: Self.tokens(text), startMs: startMs, endMs: startMs)
    }

    public mutating func stopPlaying(clause: UInt64) { playing[clause] = nil }

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
                guard o >= config.overlap, Self.hasTextEvidence(segment: seg, played: p.tokens) else { continue }
                let duringPlay = startMs >= p.startMs && startMs <= p.endMs + afterMs
                if acoustic || duringPlay { return .drop(reason: .ttsEcho, overlap: o) }
            }
            for p in playing.values where startMs - p.startMs <= Self.openClauseLimitMs {
                let o = Self.overlap(segment: seg, played: p.tokens)
                guard o >= config.overlap, Self.hasTextEvidence(segment: seg, played: p.tokens) else { continue }
                // Text alone needs a few shared words: a remote "Monday?" can land mid-clause.
                let enough = Set(seg).intersection(p.tokens).count >= 3
                if acoustic || (startMs >= p.startMs && enough) { return .drop(reason: .ttsEcho, overlap: o) }
            }
        }
        if acoustic, passthrough.contains(where: { startMs >= $0.startMs && startMs <= $0.endMs + afterMs }) {
            return .drop(reason: .passthroughEcho, overlap: 0)
        }
        return .keep
    }

    private mutating func prune(nowMs: Int) {
        let keep = Int((config.windowS + config.afterPlayS + Double(Self.backlogS)) * 1000)
        played.removeAll { nowMs - $0.endMs > keep }
        passthrough.removeAll { nowMs - $0.endMs > keep }
    }

    /// Latin letter/digit runs keep the existing behavior, including whole numbers. Han
    /// runs use adjacent two-character tokens so a partial Chinese echo can match a clause.
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = "", han: [Character] = []
        var prev: Character?
        func flushWord() { if !cur.isEmpty { out.append(cur); cur = "" } }
        func flushHan() {
            if han.count == 1 { out.append(String(han[0])) }
            else if han.count > 1 {
                out += zip(han, han.dropFirst()).map { String($0.0) + String($0.1) }
            }
            han.removeAll(keepingCapacity: true)
        }
        for ch in s.lowercased() {
            if ch.unicodeScalars.allSatisfy(TextScript.isHan) {
                flushWord(); han.append(ch)
            } else {
                flushHan()
                if ch.isLetter || ch.isNumber {
                    cur.append(ch)
                } else if (ch == "," || ch == "." || ch == "'"), let p = prev, p.isNumber {
                    // thousands separators / decimals stay inside the number
                } else { flushWord() }
            }
            prev = ch
        }
        flushWord(); flushHan()
        return out
    }

    /// A common short Chinese reply or repeated character is too little evidence by itself.
    /// Require three distinct matching Han pairs (normally at least four Han characters),
    /// or three distinct matching Latin words in mixed text. Pure Latin behavior is unchanged.
    public static func hasTextEvidence(segment: [String], played: [String]) -> Bool {
        guard segment.contains(where: { $0.unicodeScalars.contains(where: TextScript.isHan) }) else { return true }
        let common = Set(segment).intersection(played)
        let hanPairs = common.filter { $0.count == 2 && $0.unicodeScalars.allSatisfy(TextScript.isHan) }
        if hanPairs.count >= 3 { return true }
        return common.filter { $0.unicodeScalars.contains(where: TextScript.isLatinLetter) }.count >= 3
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
