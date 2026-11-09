import Foundation

/// LCP-k commit of streaming ASR hypotheses (ARCHITECTURE.md §5.1, §5.3 "LCPCommitter 是通用组件").
/// The stable prefix is the longest common prefix of the last `agreement` hypotheses (LCP-2 by
/// default), by word for en/de and by character for zh. Committed tokens only grow: when a later
/// hypothesis revises a committed token, the commit is kept (display never rewrites itself) and
/// the revision is counted, which feeds the NE metric (§5.1 target NE ≤0.2).
///
/// Tokens are compared on a normalized key (case-folded, edge punctuation stripped), so
/// "hello" → "Hello," does not break agreement; the committed text uses the newest surface form
/// seen when the token was committed.
public struct LCPCommitter: Sendable, Equatable {
    public enum Unit: Sendable, Equatable {
        case word, character

        public static func `for`(_ lang: Lang) -> Unit { lang == .zh ? .character : .word }
    }

    public let unit: Unit
    public let agreement: Int
    /// When the latest hypotheses agree on a longer prefix that contradicts the commit, take that
    /// prefix instead of waiting for the sentence to end. LISTEN re-translates its whole source
    /// on each draft, so a stale commit would otherwise stop its drafts from growing.
    public let adoptsRevisedPrefix: Bool
    public private(set) var committed: [String] = []
    /// Hypotheses (as tokens) that disagreed with an already committed token.
    public private(set) var revisions = 0
    private var history: [[String]] = []
    /// Whitespace is ignored for character agreement, but retained in the emitted surface
    /// so Chinese speech containing "OpenAI GPT" keeps the original term boundary.
    private var characterSurface = ""

    public init(unit: Unit, agreement: Int = 2, adoptsRevisedPrefix: Bool = false) {
        precondition(agreement >= 1)
        self.unit = unit
        self.agreement = agreement
        self.adoptsRevisedPrefix = adoptsRevisedPrefix
    }

    public var committedText: String { unit == .character ? characterSurface : join(committed) }

    public func tokens(_ s: String) -> [String] {
        switch unit {
        case .word: s.split(whereSeparator: \.isWhitespace).map(String.init)
        case .character: s.filter { !$0.isWhitespace }.map { String($0) }
        }
    }

    public func join(_ t: [String]) -> String {
        unit == .word ? t.joined(separator: " ") : t.joined()
    }

    static func key(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        return (trimmed.isEmpty ? token : trimmed).lowercased()
    }

    /// Feeds a new hypothesis of the current sentence; returns tokens newly committed.
    @discardableResult
    public mutating func update(hypothesis: String) -> [String] {
        let toks = tokens(hypothesis)
        history.append(toks)
        if history.count > agreement { history.removeFirst(history.count - agreement) }
        if committed.count > 0, !Self.hasPrefix(toks, committed.map(Self.key)) { revisions += 1 }
        guard history.count == agreement else { return [] }
        var n = history.map(\.count).min() ?? 0
        for i in 0..<n where !history.allSatisfy({ Self.key($0[i]) == Self.key(history[0][i]) }) {
            n = i
            break
        }
        let stable = Array(toks.prefix(n))
        if adoptsRevisedPrefix, stable.count > committed.count, !Self.hasPrefix(stable, committed.map(Self.key)) {
            committed = []
            characterSurface = ""
        }
        return extend(with: stable, surface: hypothesis)
    }

    /// The recognizer's final for the sentence: everything in it is committed.
    @discardableResult
    public mutating func commitFinal(_ text: String) -> [String] {
        let toks = tokens(text)
        if committed.count > 0, !Self.hasPrefix(toks, committed.map(Self.key)) { revisions += 1 }
        return extend(with: toks, surface: text)
    }

    /// Next sentence (keeps the revision count for the session).
    public mutating func reset() {
        committed = []
        history = []; characterSurface = ""
    }

    private mutating func extend(with stable: [String], surface: String) -> [String] {
        guard stable.count > committed.count,
              Self.hasPrefix(stable, committed.map(Self.key)) else { return [] }
        let new = Array(stable[committed.count...])
        if unit == .character {
            // Only append the newly stable range. Later formatting/revisions cannot rewrite
            // a prefix already shown. Stop at its final character to avoid duplicating spaces.
            var seen = 0
            for character in surface {
                if !character.isWhitespace { seen += 1 }
                if seen > committed.count || (seen == committed.count && seen > 0 && character.isWhitespace) {
                    characterSurface.append(character)
                }
                if seen == stable.count { break }
            }
        }
        committed.append(contentsOf: new)
        return new
    }

    private static func hasPrefix(_ toks: [String], _ keys: [String]) -> Bool {
        guard toks.count >= keys.count else { return false }
        for (i, k) in keys.enumerated() where key(toks[i]) != k { return false }
        return true
    }
}
