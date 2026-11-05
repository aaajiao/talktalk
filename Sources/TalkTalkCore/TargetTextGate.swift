import Foundation
import NaturalLanguage

/// `Resources/prompts/gate.json`.
public struct GatePatterns: Codable, Sendable, Equatable {
    public var version: Int
    public var comment: String?
    public var meta: [String]
    public var fillers: [String: [String]]

    public static func load(from url: URL) throws -> GatePatterns {
        try JSONDecoder().decode(GatePatterns.self, from: Data(contentsOf: url))
    }
    public static func loadDefault() throws -> GatePatterns {
        try load(from: ResourceLocator.url(for: "prompts/gate.json"))
    }
}

/// Language identification for the gate; injectable so tests are deterministic.
public protocol LanguageIdentifying: Sendable {
    /// Best guess and its confidence (0…1), restricted to en and de.
    func identify(_ text: String) -> (Lang, Double)?
}

public struct NLLanguageIdentifier: LanguageIdentifying {
    public init() {}
    public func identify(_ text: String) -> (Lang, Double)? {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.english, .german]
        r.processString(text)
        let h = r.languageHypotheses(withMaximum: 2)
        guard let (lang, p) = h.max(by: { $0.value < $1.value }) else { return nil }
        switch lang {
        case .english: return (.en, p)
        case .german: return (.de, p)
        default: return nil
        }
    }
}

/// TargetTextGate (ARCHITECTURE.md §5.4): the cloned voice never speaks Chinese, empty text or
/// meta-talk. Runs on every MT result (OpenAI, Apple, future backends) before TTS.
public struct TargetTextGate: Sendable {
    public enum Verdict: Sendable, Equatable {
        case pass(String)
        /// The model said `<none>`: nothing to translate, skip silently (not an error).
        case skip
        case reject(Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case empty, tooFewLatin, onlyFillers, containsCJK, wrongLanguage, metaTalk
    }

    public var config: PolicyProfile.Speak.MT.TargetGate
    public var patterns: GatePatterns
    public var identifier: any LanguageIdentifying
    private let metaRegexes: [NSRegularExpression]

    public init(config: PolicyProfile.Speak.MT.TargetGate, patterns: GatePatterns,
                identifier: any LanguageIdentifying = NLLanguageIdentifier()) throws {
        self.config = config
        self.patterns = patterns
        self.identifier = identifier
        self.metaRegexes = try patterns.meta.map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    public static let noneMarker = "<none>"

    /// `text` is the first line of the MT output.
    public func check(_ text: String, target: Lang) -> Verdict {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == Self.noneMarker { return .skip }
        t = t.replacingOccurrences(of: Self.noneMarker, with: "").trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .reject(.empty) }
        if t.unicodeScalars.contains(where: TextScript.isCJK) { return .reject(.containsCJK) }
        let ns = t as NSString
        for r in metaRegexes where r.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil {
            return .reject(.metaTalk)
        }
        let latin = t.unicodeScalars.filter(TextScript.isLatinLetter).count
        if latin < config.minLatinLetters { return .reject(.tooFewLatin) }
        let words = Self.words(t)
        let fillers = Set((patterns.fillers[target.rawValue] ?? []).map { $0.lowercased() })
        if !words.isEmpty, words.allSatisfy({ fillers.contains($0.lowercased()) }) { return .reject(.onlyFillers) }
        if words.count >= config.langIdMinWords, let (lang, p) = identifier.identify(t), lang != target,
           p >= config.langIdMinConf {
            return .reject(.wrongLanguage)
        }
        return .pass(t)
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }).map(String.init)
    }

    /// Recovery ② (§5.4): when every Han run is at most `translitMaxHanRun` characters (mostly
    /// names), transliterate them with ICU `Han-Latin; Latin-ASCII`. nil when a longer run exists.
    public func transliterateShortHanRuns(_ text: String) -> String? {
        var out = ""
        var run = ""
        func flush() -> Bool {
            guard !run.isEmpty else { return true }
            guard run.count <= config.translitMaxHanRun else { return false }
            guard let latin = run.applyingTransform(StringTransform("Han-Latin; Latin-ASCII"), reverse: false) else { return false }
            let words = latin.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            out += words.joined(separator: " ")
            run = ""
            return true
        }
        for ch in text {
            if ch.unicodeScalars.contains(where: TextScript.isHan) { run.append(ch) }
            else { guard flush() else { return nil }; out.append(ch) }
        }
        guard flush() else { return nil }
        return out
    }
}
