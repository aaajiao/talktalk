import Foundation

/// Pre-TTS normalisation (ARCHITECTURE.md), Swift ICU only (no num2words):
/// - `NumberFormatter(.spellOut)` per en-US / de-DE for numbers, percentages, €/$/¥, common
///   units, years, decimals and English ordinals;
/// - terminal_stop: add a sentence-final mark when missing (a trailing clause mark becomes ".");
/// - the target language itself is always passed to TTS explicitly (not done here).
public enum TextNormalizer {
    public static func normalize(_ text: String, lang: Lang) -> String {
        terminalStop(spellOutNumbers(text, lang: lang), lang: lang)
    }

    // MARK: terminal_stop

    static let finalMarks: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let clauseMarks: Set<Character> = [",", ";", ":", "，", "；", "：", "-", "–", "—"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "»", "«", "）", "」", "』", "】", "》"]

    public static func terminalStop(_ text: String, lang: Lang = .en) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        var tail = ""
        while let last = t.last, closers.contains(last) { tail = String(last) + tail; t.removeLast() }
        while let last = t.last, clauseMarks.contains(last) || last == " " { t.removeLast() }
        guard let last = t.last else { return text }
        if !finalMarks.contains(last) { t.append(lang == .zh ? "。" : ".") }
        return t + tail
    }

    // MARK: numbers

    struct Words {
        let percent, currency: [String: (one: String, many: String)]
        let units: [String: (one: String, many: String)]
        let point: String
    }

    static let en = Words(
        percent: ["%": ("percent", "percent")],
        currency: ["€": ("euro", "euros"), "$": ("dollar", "dollars"), "¥": ("yuan", "yuan"), "£": ("pound", "pounds")],
        units: ["ms": ("millisecond", "milliseconds"), "km": ("kilometer", "kilometers"), "kg": ("kilogram", "kilograms"),
                "GB": ("gigabyte", "gigabytes"), "MB": ("megabyte", "megabytes"), "TB": ("terabyte", "terabytes"),
                "cm": ("centimeter", "centimeters"), "mm": ("millimeter", "millimeters"), "Hz": ("hertz", "hertz"),
                "kHz": ("kilohertz", "kilohertz")],
        point: "point")
    static let de = Words(
        percent: ["%": ("Prozent", "Prozent")],
        currency: ["€": ("Euro", "Euro"), "$": ("Dollar", "Dollar"), "¥": ("Yuan", "Yuan"), "£": ("Pfund", "Pfund")],
        units: ["ms": ("Millisekunde", "Millisekunden"), "km": ("Kilometer", "Kilometer"), "kg": ("Kilogramm", "Kilogramm"),
                "GB": ("Gigabyte", "Gigabyte"), "MB": ("Megabyte", "Megabyte"), "TB": ("Terabyte", "Terabyte"),
                "cm": ("Zentimeter", "Zentimeter"), "mm": ("Millimeter", "Millimeter"), "Hz": ("Hertz", "Hertz"),
                "kHz": ("Kilohertz", "Kilohertz")],
        point: "Komma")

    static let numberRegex = try! NSRegularExpression(pattern:
        #"(?:([€$¥£])\s?)?(\d+(?:[.,']\d+)*)(?:(st|nd|rd|th)\b)?(?:\s?(%|ms\b|km\b|kg\b|GB\b|MB\b|TB\b|cm\b|mm\b|kHz\b|Hz\b|€|\$|¥|£))?"#)

    public static func spellOutNumbers(_ text: String, lang: Lang) -> String {
        guard lang != .zh else { return text }
        let w = lang == .de ? de : en
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in numberRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: m.range(at: 2))
            guard let value = TargetNumerals.parseDigits(digits, lang: lang) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let pre = m.range(at: 1).location == NSNotFound ? nil : ns.substring(with: m.range(at: 1))
            let ordinal = m.range(at: 3).location != NSNotFound
            let post = m.range(at: 4).location == NSNotFound ? nil : ns.substring(with: m.range(at: 4))
            let isOne = value == 1
            var spoken: String
            if ordinal, lang == .en, value == value.rounded() {
                spoken = englishOrdinal(Int(value))
            } else if pre == nil, post == nil, value == value.rounded(), digits.count == 4, !digits.contains(where: { !$0.isNumber }),
                      (1100...2099).contains(Int(value)) {
                spoken = year(Int(value), lang: lang)
            } else {
                spoken = spellOut(value, lang: lang)
            }
            if let post {
                if let p = w.percent[post] { spoken += " " + p.many }
                else if let u = w.units[post] { spoken += " " + (isOne ? u.one : u.many) }
                else if let c = w.currency[post] { spoken += " " + (isOne ? c.one : c.many) }
            }
            if let pre, let c = w.currency[pre] { spoken += " " + (isOne ? c.one : c.many) }
            out += spoken
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func spellOut(_ v: Double, lang: Lang) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: lang == .de ? "de_DE" : "en_US")
        f.numberStyle = .spellOut
        // ICU puts soft hyphens (U+00AD) into German compounds; TTS must not see them.
        return (f.string(from: NSNumber(value: v)) ?? String(v)).replacingOccurrences(of: "\u{AD}", with: "")
    }

    /// en: 2026 → twenty twenty-six, 2005 → two thousand five, 1999 → nineteen ninety-nine.
    /// de: 1999 → neunzehnhundertneunundneunzig, 2026 → zweitausendsechsundzwanzig.
    static func year(_ y: Int, lang: Lang) -> String {
        let hi = y / 100, lo = y % 100
        if lang == .de {
            if y < 2000 { return spellOut(Double(hi), lang: .de) + "hundert" + (lo == 0 ? "" : spellOut(Double(lo), lang: .de)) }
            return spellOut(Double(y), lang: .de)
        }
        if (2000...2009).contains(y) { return spellOut(Double(y), lang: .en) }
        if lo == 0 { return spellOut(Double(hi), lang: .en) + " hundred" }
        if lo < 10 { return spellOut(Double(hi), lang: .en) + " oh " + spellOut(Double(lo), lang: .en) }
        return spellOut(Double(hi), lang: .en) + " " + spellOut(Double(lo), lang: .en)
    }

    /// 1 → first, 12 → twelfth, 21 → twenty-first, 30 → thirtieth.
    static func englishOrdinal(_ n: Int) -> String {
        let card = spellOut(Double(n), lang: .en)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        var parts = card.components(separatedBy: CharacterSet(charactersIn: " -"))
        let seps = card.filter { $0 == " " || $0 == "-" }.map(String.init)
        guard var lastWord = parts.popLast() else { return card }
        if let r = irregular[lastWord] { lastWord = r }
        else if lastWord.hasSuffix("y") { lastWord = String(lastWord.dropLast()) + "ieth" }
        else { lastWord += "th" }
        var s = ""
        for (i, p) in parts.enumerated() { s += p + seps[i] }
        return s + lastWord
    }
}
