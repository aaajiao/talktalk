import TalkTalkCore

/// A bounded set of bilingual sentence pairs plus the open sentence's source/draft.
/// Each final carries its own source, so later volatile speech cannot change that pairing.
/// Pure presentation state; the panel renders it.
public struct SubtitleBoard: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var sentence: UInt64
        public var text: String
        public var source: String = ""
        public var approx: Bool
        public var numberWarning: Bool
        public init(sentence: UInt64, text: String, source: String = "", approx: Bool, numberWarning: Bool) {
            self.sentence = sentence; self.text = text; self.source = source
            self.approx = approx; self.numberWarning = numberWarning
        }
        /// Number-check results remain metadata and never append text to the subtitle. The
        /// Apple fallback is no longer a "≈" prefix: the view appends a "备用翻译" badge at the
        /// sentence end (redesign §4 三态), so the text itself stays unmodified.
        public var display: String { text }
        /// The final came from the Apple fallback; the view shows the "备用翻译" badge.
        public var showsFallbackBadge: Bool { approx }
    }

    public let finalLines: Int
    public let retention: SubtitleRetentionPolicy?
    public private(set) var source = ""
    public private(set) var finals: [Line] = []
    public private(set) var draft: Line?
    public private(set) var hint: String?
    private var newestFinal: UInt64 = 0
    private let maxCharactersPerSecond: Int
    private var nextDraftDisplayAt: HostTime = 0
    private var finalReadUntil: [UInt64: HostTime] = [:]
    private var pendingFinals: [Line] = []
    private var pendingDraft: Line?
    private var newestReceived: UInt64 = 0
    private var firstFinalAt: [UInt64: HostTime] = [:]
    private var retiredThrough: UInt64 = 0
    private static let pendingLimit = 2

    /// Pacing is opt-in for a rendering UI that calls advance every 100 ms. The oldest queued
    /// line rolls away on overflow instead of building an ever-later subtitle backlog.
    public init(finalLines: Int = 2, maxCharactersPerSecond: Int = 0,
                retention: SubtitleRetentionPolicy? = nil) {
        self.finalLines = max(1, finalLines)
        self.maxCharactersPerSecond = max(0, maxCharactersPerSecond)
        self.retention = retention
    }

    public var isEmpty: Bool { source.isEmpty && finals.isEmpty && draft == nil && hint == nil }
    /// Read-only observations for the explicitly enabled runtime subtitle analysis.
    public var pendingFinalSentenceIDs: [UInt64] { pendingFinals.map(\.sentence) }
    public var pendingDraftSentenceID: UInt64? { pendingDraft?.sentence }

    public mutating func setHint(_ h: String?) { hint = h }

    /// Returns true if anything visible changed.
    @discardableResult
    public mutating func apply(_ u: SubtitleUpdate, at now: HostTime = HostClock.now()) -> Bool {
        if maxCharactersPerSecond > 0 { return paced(u, at: now) }
        let before = self
        switch u {
        case let .source(t):
            // An empty line means "sentence closed": keep the last one up until speech resumes.
            if !t.isEmpty { source = t }
        case let .draft(s, t, source):
            guard s > newestFinal, !finals.contains(where: { $0.sentence == s }) else { break }
            if draft == nil || draft!.sentence <= s { draft = Line(sentence: s, text: t, source: source, approx: false, numberWarning: false) }
        case let .final(s, t, source, approx, warn):
            guard retention == nil || s > retiredThrough else { break }
            if firstFinalAt[s] == nil { firstFinalAt[s] = now }
            finals.removeAll { $0.sentence == s }
            finals.append(Line(sentence: s, text: t, source: source, approx: approx, numberWarning: warn))
            finals.sort { $0.sentence < $1.sentence }
            trimHistory()
            newestFinal = max(newestFinal, s)
            if let d = draft, d.sentence <= s { draft = nil }
        case let .dropped(s):
            if draft?.sentence == s { draft = nil }
        }
        return self != before
    }

    private mutating func paced(_ update: SubtitleUpdate, at now: HostTime) -> Bool {
        let oldSource = source, oldFinals = finals, oldDraft = draft
        switch update {
        case let .source(text): if !text.isEmpty { source = text }
        case let .draft(id, text, source):
            if id > newestReceived, id >= (pendingDraft?.sentence ?? draft?.sentence ?? 0) {
                pendingDraft = Line(sentence: id, text: text, source: source, approx: false, numberWarning: false)
            }
        case let .final(id, text, source, approx, warning):
            guard retention == nil || id > retiredThrough else { break }
            if firstFinalAt[id] == nil { firstFinalAt[id] = now }
            newestReceived = max(newestReceived, id)
            pendingFinals.removeAll { $0.sentence == id }
            pendingFinals.append(Line(sentence: id, text: text, source: source, approx: approx, numberWarning: warning))
            pendingFinals.sort { $0.sentence < $1.sentence }
            if pendingFinals.count > Self.pendingLimit { pendingFinals.removeFirst(pendingFinals.count - Self.pendingLimit) }
            trimReceiptTimes()
            if let pendingDraft, pendingDraft.sentence <= id { self.pendingDraft = nil }
            // Keep the visible draft until its replacement is actually displayed. It also
            // credits the unchanged prefix instead of charging the whole final a second time.
        case let .dropped(id):
            if pendingDraft?.sentence == id { pendingDraft = nil }
            if draft?.sentence == id { draft = nil }
        }
        _ = advance(at: now)
        return oldSource != source || oldFinals != finals || oldDraft != draft
    }

    /// Reading time belongs to the line that would leave the panel. A free slot or a revision
    /// can display immediately; replacing the oldest line waits only for that line's deadline.
    /// Draft updates have their own cadence and never delay finals. No animation.
    @discardableResult public mutating func advance(at now: HostTime = HostClock.now()) -> Bool {
        guard maxCharactersPerSecond > 0 else { return false }
        // An out-of-order final older than the retained window would immediately evict itself.
        while let waiting = pendingFinals.first, finals.count >= finalLines,
              let oldest = finals.first, waiting.sentence < oldest.sentence {
            pendingFinals.removeFirst()
        }
        if let line = pendingFinals.first {
            let existing = finals.first { $0.sentence == line.sentence }
            // Retained history is not extra instant-display capacity. Keep the existing
            // last-two-line reading cadence even when earlier pairs remain scrollable.
            let evictedDeadline = finals.suffix(finalLines).first.flatMap { finalReadUntil[$0.sentence] } ?? 0
            if existing != nil || finals.count < finalLines || now >= evictedDeadline {
                pendingFinals.removeFirst()
                let previous = existing?.text ?? (draft?.sentence == line.sentence ? draft!.text : "")
                let deadline = max(finalReadUntil[line.sentence] ?? 0,
                                   now + readingTime(for: line.text, replacing: previous))
                finals.removeAll { $0.sentence == line.sentence }
                finals.append(line); finals.sort { $0.sentence < $1.sentence }
                finalReadUntil[line.sentence] = deadline
                trimHistory()
                newestFinal = max(newestFinal, line.sentence)
                if let draft, draft.sentence <= line.sentence { self.draft = nil }
                return true
            }
        }
        if let line = pendingDraft, now >= nextDraftDisplayAt {
            pendingDraft = nil
            let previous = draft?.sentence == line.sentence ? draft!.text : ""
            draft = line
            nextDraftDisplayAt = now + readingTime(for: line.text, replacing: previous)
            return true
        }
        return false
    }

    private func readingTime(for text: String, replacing previous: String) -> HostTime {
        let prefix = zip(previous, text).prefix(while: { $0 == $1 }).count
        let changed = max(0, text.count - prefix)
        return UInt64(Double(changed) / Double(maxCharactersPerSecond) * 1_000_000_000)
    }

    private mutating func trimHistory() {
        let start: Int
        if let retention {
            start = retention.retainedStartIndex(in: finals.map {
                .init(at: firstFinalAt[$0.sentence] ?? 0, characters: $0.source.count + $0.text.count)
            })
        } else { start = max(0, finals.count - finalLines) }
        if start > 0 {
            for removed in finals.prefix(start) {
                finalReadUntil[removed.sentence] = nil
                if retention != nil { retiredThrough = max(retiredThrough, removed.sentence) }
            }
            finals.removeFirst(start)
        }
        trimReceiptTimes()
    }

    private mutating func trimReceiptTimes() {
        let live = Set(finals.map(\.sentence) + pendingFinals.map(\.sentence))
        firstFinalAt = firstFinalAt.filter { live.contains($0.key) }
    }

    public mutating func clear() {
        source = ""; finals = []; draft = nil; hint = nil; newestFinal = 0
        pendingFinals = []; pendingDraft = nil; newestReceived = 0
        nextDraftDisplayAt = 0; finalReadUntil = [:]
        firstFinalAt = [:]; retiredThrough = 0
    }
}
