import Foundation

/// French number mentions for the translation guard. The grammar consumes complete number
/// phrases only, so adjacent numbers or a comma-separated list are not added together.
enum FrenchNumerals {
    private struct Token {
        var word: String
        var range: NSRange
        var isNumber: Bool
    }

    private static let small: [String: Int] = [
        "zero": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
        "six": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10, "onze": 11, "douze": 12,
        "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16, "vingt": 20, "vingts": 20,
        "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60,
        "septante": 70, "huitante": 80, "octante": 80, "nonante": 90,
    ]
    private static let scales: [String: Double] = [
        "mille": 1_000, "million": 1_000_000, "millions": 1_000_000,
        "milliard": 1_000_000_000, "milliards": 1_000_000_000,
    ]
    private static let months = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet",
                                 "aout", "septembre", "octobre", "novembre", "decembre"]
    private static let ordinalSuffixes: Set<String> = ["er", "ers", "re", "res", "ere", "eres", "e", "es", "eme", "emes", "ieme", "iemes"]
    private static let standaloneOrdinals: Set<String> = ["premier", "premiere", "premiers", "premieres", "second", "seconde", "seconds", "secondes"]
    private static let lexer = try! NSRegularExpression(pattern:
        #"\d{1,3}(?:[ \u00A0\u202F']\d{3})+(?:[,.]\d+)?|\d+(?:[,.]\d+)*|\p{L}+|%"#)
    private static let groupedDigits = try! NSRegularExpression(pattern:
        #"\A\d{1,3}(?:[ \u00A0\u202F']\d{3})+(?:[,.]\d+)?\z"#)

    static func parseDigits(_ text: String) -> Double? {
        var clean = text
        if clean.contains(where: { $0.isWhitespace || $0 == "'" }) {
            let range = NSRange(clean.startIndex..<clean.endIndex, in: clean)
            guard groupedDigits.firstMatch(in: clean, range: range) != nil else { return nil }
            clean.removeAll { $0.isWhitespace || $0 == "'" }
        }
        // In French a comma is always decimal, including exactly three fractional digits.
        if clean.contains(",") {
            let parts = clean.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isASCIIDigit) else { return nil }
            let groups = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard !groups[0].isEmpty, groups.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
                  groups.count == 1 || groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            clean = groups.joined() + "." + String(parts[1])
        } else if clean.filter({ $0 == "." }).count > 1 {
            let groups = clean.split(separator: ".", omittingEmptySubsequences: false)
            guard !groups[0].isEmpty, groups.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            clean = groups.joined()
        }
        guard let value = Double(clean), value.isFinite else { return nil }
        return value
    }

    static func mentions(in text: String) -> [NumberGuard.Mention] {
        let ns = text as NSString
        let tokens = lexer.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let surface = ns.substring(with: match.range)
            return Token(word: surface.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")),
                         range: match.range, isNumber: surface.first?.isASCIIDigit == true)
        }
        func connected(_ left: Int, _ right: Int) -> Bool {
            let gap = NSRange(location: NSMaxRange(tokens[left].range), length: tokens[right].range.location - NSMaxRange(tokens[left].range))
            return ns.substring(with: gap).allSatisfy { $0.isWhitespace || $0 == "-" || $0 == "‑" }
        }
        func surface(_ from: Int, _ to: Int) -> String {
            ns.substring(with: NSRange(location: tokens[from].range.location,
                                       length: NSMaxRange(tokens[to - 1].range) - tokens[from].range.location))
        }
        func wordLimit(from start: Int) -> Int {
            var limit = start
            while limit < tokens.count, !tokens[limit].isNumber, numberWord(tokens[limit].word),
                  limit == start || (connected(limit - 1, limit) && !standaloneOrdinals.contains(tokens[limit].word)) { limit += 1 }
            return limit
        }
        func cents(at start: Int) -> (value: Double, end: Int)? {
            guard start < tokens.count else { return nil }
            if tokens[start].isNumber {
                guard let amount = parseDigits(ns.substring(with: tokens[start].range)),
                      amount >= 0, amount < 100, amount == amount.rounded() else { return nil }
                return (amount, start + 1)
            }
            let limit = wordLimit(from: start)
            guard limit > start else { return nil }
            for candidate in stride(from: limit, through: start + 1, by: -1) {
                if let (amount, kind) = parseWords(tokens[start..<candidate].map(\.word)),
                   kind == .cardinal, amount >= 0, amount < 100, amount == amount.rounded() {
                    return (amount, candidate)
                }
            }
            return nil
        }
        var out: [NumberGuard.Mention] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // After a quantity, seconde(s) is a time unit, not the ordinal "second".
            if ["seconde", "secondes"].contains(token.word), index > 0, connected(index - 1, index),
               tokens[index - 1].isNumber || cardinal([tokens[index - 1].word]) != nil {
                index += 1
                continue
            }
            if let month = months.firstIndex(of: token.word) {
                out.append(.init(value: Double(month + 1), kind: .month, text: surface(index, index + 1)))
                index += 1
                continue
            }
            var value: Double?
            var kind = NumberGuard.Kind.cardinal
            var end = index + 1
            if token.isNumber {
                value = parseDigits(ns.substring(with: token.range))
                if end < tokens.count, connected(index, end), ordinalSuffixes.contains(tokens[end].word) {
                    kind = .ordinal; end += 1
                }
            } else {
                let limit = wordLimit(from: index)
                if limit > index {
                    for candidate in stride(from: limit, through: index + 1, by: -1) {
                        if let parsed = parseWords(tokens[index..<candidate].map(\.word)) {
                            value = parsed.0; kind = parsed.1; end = candidate
                            break
                        }
                    }
                }
            }
            // Both digits and a spoken decimal can precede a magnitude: "1,5 million" or
            // "un virgule cinq million". Cardinal phrases already include their own scales.
            if end < tokens.count, connected(end - 1, end), let scale = scales[tokens[end].word], let number = value {
                value = number * scale; end += 1
            }
            // The common spoken half construction is bounded to "et demi(e)"; this is not
            // a general fraction parser. The half shares the immediately preceding magnitude.
            if let number = value, kind == .cardinal, end + 1 < tokens.count,
               connected(end - 1, end), tokens[end].word == "et", connected(end, end + 1),
               ["demi", "demie"].contains(tokens[end + 1].word) {
                let magnitude = scales[tokens[end - 1].word] ?? 1
                value = number + 0.5 * magnitude
                end += 2
                if magnitude == 1, end < tokens.count, connected(end - 1, end), let scale = scales[tokens[end].word] {
                    value = (number + 0.5) * scale; end += 1
                }
            }
            // French amounts often omit "centimes": "deux euros cinquante" / "2 euros 50".
            // Only euros with an integer amount and 0–99 cents are combined here.
            if let euros = value, kind == .cardinal, euros == euros.rounded(), end + 1 < tokens.count,
               connected(end - 1, end), ["euro", "euros"].contains(tokens[end].word), connected(end, end + 1) {
                var centStart = end + 1
                if tokens[centStart].word == "et", centStart + 1 < tokens.count, connected(centStart, centStart + 1) { centStart += 1 }
                if let amount = cents(at: centStart) {
                    value = euros + amount.value / 100
                    end = amount.end
                    if end < tokens.count, connected(end - 1, end), ["centime", "centimes"].contains(tokens[end].word) { end += 1 }
                }
            }
            guard let value else { index += 1; continue }
            if end < tokens.count, connected(end - 1, end) {
                if tokens[end].word == "%" { kind = .percent; end += 1 }
                else if tokens[end].word == "pour", end + 1 < tokens.count,
                        connected(end, end + 1), tokens[end + 1].word == "cent" {
                    kind = .percent; end += 2
                }
            }
            // un/une alone is usually an article; numeric 1, ordinals and one percent remain.
            if token.isNumber || value != 1 || kind != .cardinal || end > index + 1 {
                out.append(.init(value: value, kind: kind, text: surface(index, end)))
            }
            index = end
        }
        return out
    }

    private static func numberWord(_ word: String) -> Bool {
        small[word] != nil || scales[word] != nil || ["cent", "cents", "et", "virgule"].contains(word)
            || ordinalCardinal(word) != nil
    }

    private static func parseWords(_ words: [String]) -> (Double, NumberGuard.Kind)? {
        if let comma = words.firstIndex(of: "virgule") {
            guard comma > 0, comma + 1 < words.count, let whole = cardinal(Array(words[..<comma])) else { return nil }
            let fractional = Array(words[(comma + 1)...])
            let digits: String
            if fractional.allSatisfy({ small[$0].map { $0 < 10 } == true }) {
                digits = fractional.map { String(small[$0]!) }.joined()
            } else if let part = cardinal(fractional), part < 1_000, part == part.rounded() {
                digits = String(Int(part))
            } else { return nil }
            guard let fraction = Double("0." + digits) else { return nil }
            return (whole + fraction, .cardinal)
        }
        if let last = words.last, let replacement = ordinalCardinal(last) {
            guard let value = cardinal(Array(words.dropLast()) + [replacement]) else { return nil }
            return (value, .ordinal)
        }
        return cardinal(words).map { ($0, .cardinal) }
    }

    private static func ordinalCardinal(_ word: String) -> String? {
        if ["premier", "premiere", "premiers", "premieres"].contains(word) { return "un" }
        if ["second", "seconde", "seconds", "secondes"].contains(word) { return "deux" }
        let singular = word.hasSuffix("s") ? String(word.dropLast()) : word
        guard singular.hasSuffix("ieme") else { return nil }
        let stem = String(singular.dropLast(4))
        if stem == "cinqu" { return "cinq" }
        if stem == "neuv" { return "neuf" }
        for candidate in [stem, stem + "e"] where small[candidate] != nil || scales[candidate] != nil || candidate == "cent" {
            return candidate
        }
        return nil
    }

    private static func cardinal(_ words: [String], below maximumScale: Double = .infinity) -> Double? {
        guard !words.isEmpty else { return nil }
        for scale in [1_000_000_000.0, 1_000_000.0, 1_000.0] where scale < maximumScale {
            if let index = words.firstIndex(where: { scales[$0] == scale }) {
                let prefix = Array(words[..<index]), suffix = Array(words[(index + 1)...])
                guard let multiplier = prefix.isEmpty ? 1 : cardinal(prefix, below: scale),
                      let remainder = suffix.isEmpty ? 0 : cardinal(suffix, below: scale), remainder < scale else { return nil }
                return multiplier * scale + remainder
            }
        }
        if let index = words.firstIndex(where: { $0 == "cent" || $0 == "cents" }) {
            // Years also use century readings: "dix-neuf cent quatre-vingt-dix-neuf".
            let multiplier = index == 0 ? 1 : belowHundred(Array(words[..<index]))
            guard let multiplier, (1...19).contains(multiplier) else { return nil }
            let rest = Array(words[(index + 1)...])
            guard let remainder = rest.isEmpty ? 0 : belowHundred(rest) else { return nil }
            return Double(multiplier * 100 + remainder)
        }
        return belowHundred(words).map(Double.init)
    }

    private static func belowHundred(_ words: [String]) -> Int? {
        guard let first = words.first else { return nil }
        if words.count == 1 { return small[first] }
        if first == "dix", words.count == 2, let tail = small[words[1]], (7...9).contains(tail) { return 10 + tail }
        if first == "quatre", words.count >= 2, ["vingt", "vingts"].contains(words[1]) {
            if words.count == 2 { return 80 }
            guard let tail = belowHundred(Array(words.dropFirst(2))), (1...19).contains(tail) else { return nil }
            return 80 + tail
        }
        guard let tens = small[first], tens >= 20, tens % 10 == 0 else { return nil }
        let hasAnd = words[1] == "et"
        let rest = Array(words.dropFirst(hasAnd ? 2 : 1))
        guard let tail = belowHundred(rest), (1...(tens == 60 ? 19 : 9)).contains(tail),
              !hasAnd || tail == 1 || (tens == 60 && tail == 11) else { return nil }
        return tens + tail
    }
}
