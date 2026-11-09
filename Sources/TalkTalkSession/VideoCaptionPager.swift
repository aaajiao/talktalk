import TalkTalkCore

/// Video caption paging (redesign §6 分页). Pure: the view supplies each character's advance
/// width, so tests can use fixed widths. Ranges are character (grapheme) offsets.
///
/// - A page has at most `maxLines` lines that each fit `lineWidth`.
/// - Where text remains, the page break moves back to the last "，。；？！、" / ", ; . ?", or a
///   space between two Chinese characters, within half a line.
/// - Two-line pages break where the two lines are most nearly equal; the second line never
///   holds only one or two characters or a lone punctuation mark when another break fits.
/// - Latin words and numbers are not split unless a single word is wider than a line; no line
///   starts with closing punctuation.
public enum VideoCaptionPager {
    public struct Page: Sendable, Equatable {
        /// Line ranges without leading or trailing spaces, in reading order.
        public var lines: [Range<Int>]
        public init(lines: [Range<Int>]) { self.lines = lines }
        public var range: Range<Int> { (lines.first?.lowerBound ?? 0)..<(lines.last?.upperBound ?? 0) }
    }

    static let preferredBreaks: Set<Character> = ["，", "。", "；", "？", "！", "、", ",", ";", ".", "?"]
    static let closing: Set<Character> = ["，", "。", "；", "？", "！", "、", "：", "）", "」", "』", "”", "’", "》", "…",
                                          ",", ".", ";", "?", "!", ":", ")", "]", "}", "%", "›"]
    static let opening: Set<Character> = ["（", "「", "『", "“", "‘", "《", "(", "[", "{"]
    private static let clauseMarks: Set<Character> = ["，", "。"]
    /// Marks a removed comma or period leaves no gap before. Unlike `closing`, this leaves out
    /// marks that can begin a token, as in ".NET".
    private static let noGapBefore = closing.subtracting([".", ":", "%"]).union(["】", "〉", "］"])
    private static let curlyQuotes: Set<Character> = ["“", "”", "‘", "’"]

    /// The translation line of a video caption follows Chinese subtitle style: "，" and "。" are
    /// shown as one space, and as nothing at either end or before closing punctuation. Only
    /// full-width marks change, so "3,000" and "3.5" stay intact. For display only: the text
    /// that is translated, saved or announced keeps its punctuation.
    public static func withoutClauseMarks(_ text: String) -> String {
        guard text.contains(where: clauseMarks.contains) else { return text }
        var result = ""
        var gap = false
        for character in text {
            if clauseMarks.contains(character) {
                gap = true
                continue
            }
            if gap {
                if character.isWhitespace { continue }
                if let last = result.last, !last.isWhitespace, !noGapBefore.contains(character),
                   !closesStraightQuote(character, after: result) { result.append(" ") }
                gap = false
            }
            result.append(character)
        }
        return result
    }

    /// A straight quote closes when the same quote before it is still open.
    private static func closesStraightQuote(_ character: Character, after text: String) -> Bool {
        (character == "\"" || character == "'") && text.filter { $0 == character }.count % 2 == 1
    }

    public static func paginate(_ text: [Character], advances: [Double], lineWidth: Double,
                                maxLines: Int = 2) -> [Page] {
        let layout = Layout(text: text, advances: advances, lineWidth: lineWidth)
        return layout.paginate(maxLines: max(1, maxLines))
    }

    public static func paginate(_ text: String, advances: [Double], lineWidth: Double, maxLines: Int = 2) -> [Page] {
        paginate(Array(text), advances: advances, lineWidth: lineWidth, maxLines: maxLines)
    }

    private struct Layout {
        let text: [Character]
        let prefix: [Double]
        let width: Double

        init(text: [Character], advances: [Double], lineWidth: Double) {
            self.text = text
            var sums = [0.0]
            sums.reserveCapacity(text.count + 1)
            for index in text.indices {
                let advance = index < advances.count && advances[index].isFinite ? max(0, advances[index]) : 0
                sums.append(sums[index] + advance)
            }
            prefix = sums
            width = lineWidth.isFinite ? max(0, lineWidth) : 0
        }

        var count: Int { text.count }

        func isSpace(_ index: Int) -> Bool { text[index].isWhitespace }

