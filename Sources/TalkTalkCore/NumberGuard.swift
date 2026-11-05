import Foundation

/// NumberGuard (ARCHITECTURE.md §5.4): a self-written Chinese numeral parser (no dependency)
/// normalises the numbers in the source into a multiset of values (三十万 → 300000,
/// 百分之二十 → 20 %, 两千零五 → 2005, 1.5 亿 → 150000000) and compares it with the numbers in
/// the translation (digits, and en/de number words that can be read back). It also checks that
/// glossary entries found in the source appear in their target form.
///
/// Deliberately ignored, on both sides, because they are usually not numbers in meaning:
/// a bare 一 / "one" / "ein(e)" (articles, 一下, 一起 …), fixed words such as 一些、统一、十分、
/// 千万、万一, and weekdays (周三, 星期三). Months are numbers (十二月 = December = 12).
public enum NumberGuard {
    public enum Kind: String, Sendable, Equatable { case cardinal, ordinal, percent, month }

    public struct Mention: Sendable, Equatable {
        public var value: Double
        public var kind: Kind
        public var text: String
    }

    public struct Check: Sendable, Equatable {
        public var source: [Mention]
        public var target: [Mention]
        /// Source values missing from the target, and target values not in the source.
        public var missing: [Double]
        public var extra: [Double]
        /// Glossary entries present in the source whose target form is missing.
        public var missingTerms: [String]

        public var numbersMatch: Bool { missing.isEmpty && extra.isEmpty }
        public var isOK: Bool { numbersMatch && missingTerms.isEmpty }
        /// Both sides have numbers and the values differ.
        public var hardMismatch: Bool { !source.isEmpty && !target.isEmpty && !numbersMatch }
        /// For the HUD (“数字可能有误：三十万”).
        public var sourceTexts: [String] { source.map(\.text) }
    }

    public static func check(source: String, target: String, targetLang: Lang,
                             glossary: [GlossaryEntry] = []) -> Check {
        let s = sourceMentions(in: source)
        let t = TargetNumerals.mentions(in: target, lang: targetLang)
        var remaining = t.map(\.value)
        var missing: [Double] = []
        for m in s {
            if let i = remaining.firstIndex(where: { same($0, m.value) }) { remaining.remove(at: i) }
            else { missing.append(m.value) }
        }
        let lowered = target.lowercased()
        let terms = glossary.filter { !$0.zh.isEmpty && source.contains($0.zh) }
            .map { $0.rendering(for: targetLang) }
            .filter { !$0.isEmpty && !lowered.contains($0.lowercased()) }
        return Check(source: s, target: t, missing: missing, extra: remaining, missingTerms: terms)
    }

    /// Chinese/Arabic numerals keep their existing unit rules. English number words in a
    /// mixed utterance use the same reader as English targets, without counting Arabic digits
    /// twice (for example 20万 must remain 200000, not also 20). Han/digit/punctuation boundaries
    /// separate runs so adjacent "two个、twenty台" cannot become one English number phrase.
    public static func sourceMentions(in text: String) -> [Mention] {
        var mentions = ChineseNumerals.mentions(in: text)
        var english = ""
        func flush() {
            if !english.isEmpty { mentions += TargetNumerals.mentions(in: english, lang: .en) }
            english = ""
        }
        for character in text {
            if character.unicodeScalars.allSatisfy(TextScript.isLatinLetter) || character.isWhitespace
                || character == "-" || character == "'" || character == "’" {
                english.append(character)
            } else { flush() }
        }
        flush()
        return mentions
    }

    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(1e-9, abs(a) * 1e-9) }

    public enum Backend: Sendable { case openAI, apple }

    public enum Action: Sendable, Equatable {
        case pass
        /// Retry once with strictTerms (OpenAI path; double-sent, guardRetry deadline).
        case retry
        /// Play anyway, HUD yellow “数字可能有误”.
        case playWithWarning
        /// Apple path: do not speak; HUD shows source and translation.
        case block
    }

    /// §5.4: OpenAI retries once only when masked by ≥1.5 s of preceding audio or on a hard
    /// numeric mismatch; otherwise (or after the retry) play with a warning. Apple blocks.
    public static func action(_ c: Check, backend: Backend, maskedMs: Int, alreadyRetried: Bool,
                              policy: HedgePolicy) -> Action {
        guard !c.isOK else { return .pass }
        switch backend {
        case .apple: return .block
        case .openAI:
            if !alreadyRetried, policy.shouldRetryNumberGuard(maskedMs: maskedMs, hardMismatch: c.hardMismatch) { return .retry }
            return .playWithWarning
        }
    }
}

