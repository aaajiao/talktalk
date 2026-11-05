import Foundation

/// FIFO of committed, gated, normalized target-language clauses waiting for TTS (§5.5).
///
/// - Merge rule: the newest queued item has not started synthesis, the next clause arrives within
///   `mergeWindowMs` (300 ms) of it, both have fewer than `mergeMaxWords` (8) words and the same
///   language → one item. The merged item keeps the first clause's ID and lists the others in
///   `clauses`, so the caller moves all of them through ClauseLedger together.
/// - Each request: explicit language, `seed = hash(voice, text)`, `wholeClause` when the expected
///   duration is below `wholeClauseBelowExpectedS` (1.5 s, §3.3 short clauses).
///
/// Pure value type driven by explicit times (virtual clock in tests). BacklogController (M3)
/// reads `pendingExpectedS` and may `dropOldest` / `replaceAll` (summarize).
public struct TTSQueue: Sendable {
    public struct Config: Sendable, Equatable {
        public var mergeWindowMs: Int
        public var mergeMaxWords: Int
        public var wholeClauseBelowExpectedS: Double
        public init(mergeWindowMs: Int, mergeMaxWords: Int, wholeClauseBelowExpectedS: Double) {
            self.mergeWindowMs = mergeWindowMs; self.mergeMaxWords = mergeMaxWords
            self.wholeClauseBelowExpectedS = wholeClauseBelowExpectedS
        }
        public init(_ tts: PolicyProfile.Speak.TTS) {
            self.init(mergeWindowMs: tts.mergeWindowMs, mergeMaxWords: tts.mergeMaxWords,
                      wholeClauseBelowExpectedS: tts.wholeClauseBelowExpectedS)
        }
    }

    public struct Item: Sendable, Equatable {
        /// Ledger clause IDs carried by this item, in order; `clauses[0]` is the request's clause.
        public var clauses: [UInt64]
        public var text: String
        public var lang: Lang
        /// Arrival of the newest clause merged into this item (the merge window runs from here).
        public var lastArrival: HostTime
        public var clause: UInt64 { clauses[0] }
        public var words: Int { ExpectedDuration.words(text) }
        public var expectedS: Double { ExpectedDuration.seconds(text, lang) }
    }

    public let config: Config
    public private(set) var items: [Item] = []

    public init(config: Config) { self.config = config }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Expected duration of everything still waiting (unrendered part of the backlog Q, §5.5).
    public var pendingExpectedS: Double { items.reduce(0) { $0 + $1.expectedS } }

    /// Adds a clause. Returns true when it was merged into the newest waiting item.
    @discardableResult
    public mutating func enqueue(clause: UInt64, text: String, lang: Lang, at now: HostTime) -> Bool {
        if var last = items.last, last.lang == lang,
           now >= last.lastArrival, HostClock.ms(last.lastArrival, to: now) <= config.mergeWindowMs,
           last.words < config.mergeMaxWords, ExpectedDuration.words(text) < config.mergeMaxWords {
            last.clauses.append(clause)
            last.text = Self.join(last.text, text)
            last.lastArrival = now
            items[items.count - 1] = last
            return true
        }
        items.append(Item(clauses: [clause], text: text, lang: lang, lastArrival: now))
        return false
    }

    /// Takes the head for synthesis. Once taken it can no longer be merged into (it has started).
    public mutating func next(job: JobID, voice: VoiceHandle, priority: Priority = .p0TTS) -> (item: Item, request: TTSRequest)? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        return (item, request(for: item, job: job, voice: voice, priority: priority))
    }

    /// The request for an item (also used to resend the same clause after an engine restart).
    public func request(for item: Item, job: JobID, voice: VoiceHandle, priority: Priority = .p0TTS) -> TTSRequest {
        TTSRequest(job: job, clause: item.clause, text: item.text, language: item.lang, voice: voice,
                   seed: TTSSeed.make(voice: voice, text: item.text), priority: priority,
                   wholeClause: item.expectedS < config.wholeClauseBelowExpectedS)
    }

    /// Hard interrupt or press-wide drop: empties the queue, returns every carried clause ID.
    public mutating func removeAll() -> [UInt64] {
        defer { items.removeAll() }
        return items.flatMap(\.clauses)
    }

    /// Removes the items carrying any of `clauses` (e.g. a press whose clone voice did not come back).
    public mutating func remove(clauses: Set<UInt64>) -> [UInt64] {
        var removed: [UInt64] = []
        items.removeAll { item in
            guard item.clauses.contains(where: clauses.contains) else { return false }
            removed += item.clauses
            return true
        }
        return removed
    }

    /// Backlog > 12 s (§5.5): drops the oldest waiting item.
    public mutating func dropOldest() -> Item? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// Replace a contiguous set of waiting items after summarize/retranslation. Every clause
    /// of a merged item must be selected; otherwise no mutation occurs. Items already taken
    /// for synthesis are absent here and cannot be replaced. The replacement keeps FIFO order.
    @discardableResult
    public mutating func replace(clauses: Set<UInt64>, with clause: UInt64, text: String,
                                  lang: Lang, at now: HostTime) -> [UInt64]? {
        let positions = items.indices.filter { !clauses.isDisjoint(with: items[$0].clauses) }
        guard let first = positions.first, let last = positions.last,
              positions.count == last - first + 1 else { return nil }
        let removed = positions.flatMap { items[$0].clauses }
        guard Set(removed) == clauses,
              items.indices.filter({ !positions.contains($0) }).allSatisfy({ !items[$0].clauses.contains(clause) })
        else { return nil }
        items.replaceSubrange(first...last, with: [Item(clauses: [clause], text: text, lang: lang, lastArrival: now)])
        return removed
    }

    @discardableResult
    public mutating func replaceAll(clause: UInt64, text: String, lang: Lang, at now: HostTime) -> [UInt64] {
        let removed = items.flatMap(\.clauses)
        items = [Item(clauses: [clause], text: text, lang: lang, lastArrival: now)]
        return removed
    }

    static func join(_ a: String, _ b: String) -> String {
        let l = a.trimmingCharacters(in: .whitespaces), r = b.trimmingCharacters(in: .whitespaces)
        if l.isEmpty { return r }
        if r.isEmpty { return l }
        return l + " " + r
    }
}