        func skipSpaces(_ index: Int) -> Int {
            var i = index
            while i < count, isSpace(i) { i += 1 }
            return i
        }

        func trimEnd(_ start: Int, _ end: Int) -> Int {
            var e = end
            while e > start, isSpace(e - 1) { e -= 1 }
            return e
        }

        /// Visible width of a line: trailing spaces do not count.
        func lineWidth(_ start: Int, _ end: Int) -> Double {
            let e = trimEnd(start, end)
            return prefix[e] - prefix[start]
        }

        func visibleCount(_ start: Int, _ end: Int) -> Int {
            (start..<end).filter { !isSpace($0) }.count
        }

        func isWide(_ c: Character) -> Bool {
            guard let scalar = c.unicodeScalars.first else { return false }
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0x303F, 0x3040...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF,
                 0x20000...0x3FFFF: return true
            default: return false
            }
        }

        /// A line may end before `index` (0 < index < count).
        func canBreak(before index: Int) -> Bool {
            guard index > 0, index < count else { return index == count }
            let previous = text[index - 1], next = text[index]
            if next.isWhitespace { return false }
            if VideoCaptionPager.closing.contains(next) { return false }
            if VideoCaptionPager.opening.contains(previous) { return false }
            if previous.isWhitespace { return true }
            if isWide(previous) || isWide(next) { return true }
            return previous == "-" || previous == "–" || previous == "/"
        }

        func isPreferred(break index: Int, after start: Int) -> Bool {
            let end = trimEnd(start, index)
            guard end > start else { return false }
            if VideoCaptionPager.preferredBreaks.contains(text[end - 1]) { return true }
            // A space between Chinese text stands in for a comma or period.
            return end < index && index < count && isChineseSide(text[end - 1]) && isChineseSide(text[index])
        }

        func isChineseSide(_ c: Character) -> Bool { isWide(c) || VideoCaptionPager.curlyQuotes.contains(c) }

        /// The longest line from `start` that fits; a word wider than the line is cut.
        func fitLine(from start: Int) -> Int {
            if lineWidth(start, count) <= width + 0.001 { return count }
            var best: Int?
            var index = start + 1
            while index < count, lineWidth(start, index) <= width + 0.001 {
                if canBreak(before: index) { best = index }
                index += 1
            }
            if let best { return best }
            // No break opportunity fits: cut inside the word, at least one character.
            var cut = start + 1
            while cut < count, lineWidth(start, cut + 1) <= width + 0.001 { cut += 1 }
            return cut
        }

        func paginate(maxLines: Int) -> [Page] {
            var pages: [Page] = []
            var start = skipSpaces(0)
            while start < count {
                var cursor = start
                var end = start
                for _ in 0..<maxLines where cursor < count {
                    end = fitLine(from: cursor)
                    cursor = skipSpaces(end)
                }
                if cursor < count { end = adjustedPageEnd(start: start, end: end) }
                let lines = lines(start, trimEnd(start, end), maxLines: maxLines)
                pages.append(Page(lines: lines))
                let next = skipSpaces(end)
                // Defensive: always make progress.
                start = next > start ? next : start + 1
            }
            return pages
        }

        /// Prefer punctuation within half a line back; never leave only one or two characters
        /// (or only punctuation) for the next page when an earlier break exists.
        func adjustedPageEnd(start: Int, end: Int) -> Int {
            var result = end
            let visibleEnd = trimEnd(start, end)
            if !isPreferred(break: end, after: start) {
                var index = end - 1
                while index > start, prefix[visibleEnd] - prefix[index] <= width / 2 + 0.001 {
                    if canBreak(before: index), isPreferred(break: index, after: start) { result = index; break }
                    index -= 1
                }
            }
            if tinyRemainder(from: skipSpaces(result)) {
                var candidate = result - 1
                while candidate > start {
                    if canBreak(before: candidate), !tinyRemainder(from: skipSpaces(candidate)) { return candidate }
                    candidate -= 1
                }
            }
            return result
        }

        func tinyRemainder(from index: Int) -> Bool {
            guard index < count else { return false }
            let visible = (index..<count).filter { !isSpace($0) }
            if visible.count <= 2 { return true }
            return visible.allSatisfy { VideoCaptionPager.closing.contains(text[$0]) }
        }