// MARK: - Chinese side

public enum ChineseNumerals {
    static let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "俩": 2, "三": 3, "四": 4,
                                           "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    static let bigUnits: [Character: Double] = ["万": 1e4, "亿": 1e8]

    /// Words whose numeral characters are not numbers.
    static let nonNumberWords = [
        "一下", "一些", "一起", "一直", "一样", "一定", "一切", "一般", "一边", "一旦", "一致", "一共", "一会", "一向",
        "一再", "一同", "一律", "一贯", "一味", "一番", "一流", "一方面", "一点儿", "统一", "唯一", "万一", "同一",
        "单一", "不一", "之一", "十分", "万分", "千万", "一模一样", "三心二意", "五花八门", "乱七八糟", "七上八下",
        "四面八方", "一五一十", "十全十美", "一会儿", "一面", "一时", "一阵",
    ]
    static let weekdayPrefixes = ["周", "星期", "礼拜"]

    static func isNumeralChar(_ c: Character) -> Bool {
        digits[c] != nil || smallUnits[c] != nil || bigUnits[c] != nil
    }

    public static func mentions(in text: String) -> [NumberGuard.Mention] {
        let chars = Array(text)
        var masked = [Bool](repeating: false, count: chars.count)
        // Mask fixed words and weekdays.
        for w in nonNumberWords { mask(w, in: chars, &masked) }
        for p in weekdayPrefixes {
            for d in ["一", "二", "三", "四", "五", "六", "日", "天", "末"] { mask(p + d, in: chars, &masked) }
        }
        // 一点 not followed by a digit means "a bit".
        for i in chars.indices where chars[i] == "一" && i + 1 < chars.count && chars[i + 1] == "点" {
            let nextIsDigit = i + 2 < chars.count && (digits[chars[i + 2]] != nil || chars[i + 2].isASCIIDigit)
            if !nextIsDigit { masked[i] = true; masked[i + 1] = true }
        }

        var out: [NumberGuard.Mention] = []
        var i = 0
        while i < chars.count {
            if masked[i] { i += 1; continue }
            let start = i
            var percent = false
            if hasPrefix(chars, i, "百分之") {
                let j = i + 3
                if j < chars.count, !masked[j], isNumeralChar(chars[j]) || chars[j].isASCIIDigit {
                    percent = true
                    i = j
                }
            }
            if chars[i].isASCIIDigit {
                var j = i
                while j < chars.count, chars[j].isASCIIDigit || ((chars[j] == "." || chars[j] == ",")
                        && j + 1 < chars.count && chars[j + 1].isASCIIDigit) { j += 1 }
                guard var v = parseArabic(String(chars[i..<j])) else { i = j; continue }
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                if k < chars.count, let u = bigUnits[chars[k]] { v *= u; k += 1 }
                else if k < chars.count, let u = smallUnits[chars[k]], k == j { v *= Double(u); k += 1 }
                else { k = j }
                var kind: NumberGuard.Kind = percent ? .percent : .cardinal
                if k < chars.count, chars[k] == "%" || chars[k] == "％" { kind = .percent; k += 1 }
                else if k < chars.count, chars[k] == "月" { kind = .month }
                if start > 0, chars[start - 1] == "第" { kind = .ordinal }
                out.append(.init(value: v, kind: kind, text: String(chars[(percent ? start : i)..<k])))
                i = k
                continue
            }
            if isNumeralChar(chars[i]) {
                var j = i
                while j < chars.count, !masked[j], isNumeralChar(chars[j]) || (chars[j] == "点" && j + 1 < chars.count
                        && digits[chars[j + 1]] != nil && j > i) { j += 1 }
                let run = String(chars[i..<j])
                let ordinal = start > 0 && chars[start - 1] == "第"
                let month = j < chars.count && chars[j] == "月"
                if let v = parseChinese(run) {
                    // A bare 一 / 两… alone: only 一 is dropped (article-like); 两周 stays 2.
                    let bareOne = run == "一" && !ordinal && !percent && !month
                    if !bareOne {
                        let kind: NumberGuard.Kind = percent ? .percent : ordinal ? .ordinal : month ? .month : .cardinal
                        out.append(.init(value: v, kind: kind, text: String(chars[start..<j])))
                    }
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    /// "300,000" → 300000; "1.5" → 1.5; "1,5" (decimal comma) → 1.5.
    static func parseArabic(_ s: String) -> Double? {
        let groups = s.split(whereSeparator: { $0 == "," || $0 == "." }).map(String.init)
        if groups.count > 1, groups.dropFirst().allSatisfy({ $0.count == 3 }), s.contains(",") && !s.contains(".") {
            return Double(groups.joined())
        }
        return Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// 三十万 → 300000, 两千零五 → 2005, 十二 → 12, 一百五 → 150, 二〇二六 → 2026, 三点五亿 → 3.5e8.
    public static func parseChinese(_ run: String) -> Double? {
        guard !run.isEmpty else { return nil }
        if let dot = run.firstIndex(of: "点") {
            let intPart = String(run[..<dot])
            var frac = String(run[run.index(after: dot)...])
            var scale = 1.0
            if let last = frac.last, let u = bigUnits[last] { scale = u; frac.removeLast() }
            guard let iv = intPart.isEmpty ? 0 : parseChinese(intPart) else { return nil }
            let fd = frac.compactMap { digits[$0] }
            guard fd.count == frac.count, !fd.isEmpty else { return nil }
            let fv = Double(fd.map(String.init).joined()).map { $0 / pow(10, Double(fd.count)) } ?? 0
            return (iv + fv) * scale
        }
        let cs = Array(run)
        if cs.allSatisfy({ digits[$0] != nil }) {
            if cs.count == 1 { return Double(digits[cs[0]]!) }
            // Digit-by-digit (years, codes): 二〇二六 → 2026.
            return Double(cs.map { String(digits[$0]!) }.joined())
        }
        var total = 0.0, section = 0.0, number = 0.0
        var lastUnit = 0.0
        var zeroBeforeLast = false
        var lastWasDigit = false
        for c in cs {
            if let d = digits[c] {
                if d == 0 { zeroBeforeLast = true; number = 0 } else { number = Double(d) }
                lastWasDigit = d != 0
            } else if let u = smallUnits[c] {
                if number == 0 && !lastWasDigit { number = 1 }      // leading 十 → 10
                section += number * Double(u)
                number = 0; lastUnit = Double(u); lastWasDigit = false; zeroBeforeLast = false
            } else if let u = bigUnits[c] {
                section += number
                if u == 1e8 { total = (total + section) * u } else { total += section * u }
                section = 0; number = 0; lastUnit = u; lastWasDigit = false; zeroBeforeLast = false
            } else {
                return nil
            }
        }
        if lastWasDigit, number > 0, lastUnit >= 100, !zeroBeforeLast {
            number *= lastUnit / 10                                   // 一百五 → 150, 三万五 → 35000
        }
        return total + section + number
    }

    /// Fixed words that are real numbers after another numeral: 三千万, 三万一, 九十分.
    static let onlyWithoutNumeralBefore: Set<String> = ["千万", "万一", "十分", "万分"]

    static func mask(_ word: String, in chars: [Character], _ masked: inout [Bool]) {
        let w = Array(word)
        guard w.count <= chars.count else { return }
        var i = 0
        while i + w.count <= chars.count {
            if Array(chars[i..<(i + w.count)]) == w,
               !(onlyWithoutNumeralBefore.contains(word) && i > 0 && (isNumeralChar(chars[i - 1]) || chars[i - 1].isASCIIDigit)) {
                // 第一 keeps its 一 (ordinal); 之一 / 一共 etc. are masked.
                for k in i..<(i + w.count) { masked[k] = true }
                i += w.count
            } else { i += 1 }
        }
    }

    static func hasPrefix(_ chars: [Character], _ i: Int, _ p: String) -> Bool {
        let pc = Array(p)
        return i + pc.count <= chars.count && Array(chars[i..<(i + pc.count)]) == pc
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - en / de side

public enum TargetNumerals {
    static let enUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let enOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
        "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1000,
    ]
    static let enScales: [String: Double] = ["hundred": 100, "thousand": 1e3, "million": 1e6, "billion": 1e9]
    static let deScales: [String: Double] = ["tausend": 1e3, "million": 1e6, "millionen": 1e6, "mio": 1e6,
                                             "milliarde": 1e9, "milliarden": 1e9, "mrd": 1e9]
    static let enMonths = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                           "october", "november", "december"]
    static let deMonths = ["januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september",
                           "oktober", "november", "dezember"]
    static let deOrdinalIrregular: [String: Int] = ["erst": 1, "dritt": 3, "siebt": 7, "acht": 8]
    static let percentWords: Set<String> = ["percent", "per", "prozent"]
    static let deNumeralMorphemes = ["null", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun",
                                     "zehn", "elf", "zwölf", "zwanzig", "ßig", "zig", "hundert", "tausend", "eins"]

    struct Token { var text: String; var isNumber: Bool }

    public static func mentions(in text: String, lang: Lang) -> [NumberGuard.Mention] {
        let tokens = tokenize(text)
        var out: [NumberGuard.Mention] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.isNumber {
                guard var v = parseDigits(t.text, lang: lang) else { i += 1; continue }
                var kind: NumberGuard.Kind = .cardinal
                var j = i + 1
                if j < tokens.count {
                    let next = tokens[j].text.lowercased()
                    if ["st", "nd", "rd", "th"].contains(next) { kind = .ordinal; j += 1 }
                }
                if j < tokens.count {
                    let next = tokens[j].text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if let s = (lang == .de ? deScales[next] : enScales[next]) ?? (next == "k" ? 1e3 : nil), s >= 1e3 {
                        v *= s; j += 1
                    }
                }
                if j < tokens.count {
                    let next = tokens[j].text.lowercased()
                    if next == "%" || percentWords.contains(next) { kind = .percent; j += 1 }
                }
                out.append(.init(value: v, kind: kind, text: tokens[i..<j].map(\.text).joined(separator: " ")))
                i = j
                continue
            }
            let w = t.text.lowercased()
            if let m = (lang == .de ? deMonths : enMonths).firstIndex(of: w) {
                out.append(.init(value: Double(m + 1), kind: .month, text: t.text))
                i += 1
                continue
            }
            if let (v, kind, used) = (lang == .de ? parseGermanWords(tokens, i) : parseEnglishWords(tokens, i)) {
                // Bare "one" / "ein(e)" is article-like: ignored (see NumberGuard docs).
                if !(v == 1 && kind == .cardinal && used == 1) {
                    out.append(.init(value: v, kind: kind, text: tokens[i..<(i + used)].map(\.text).joined(separator: " ")))
                }
                i += used
                continue
            }
            i += 1
        }
        return out
    }

    /// Words, digit groups (with internal , . '), and single symbols (% € $).
    static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        var cur = ""
        var curIsNum = false
        func flush() { if !cur.isEmpty { out.append(Token(text: cur, isNumber: curIsNum)); cur = "" } }
        let cs = Array(s)
        for (k, c) in cs.enumerated() {
            if c.isASCIIDigit {
                if !curIsNum { flush(); curIsNum = true }
                cur.append(c)
            } else if (c == "," || c == "." || c == "'"), curIsNum, k + 1 < cs.count, cs[k + 1].isASCIIDigit {
                cur.append(c)
            } else if c.isLetter {
                if curIsNum { flush(); curIsNum = false }
                cur.append(c)
            } else if c == "-", !curIsNum, !cur.isEmpty, k + 1 < cs.count, cs[k + 1].isLetter {
                cur.append(c)
            } else {
                flush(); curIsNum = false
                if c == "%" || c == "％" { out.append(Token(text: "%", isNumber: false)) }
            }
        }
        flush()
        return out
    }

    /// en: 300,000 / 1.5; de: 300.000 / 1,5. A group of exactly three digits after the
    /// separator is a thousands group; anything else is a decimal part.
    static func parseDigits(_ s: String, lang: Lang) -> Double? {
        let thousands: Character = lang == .de ? "." : ","
        let decimal: Character = lang == .de ? "," : "."
        var t = s.replacingOccurrences(of: "'", with: "")
        let parts = t.split(separator: thousands, omittingEmptySubsequences: false)
        if parts.count > 1, parts.dropFirst().allSatisfy({ $0.prefix(while: \.isASCIIDigit).count == 3 }) {
            t = parts.joined()
        } else if parts.count > 1 {
            t = t.replacingOccurrences(of: String(thousands), with: ".")   // foreign decimal style
        }
        t = t.replacingOccurrences(of: String(decimal), with: ".")
        return Double(t)
    }

    static func parseEnglishWords(_ tokens: [Token], _ start: Int) -> (Double, NumberGuard.Kind, Int)? {
        var total = 0.0, current = 0.0
        var used = 0, any = false, kind = NumberGuard.Kind.cardinal
        var i = start
        while i < tokens.count, !tokens[i].isNumber {
            let raw = tokens[i].text.lowercased()
            if raw == "and", any, i + 1 < tokens.count, isEnglishNumberWord(tokens[i + 1].text.lowercased()) { i += 1; continue }
            if raw == "a", !any, i + 1 < tokens.count, let s = enScales[tokens[i + 1].text.lowercased()] {
                current = s; any = true; i += 2; used = i - start; continue
            }
            var matched = false
            for part in raw.split(separator: "-").map(String.init) {
                if let u = enUnits[part] { current += Double(u); matched = true }
                else if let o = enOrdinals[part] {
                    if o >= 100 { current = max(current, 1) * Double(o) } else { current += Double(o) }
                    kind = .ordinal; matched = true
                } else if let s = enScales[part], any || matched {
                    if s == 100 { current = max(current, 1) * 100 } else { total += max(current, 1) * s; current = 0 }
                    matched = true
                } else { matched = false; break }
            }
            guard matched else { break }
            any = true
            i += 1
            used = i - start
            if kind == .ordinal { break }
        }
        guard any, used > 0 else { return nil }
        return (total + current, kind, used)
    }

    static func isEnglishNumberWord(_ w: String) -> Bool {
        w.split(separator: "-").allSatisfy { enUnits[String($0)] != nil || enOrdinals[String($0)] != nil || enScales[String($0)] != nil }
    }

    static func parseGermanWords(_ tokens: [Token], _ start: Int) -> (Double, NumberGuard.Kind, Int)? {
        let w = tokens[start].text.lowercased()
        if ["ein", "eine", "einen", "einem", "einer", "eines"].contains(w) { return nil }
        var kind = NumberGuard.Kind.cardinal
        var value: Double?
        if let v = germanCardinal(w) { value = v }
        else if let (v, _) = germanOrdinal(w) { value = v; kind = .ordinal }
        guard var v = value else { return nil }
        var used = 1
        if start + 1 < tokens.count, let s = deScales[tokens[start + 1].text.lowercased()], s >= 1e6 {
            v *= s; used = 2
        }
        return (v, kind, used)
    }

    static func germanCardinal(_ w: String) -> Double? {
        guard deNumeralMorphemes.contains(where: { w.contains($0) }) else { return nil }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .spellOut
        f.isLenient = true            // strict parsing only accepts ICU's soft-hyphenated output
        return f.number(from: w)?.doubleValue
    }

    /// zwölften → 12, dritte → 3, achten → 8, zwanzigste → 20.
    static func germanOrdinal(_ w: String) -> (Double, Int)? {
        for suffix in ["sten", "ster", "stes", "stem", "ste"] where w.hasSuffix(suffix) {
            if let v = germanCardinal(String(w.dropLast(suffix.count))), v >= 20 { return (v, 0) }
        }
        for suffix in ["en", "er", "es", "em", "e"] where w.hasSuffix(suffix) {
            let stem = String(w.dropLast(suffix.count))          // zwölft, dritt, acht, siebt, erst
            if let v = deOrdinalIrregular[stem] { return (Double(v), 0) }
            if stem.hasSuffix("t"), let v = germanCardinal(String(stem.dropLast())), v < 20 { return (v, 0) }
        }
        return nil
    }
}
