import Foundation

/// Whether a short SPEAK clip only re-says the ending of the previous accepted source of the same
/// press (ARCHITECTURE 翻译轮次隔离). Missing a repeat is preferred to deleting a correction: the
/// first unit must match exactly, and apart from a few modal or filler particles no unit may be
/// added, removed or changed (a changed particle costs two edits).
public struct SpeakRepeatCheck: Sendable {
    public enum Verdict: String, Sendable {
        case repeated = "repeat", previousNotSent, noPrevious, shortReply, longSpeech, fewTokens
        case protectedEdit, notAtEnd, different
    }
    public struct Result: Sendable, Equatable {
        public var verdict: Verdict
        public var tokens: Int
        /// Share of this clip's units that appear, in order, in the previous source; diagnostics only.
        public var similarityPct: Int?
    }
    public let config: PolicyProfile.Speak.Gate.PreviousRepeat
    public init(_ profile: PolicyProfile.Speak) { config = profile.gate.previousRepeat }

    /// The only units a repeat may add or drop. Characters that can carry meaning by themselves
    /// (得 "must", 地 "ground", 呢, 吗) are deliberately absent.
    static let tolerated: Set<Character> = Set("了的吧啊呀啦嘛哦呃嗯哈")

    /// Symbols that change what a figure means. Currency and math symbols (+ − ± < > …) are units
    /// too; a hyphen or dash counts only next to a letter or digit (A-, -5, e-mail).
    static let figureSymbols: Set<Character> = Set("%‰‱°"), dashes: Set<Character> = Set("-\u{2012}\u{2013}")

    /// NFKC and lowercase; each Han character is a unit, a run of other letters or digits is one
    /// unit, currency, math and figure symbols are units of their own, and everything else
    /// (punctuation, spaces) only separates units.
    static func tokens(_ text: String) -> [String] {
        var units: [String] = [], run = ""
        let characters = Array(text.precomposedStringWithCompatibilityMapping.lowercased())
        for (index, character) in characters.enumerated() {
            if character.unicodeScalars.allSatisfy(TextScript.isHan) {
                if !run.isEmpty { units.append(run); run = "" }
                units.append(String(character))
            } else if character.isLetter || character.isNumber {
                run.append(character)
            } else {
                if !run.isEmpty { units.append(run); run = "" }
                let category = character.unicodeScalars.count == 1 ? character.unicodeScalars.first?.properties.generalCategory : nil
                func word(_ i: Int) -> Bool { characters.indices.contains(i) && (characters[i].isLetter || characters[i].isNumber) }
                if category == .currencySymbol || category == .mathSymbol || figureSymbols.contains(character)
                    || (dashes.contains(character) && (word(index - 1) || word(index + 1))) {
                    units.append(String(character))
                }
            }
        }
        if !run.isEmpty { units.append(run) }
        return units
    }

    static func isTolerated(_ unit: String) -> Bool { unit.count == 1 && unit.first.map(tolerated.contains) == true }

    /// Cost of aligning all of `a` to some span of `b` using only added or removed units (a
    /// substitution costs 2); the span's start in `b` is free. `anywhere` lets the span end
    /// anywhere, `suffix` requires it to end at the end of `b`. With `protect`, only tolerated
    /// particles other than `a[0]` may be added or removed.
    static func distance(_ a: [String], in b: [String], protect: Bool) -> (anywhere: Int, suffix: Int) {
        let blocked = a.count + 1
        func costA(_ i: Int) -> Int { !protect || (i > 0 && isTolerated(a[i])) ? 1 : blocked }
        func costB(_ j: Int) -> Int { !protect || isTolerated(b[j]) ? 1 : blocked }
        var row = [Int](repeating: 0, count: b.count + 1)
        for i in a.indices {
            var next = [Int](repeating: 0, count: b.count + 1)
            next[0] = row[0] + costA(i)
            for j in b.indices {
                var best = min(row[j + 1] + costA(i), next[j] + costB(j))
                if a[i] == b[j] { best = min(best, row[j]) }
                next[j + 1] = best
            }
            row = next
        }
        return (row.min() ?? 0, row.last ?? 0)
    }

    /// Longest common subsequence length.
    static func common(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for unit in a {
            var next = [Int](repeating: 0, count: b.count + 1)
            for j in b.indices { next[j + 1] = unit == b[j] ? row[j] + 1 : max(row[j + 1], next[j]) }
            row = next
        }
        return row.last ?? 0
    }

    /// `short`: VAD speech below `commitMin(for:).speechS`. `previous`: the same press's last
    /// accepted source, or nil. `previousUndelivered`: that source is already known not to have
    /// been sent, so re-saying its ending is not a repeat.
    public func evaluate(_ text: String, previous: String?, previousUndelivered: Bool = false,
                         short: Bool, shortReply: Bool) -> Result {
        let a = Self.tokens(text), n = a.count
        guard let previous else { return .init(verdict: .noPrevious, tokens: n, similarityPct: nil) }
        guard n > 0 else { return .init(verdict: .fewTokens, tokens: 0, similarityPct: nil) }
        let b = Self.tokens(previous)
        let pct = Int((100 * Double(Self.common(a, b)) / Double(n)).rounded())
        func result(_ verdict: Verdict) -> Result { .init(verdict: verdict, tokens: n, similarityPct: pct) }
        if shortReply { return result(.shortReply) }
        if !short { return result(.longSpeech) }
        if n < config.minTokens { return result(.fewTokens) }
        let allowed = n / max(1, config.tokensPerEdit)
        if Self.distance(a, in: b, protect: true).suffix <= allowed {
            return result(previousUndelivered ? .previousNotSent : .repeated)
        }
        let plain = Self.distance(a, in: b, protect: false)
        if plain.suffix <= allowed { return result(.protectedEdit) }
        if plain.anywhere <= allowed { return result(.notAtEnd) }
        return result(.different)
    }
}