        /// Balanced lines for one page.
        func lines(_ start: Int, _ end: Int, maxLines: Int) -> [Range<Int>] {
            guard end > start else { return [start..<start] }
            if maxLines == 1 || lineWidth(start, end) <= width + 0.001 { return [start..<end] }
            guard maxLines == 2 else { return greedyLines(start, end, maxLines: maxLines) }
            var best: (index: Int, score: Double)?
            var bestPunctuation: (index: Int, score: Double)?
            for index in (start + 1)..<end where canBreak(before: index) {
                let first = lineWidth(start, index)
                let secondStart = skipSpaces(index)
                guard first <= width + 0.001, secondStart < end, lineWidth(secondStart, end) <= width + 0.001 else { continue }
                if shortSecondLine(secondStart, end) { continue }
                let score = abs(first - lineWidth(secondStart, end))
                if best == nil || score < best!.score { best = (index, score) }
                if isPreferred(break: index, after: start), bestPunctuation == nil || score < bestPunctuation!.score {
                    bestPunctuation = (index, score)
                }
            }
            // A punctuation break wins when it is almost as balanced (within 15% of a line).
            if let punctuation = bestPunctuation, let balanced = best, punctuation.score <= balanced.score + 0.15 * width {
                best = punctuation
            }
            guard let split = best?.index else { return greedyLines(start, end, maxLines: maxLines) }
            return [start..<trimEnd(start, split), skipSpaces(split)..<end]
        }

        func shortSecondLine(_ start: Int, _ end: Int) -> Bool {
            let visible = (start..<end).filter { !isSpace($0) }
            return visible.count <= 2 || visible.allSatisfy { VideoCaptionPager.closing.contains(text[$0]) }
        }

        func greedyLines(_ start: Int, _ end: Int, maxLines: Int) -> [Range<Int>] {
            var result: [Range<Int>] = []
            var cursor = start
            while cursor < end {
                var lineEnd = min(end, fitLine(from: cursor))
                if result.count == maxLines - 1 { lineEnd = end }
                result.append(cursor..<trimEnd(cursor, lineEnd))
                cursor = skipSpaces(lineEnd)
            }
            return result
        }
    }
}

/// Video reading time (§6 分页): 9 Chinese or 18 English/German characters per second
/// on either side, whichever needs longer, within 1–6 s. With pending cues each page gets 0.7 of its
/// time (at least 1 s) to catch up before older pending cues are dropped.
public enum VideoCaptionPacing {
    public static let catchUpFactor = 0.7
    public static let minimumSeconds = 1.0
    public static let maximumSeconds = 6.0

    public static func charactersPerSecond(_ language: Lang) -> Double { language == .zh ? 9 : 18 }

    public static func readingTime(sourceCharacters: Int, translationCharacters: Int,
                                   sourceLanguage: Lang = .en, targetLanguage: Lang = .zh) -> Double {
        let sourceSeconds = Double(max(0, sourceCharacters)) / charactersPerSecond(sourceLanguage)
        let targetSeconds = Double(max(0, translationCharacters)) / charactersPerSecond(targetLanguage)
        return min(maximumSeconds, max(minimumSeconds, max(sourceSeconds, targetSeconds)))
    }

    /// The page budget actually waited; never longer than the normal budget.
    public static func effectiveDuration(_ seconds: Double, catchingUp: Bool) -> Double {
        guard catchingUp else { return seconds }
        return min(seconds, max(minimumSeconds, seconds * catchUpFactor))
    }

    /// Characters a draft shares with its previous version; the rest is the new tail (§6 草稿).
    public static func stablePrefixLength(previous: String, current: String) -> Int {
        zip(previous, current).prefix(while: { $0 == $1 }).count
    }

    /// UTF-16 offsets of the non-space characters of `text` that a longest common subsequence
    /// with `seen` leaves unmatched. A shared prefix would charge everything after one early edit.
    public static func unreadOffsets(in text: String, seen: String) -> [Int] {
        let new = Array(text), old = Array(seen)
        let width = old.count + 1
        var longest = [Int](repeating: 0, count: (new.count + 1) * width)
        for i in new.indices.reversed() {
            for j in old.indices.reversed() {
                longest[i * width + j] = new[i] == old[j]
                    ? longest[(i + 1) * width + j + 1] + 1
                    : max(longest[(i + 1) * width + j], longest[i * width + j + 1])
            }
        }
        var unread: [Int] = []
        var offset = 0, j = 0
        for i in new.indices {
            while j < old.count, new[i] != old[j], longest[(i + 1) * width + j] < longest[i * width + j + 1] { j += 1 }
            if j < old.count, new[i] == old[j] {
                j += 1
            } else if !new[i].isWhitespace {
                unread.append(offset)
            }
            offset += new[i].utf16.count
        }
        return unread
    }
}

