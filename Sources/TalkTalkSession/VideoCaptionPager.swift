/// Video caption paging (redesign §6 分页). Pure: the view supplies each character's advance
/// width, so tests can use fixed widths. Ranges are character (grapheme) offsets.
///
/// - A page has at most `maxLines` lines that each fit `lineWidth`.
/// - Where text remains, the page break moves back to the last "，。；？！、" / ", ; . ?"
///   within half a line.
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
            return end > start && VideoCaptionPager.preferredBreaks.contains(text[end - 1])
        }

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

/// Video reading time (§6 分页): about 18 source characters or 9 Chinese characters per
/// second, whichever is longer, within 1–6 s. With pending cues each page gets 0.7 of its
/// time (at least 1 s) to catch up before older pending cues are dropped.
public enum VideoCaptionPacing {
    public static let catchUpFactor = 0.7
    public static let minimumSeconds = 1.0
    public static let maximumSeconds = 6.0

    public static func readingTime(sourceCharacters: Int, translationCharacters: Int) -> Double {
        min(maximumSeconds, max(minimumSeconds, max(Double(sourceCharacters) / 18, Double(translationCharacters) / 9)))
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
}
