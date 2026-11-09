import Foundation

/// Finds sentence ends inside an audio window that is read again every few hundred ms.
///
/// The recognizer closes every reading with sentence punctuation, so a period at the end of a
/// reading says nothing. A period inside a reading, still there in the next one and followed by
/// more speech, does. Such a sentence is released at once while the audio window stays as it is,
/// because the model gives no timestamps to cut it with. Later readings of the same window repeat
/// the released text from its start, and this type removes it. Pure and clock-free.
public struct RollingSentenceCommitter: Sendable {
    public struct Reading: Sendable, Equatable {
        public var sentence: String?
        /// What is left of the reading once `sentence` and everything released earlier is removed.
        public var remainder: String
    }

    public struct Closing: Sendable, Equatable {
        public var sentences: [String]
        public var tail: String
    }

    private struct Token: Sendable {
        var surface: Substring
        var key: String
    }

    private static let enders: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
    private static let closers: Set<Character> = ["\"", "'", ")", "”", "’", "）", "」", "』", "】", "》"]
    private static let pauses: Set<Character> = [",", ";", ":", "，", "；", "：", "、"]
    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "st", "vs", "jr", "sr",   // en
        "hr", "fr", "nr", "bzw", "ca", "ggf", "evtl", "vgl",       // de
    ]
    private static let requiredAgreement = 2

    public let lang: Lang
    private let unit: LCPCommitter.Unit
    private let tokensAfterEnd: Int
    private var released: [String] = []
    private var previous: [Token] = []
    private var agreement: [Int] = []
    private var continuesSentence = false
    /// What the current window has released, exactly as the recognizer wrote it. Later readings
    /// can continue from this text instead of working it out again. Empty until a release.
    public private(set) var releasedReading = ""

    public init(lang: Lang) {
        self.lang = lang
        unit = .for(lang)
        tokensAfterEnd = lang == .zh ? 6 : 3
    }

    /// True while later readings of this window will repeat text that was already released.
    public var hasReleased: Bool { !released.isEmpty }

    /// A new reading of the current window, from the window's start.
    public mutating func observe(_ reading: String) -> Reading {
        let all = tokens(reading)
        if all.isEmpty, released.isEmpty { continuesSentence = false }
        let fresh = Array(all[overlap(with: all)...])
        let agreed = agreements(fresh)
        let limit = confirmedLimit(fresh, agreed)
        if limit > 0, let found = (0..<limit).first(where: { endsSentence(fresh, at: $0) && hasWords(fresh[...$0]) }) {
            let end = throughTrailingMarks(fresh, from: found)
            let sentence = decapitalized(slice(reading, fresh[...end]))
            released += fresh[...end].filter { Self.hasWords($0.key) }.map(\.key)
            releasedReading = String(reading[..<fresh[end].surface.endIndex])
            previous = []
            agreement = []
            continuesSentence = false
            return Reading(sentence: sentence, remainder: slice(reading, fresh[(end + 1)...]))
        }
        previous = fresh
        agreement = agreed
        return Reading(sentence: nil, remainder: decapitalized(slice(reading, fresh[...])))
    }

    /// The window's last reading. `forced` means the cut was made by the window's length and not
    /// by the speaker, so a period at its end is not believed and the sentence goes on. Only a
    /// period the previous reading agreed on splits the text. A tail left after a split belongs
    /// to no request to close, so it goes on as well.
    public mutating func finish(_ text: String, forced: Bool) -> Closing {
        let all = tokens(text)
        let fresh = Array(all[overlap(with: all)...])
        var sentences: [String] = []
        var start = 0, index = 0
        let limit = confirmedLimit(fresh, agreements(fresh))
        while index < limit {
            guard endsSentence(fresh, at: index), hasWords(fresh[start...index]) else { index += 1; continue }
            let end = throughTrailingMarks(fresh, from: index)
            sentences.append(slice(text, fresh[start...end]))
            start = end + 1
            index = start
        }
        var tail = slice(text, fresh[start...])
        let continues = forced || !sentences.isEmpty
        if continues { tail = withoutSentenceEnd(tail) }
        if let first = sentences.first { sentences[0] = decapitalized(first) } else { tail = decapitalized(tail) }
        continuesSentence = continues && !tail.isEmpty
        windowMoved()
        return Closing(sentences: sentences, tail: tail)
    }

    /// Cuts one piece off a sentence too long for one subtitle, at a sentence end or else at a
    /// comma. One piece at a time, because the subtitle board holds only two waiting cues. Limits
    /// count words; Chinese counts characters, twice as many. Nil if the text stays whole.
    public func splitLong(_ text: String, fromWords limit: Int, minHeadWords: Int) -> (head: String, rest: String)? {
        let all = tokens(text)
        let scale = unit == .character ? 2 : 1
        let total = all.filter { Self.hasWords($0.key) }.count
        guard total >= limit * scale,
              let end = longCut(all, total: total, limit: limit * scale, minPiece: minHeadWords * scale),
              end + 1 < all.count else { return nil }
        return (slice(text, all[...end]), slice(text, all[(end + 1)...]))
    }

    /// Whether `text` has at least `limit` words, counted as `splitLong` counts them.
    public func isLong(_ text: String, fromWords limit: Int) -> Bool {
        tokens(text).filter { Self.hasWords($0.key) }.count >= limit * (unit == .character ? 2 : 1)
    }

    /// The audio went silent, so whatever comes next starts a new sentence.
    public mutating func speechStopped() { continuesSentence = false }

    /// The window now starts somewhere else, so its readings no longer repeat released text.
    public mutating func windowMoved() {
        released = []
        releasedReading = ""
        previous = []
        agreement = []
    }

    // MARK: - internals

    private func agreements(_ fresh: [Token]) -> [Int] {
        fresh.indices.map { index in
            // The last token of a reading does not count: every reading ends in a period.
            let same = index < previous.count - 1 && previous[index].key == fresh[index].key
                && previous[index].surface.last == fresh[index].surface.last
            return same ? agreement[index] + 1 : 1
        }
    }

    private func confirmedLimit(_ fresh: [Token], _ agreed: [Int]) -> Int {
        min(agreed.firstIndex { $0 < Self.requiredAgreement } ?? fresh.count, fresh.count - tokensAfterEnd)
    }

    private func tokens(_ text: String) -> [Token] {
        switch unit {
        case .word:
            return text.split(whereSeparator: \.isWhitespace).map { Token(surface: $0, key: LCPCommitter.key(String($0))) }
        case .character:
            return text.indices.filter { !text[$0].isWhitespace }.map {
                Token(surface: text[$0...$0], key: LCPCommitter.key(String(text[$0])))
            }
        }
    }

    /// The text of these tokens, without the period the recognizer left after an unfinished word.
    private func slice(_ text: String, _ tokens: ArraySlice<Token>) -> String {
        guard let first = tokens.first else { return "" }
        var out = ""
        var cursor = first.surface.startIndex
        var lowerNext = false
        for index in tokens.indices {
            let surface = tokens[index].surface
            out += text[cursor..<surface.startIndex]
            cursor = surface.endIndex
            if index < tokens.endIndex - 1, endsOnUnfinishedWord(tokens, at: index) {
                out += surface.dropLast()
                lowerNext = lang == .en
            } else {
                out += lowerNext ? Self.withLoweredHead(String(surface)) : String(surface)
                lowerNext = false
            }
        }
        return out
    }

    private func endsOnUnfinishedWord(_ tokens: ArraySlice<Token>, at index: Int) -> Bool {
        guard let mark = tokens[index].surface.last, mark == "." || mark == "。" else { return false }
        let context = tokens[max(tokens.startIndex, index - 3)...index].map(\.surface).joined(separator: unit == .word ? " " : "")
        return UnfinishedEnding.matches(context, lang: lang)
    }

    /// A sentence end is the better cut, unless it is so far off that the piece would be long again.
    private func longCut(_ all: [Token], total: Int, limit: Int, minPiece: Int) -> Int? {
        var words = 0
        var comma: Int?
        var earlierComma: Int?
        // Near the middle, so one cut takes enough out of a backlog that a long window refills.
        let middle = max(minPiece, min(limit, total / 2))
        for index in 0..<(all.count - 1) {
            if Self.hasWords(all[index].key) { words += 1 }
            if comma != nil || earlierComma != nil, words >= limit + minPiece { break }
            if words >= tokensAfterEnd, endsSentence(all, at: index) { return throughTrailingMarks(all, from: index) }
            guard comma == nil, words >= minPiece, total - words >= minPiece, isClauseMark(all[index]) else { continue }
            if words >= middle { comma = throughTrailingMarks(all, from: index) }
            else { earlierComma = throughTrailingMarks(all, from: index) }
        }
        return comma ?? earlierComma
    }

    /// Chinese is tokenized by character, where ASCII commas and "：" sit inside numbers.
    private func isClauseMark(_ token: Token) -> Bool {
        guard let mark = token.surface.last else { return false }
        return (unit == .character ? "，；" : ",;:").contains(mark)
    }

    /// How many leading tokens of this reading restate released text. Readings of one window can
    /// revise, drop or add a word, so this takes the prefix of the reading closest in edit distance
    /// to the released words. Punctuation is left out: it changes freely between readings.
    private func overlap(with all: [Token]) -> Int {
        guard !released.isEmpty else { return 0 }
        let words = all.indices.filter { Self.hasWords(all[$0].key) }
        var row = Array(0...words.count)
        for (line, word) in released.enumerated() {
            var diagonal = row[0]
            row[0] = line + 1
            for column in row.indices.dropFirst() {
                let cost = min(diagonal + (all[words[column - 1]].key == word ? 0 : 1), row[column] + 1, row[column - 1] + 1)
                diagonal = row[column]
                row[column] = cost
            }
        }
        let distances = row, target = released.count, lastWord = released[target - 1]
        // Released text ends a sentence, so among equally close prefixes one ending a sentence wins.
        func rank(_ prefix: Int) -> (Int, Int, Int, Int) {
            guard prefix > 0 else { return (distances[0], 1, 1, target) }
            let word = words[prefix - 1]
            let endsOnLastWord = all[word].key == lastWord
            let atSentenceEnd = marksAfter(all, word: word).endsSentence
                || (all[word].surface.last.map(Self.enders.contains) == true && !endsOnUnfinishedWord(all[...], at: word))
            return (distances[prefix], atSentenceEnd ? 0 : 1, endsOnLastWord ? 0 : 1, abs(prefix - target))
        }
        guard let best = distances.indices.min(by: { rank($0) < rank($1) }), best > 0,
              distances[best] < target else { return 0 }   // no released word aligned: not a restatement
        return marksAfter(all, word: words[best - 1]).next
    }

    /// Where new text starts after a word: past the punctuation trailing it, but not past an
    /// opening quote or a sign, which belong to what follows.
    private func marksAfter(_ all: [Token], word: Int) -> (next: Int, endsSentence: Bool) {
        var next = word + 1, endsSentence = false, scan = word + 1
        while scan < all.count, !Self.hasWords(all[scan].key) {
            if all[scan].surface.count == 1, let mark = all[scan].surface.first {
                if Self.enders.contains(mark) { endsSentence = true }
                if Self.enders.contains(mark) || Self.closers.contains(mark) || Self.pauses.contains(mark) { next = scan + 1 }
            }
            scan += 1
        }
        return (next, endsSentence)
    }

    private static func hasWords(_ key: String) -> Bool { key.contains { $0.isLetter || $0.isNumber } }
    private func hasWords(_ tokens: ArraySlice<Token>) -> Bool { tokens.contains { Self.hasWords($0.key) } }

    /// Punctuation right after a sentence end belongs to that sentence: `。”`, `？！`, `……`.
    private func throughTrailingMarks(_ tokens: [Token], from index: Int) -> Int {
        var end = index
        while end + 1 < tokens.count, tokens[end + 1].surface.count == 1, let character = tokens[end + 1].surface.first,
              Self.closers.contains(character) || Self.enders.contains(character) { end += 1 }
        return end
    }

    private func endsSentence(_ tokens: [Token], at index: Int) -> Bool {
        var body = tokens[index].surface
        while let last = body.last, Self.closers.contains(last) { body.removeLast() }
        guard let last = body.last, Self.enders.contains(last) else { return false }
        if endsOnUnfinishedWord(tokens[...], at: index) { return false }
        if unit == .character {
            // "3.5", "Node.js" and "Dr." inside Chinese speech. The sentence period here is "。".
            guard last == ".", index > 0, let before = tokens[index - 1].surface.last else { return true }
            return !(before.isASCII && (before.isLetter || before.isNumber))
        }
        if isAbbreviation(body) { return false }
        return index + 1 >= tokens.count || tokens[index + 1].surface.first?.isLowercase != true
    }

    private func isAbbreviation(_ word: Substring) -> Bool {
        guard unit == .word, word.last == "." else { return false }
        let bare = word.dropLast().lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !bare.isEmpty else { return false }
        if Self.abbreviations.contains(bare) { return true }
        // "am 3. Mai", "der 100. Geburtstag", "am 3.5."; a four-digit number is a year ending a sentence.
        if lang == .de, bare.allSatisfy({ $0.isNumber || $0 == "." }), bare.count != 4 || bare.contains(".") { return true }
        return bare.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
    }

    /// Unlike `endsSentence` this ignores abbreviations: any period left here would close the
    /// sentence, and a cut after "a" or "Dr" reads as an abbreviation.
    private func withoutSentenceEnd(_ tail: String) -> String {
        var body = Substring(tail)
        var closing = ""
        while let character = body.last, Self.closers.contains(character) {
            closing.insert(character, at: closing.startIndex)
            body.removeLast()
        }
        guard let last = body.last, Self.enders.contains(last) else { return tail }
        while let character = body.last, Self.enders.contains(character) { body.removeLast() }
        return String(body) + closing
    }

    /// The model capitalizes the first word of every window, even mid-sentence. German nouns are
    /// capitalized anyway, and acronyms or "I" must keep theirs.
    private func decapitalized(_ text: String) -> String {
        guard continuesSentence, released.isEmpty, lang == .en else { return text }
        return Self.withLoweredHead(text)
    }

    private static func withLoweredHead(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let head = text.prefix { !$0.isWhitespace }
        let letters = head.filter(\.isLetter)
        guard letters.dropFirst().allSatisfy(\.isLowercase),
              !(first == "I" && (head.count == 1 || head.dropFirst().first?.isLetter == false)) else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