/// What a draft actually showed, page by page. A later draft can revise a page the viewer has
/// already left, and that unseen revision must not count as read.
public struct VideoDraftReading: Equatable, Sendable {
    private var sourcePages: [Int: String] = [:]
    private var translationPages: [Int: String] = [:]

    public init() {}

    public mutating func record(sourcePage: Int, source: String, translationPage: Int, translation: String) {
        sourcePages[sourcePage] = source
        translationPages[translationPage] = translation
    }

    public var source: String { Self.joined(sourcePages) }
    public var translation: String { Self.joined(translationPages) }

    private static func joined(_ pages: [Int: String]) -> String {
        pages.sorted { $0.key < $1.key }.map(\.value).joined()
    }
}

/// The reading clock of a final that replaces a draft already on screen (§6 分页). While another
/// cue waits, a page needs only the time to read what the draft did not show, at least 1 s.
public struct VideoCaptionFinalHold: Equatable, Sendable {
    /// A page is treated as rewritten, and read in full, once this share of it is unread.
    public static let rewrittenShare = 0.6

    public struct Page: Equatable, Sendable {
        public var text: String
        public var utf16Range: Range<Int>

        public init(text: String, utf16Range: Range<Int>) {
            self.text = text
            self.utf16Range = utf16Range
        }
    }

    private let unreadSource: [Int]
    private let unreadTranslation: [Int]
    private var pageStartedAt: Double
    private var keepsSource = false
    private var keepsTranslation = false

    /// `seenSource` and `seenTranslation`: what the draft actually showed (`VideoDraftReading`).
    public init(source: String, translation: String, seenSource: String, seenTranslation: String, at now: Double) {
        unreadSource = VideoCaptionPacing.unreadOffsets(in: source, seen: seenSource)
        unreadTranslation = VideoCaptionPacing.unreadOffsets(in: translation, seen: seenTranslation)
        pageStartedAt = now
    }

    /// A language that stays on its last page has nothing new to read on the next one.
    public mutating func flipPage(at now: Double, keepsSource: Bool, keepsTranslation: Bool) {
        pageStartedAt = now
        self.keepsSource = keepsSource
        self.keepsTranslation = keepsTranslation
    }

    public mutating func restart(at now: Double) { pageStartedAt = now }

    public func readyTime(source: Page?, translation: Page?, sourceLanguage: Lang, targetLanguage: Lang) -> Double {
        pageStartedAt + VideoCaptionPacing.readingTime(
            sourceCharacters: keepsSource ? 0 : Self.charged(source, unread: unreadSource),
            translationCharacters: keepsTranslation ? 0 : Self.charged(translation, unread: unreadTranslation),
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private static func charged(_ page: Page?, unread: [Int]) -> Int {
        guard let page else { return 0 }
        let letters = page.text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
        let count = unread.reduce(0) { page.utf16Range.contains($1) ? $0 + 1 : $0 }
        guard letters > 0, Double(count) / Double(letters) >= rewrittenShare else { return count }
        return page.text.count
    }
}

/// The draft's dimmed tail (§6 草稿) is measured when the draft text actually changes. A
/// re-render of the same draft (the 500 ms preview tick, a layout pass) keeps that tail
/// instead of comparing the draft with itself.
public struct VideoDraftTail: Sendable, Equatable {
    private var sentence: UInt64?
    private var text = ""
    private var stable = 0

    public init() {}

    /// `previous`: the draft text of the same sentence that was on screen before this render.
    public mutating func stablePrefix(sentence: UInt64, text: String, previous: String?) -> Int {
        if self.sentence == sentence, self.text == text { return stable }
        stable = previous.map { VideoCaptionPacing.stablePrefixLength(previous: $0, current: text) } ?? 0
        self.sentence = sentence
        self.text = text
        return stable
    }

    public mutating func reset() { self = .init() }
}
