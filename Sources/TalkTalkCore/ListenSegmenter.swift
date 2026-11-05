import Foundation

/// LISTEN sentence segmentation (ARCHITECTURE.md §5.1, `listen.draft` / `listen.finalize`).
/// Pure and clock-free: the pipeline feeds ASR events and audio ticks with a millisecond clock and
/// performs the returned actions. Virtual-clock tests drive it directly.
///
///  - Stable source = ASR finals of this sentence + LCP-2 of the last two volatile hypotheses
///    (LCPCommitter); the source line shows stable + the volatile tail.
///  - Draft: stable source grew by ≥ `minNewWords`, or grew at all and `maxIntervalMs` passed;
///    never more than `maxUpdatesPerS`. Only the newest draft matters (the pipeline cancels older).
///  - Finalize trigger: FinalizeTrigger (asrFinal / punctPause / force / silence / stall / hardCap).
///    Except for asrFinal the pipeline calls `finalize(through:)`; the deadline of the final MT is
///    counted from this moment (§5.1 "截止 = 定稿触发时刻 + 1.5 s").
///  - Final text: the next ASR final after the trigger. If none arrives within `finalWaitMs`, the
///    stable + volatile text at that point is used (`finalTimeout`), so a sentence never hangs.
public struct ListenSegmenter: Sendable {
    public typealias SentenceID = UInt64

    public enum Action: Sendable, Equatable {
        /// Translate `text` (the whole current sentence) as a draft.
        case draft(sentence: SentenceID, text: String)
        /// Call `finalize(through:)` on the ASR stream with audio up to `throughMs`.
        case finalize(sentence: SentenceID, trigger: FinalizeTrigger.Kind, throughMs: Int)
        /// The sentence's source text is final: send it to the final MT.
        case sentenceFinal(SentenceFinal)
    }

    public struct SentenceFinal: Sendable, Equatable {
        public var sentence: SentenceID
        public var text: String
        public var trigger: FinalizeTrigger.Kind
        /// The finalize-trigger time (deadline origin).
        public var triggerAtMs: Int
        public var finalAtMs: Int
        /// True when no ASR final arrived within `finalWaitMs` and the hypothesis was used.
        public var finalTimeout: Bool
        public var firstWordAtMs: Int?
    }

    public let lang: Lang
    public let draft: PolicyProfile.Listen.Draft
    public let finalWaitMs: Int
    public private(set) var sentence: SentenceID = 1
    private var trigger: FinalizeTrigger
    private var lcp: LCPCommitter
    private var finals: [String] = []          // ASR finals inside the current sentence (only before a trigger)
    private var volatile = ""
    private var pending: (trigger: FinalizeTrigger.Kind, atMs: Int)?
    private var lastDraftAtMs: Int?
    private var lastDraftWords = 0
    private var lastSpeechAtMs: Int?
    private var firstWordAtMs: Int?

    public init(lang: Lang, profile: PolicyProfile.Listen, finalWaitMs: Int = 1500) {
        self.lang = lang
        self.draft = profile.draft
        self.finalWaitMs = finalWaitMs
        self.trigger = FinalizeTrigger(config: profile.finalize, lang: lang)
        self.lcp = LCPCommitter(unit: .for(lang))
    }

    // MARK: - views

    /// Stable source text of the current sentence.
    public var stableText: String {
        ([finals.joined(separator: " "), lcp.committedText].filter { !$0.isEmpty }).joined(separator: " ")
    }

    /// What the subtitle's source line shows: stable text + the unstable volatile tail.
    public var sourceLine: String {
        let base = finals.joined(separator: " ")
        return [base, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var awaitingFinal: Bool { pending != nil }
    public var revisions: Int { lcp.revisions }

    private var fullWords: Int { FinalizeTrigger.wordCount(sourceLine) }

    // MARK: - inputs

    /// A volatile hypothesis of the current (unfinalized) audio.
    public mutating func volatile(_ text: String, nowMs: Int) -> [Action] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // While the final is pending, volatiles may still describe this sentence's audio or
        // already the next one; ignore them. SpeechAnalyzer's volatiles are cumulative for the
        // unfinalized range, so the first one after the final restates the new sentence.
        guard pending == nil else { return [] }
        volatile = t
        lcp.update(hypothesis: t)
        if firstWordAtMs == nil, !t.isEmpty { firstWordAtMs = nowMs }
        return draftIfDue(nowMs: nowMs) + observe(nowMs: nowMs, silenceMs: 0, asrFinal: false)
    }

    /// An ASR final (the recognizer's own end of segment, or the answer to finalize(through:)).
    public mutating func final(_ text: String, nowMs: Int) -> [Action] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = pending {
            return close(text: ([stableFinalsText, t].filter { !$0.isEmpty }).joined(separator: " "),
                         trigger: p.trigger, triggerAtMs: p.atMs, nowMs: nowMs, timeout: false)
        }
        guard !t.isEmpty else { return [] }
        if firstWordAtMs == nil { firstWordAtMs = nowMs }
        finals.append(t)
        volatile = ""
        lcp.reset()
        // A final with no trigger pending ends the sentence only when it ends with sentence
        // punctuation. en-US `.fastResults` emits finals mid-sentence (M0-T10); those become stable
        // source and the sentence goes on until another rule fires (§5.1, changed in M1).
        if FinalizeTrigger.endsWithSentencePunct(t) {
            _ = trigger.observe(nowMs: nowMs, words: fullWords, stableEndsWithSentencePunct: true,
                                silenceMs: 0, asrFinal: true)
            return close(text: finals.joined(separator: " "), trigger: .asrFinal, triggerAtMs: nowMs,
                         nowMs: nowMs, timeout: false)
        }
        return draftIfDue(nowMs: nowMs) + observe(nowMs: nowMs, silenceMs: 0, asrFinal: false)
    }

    /// Periodic tick (e.g. every 50 ms) with the remote VAD's current silence length.
    public mutating func tick(nowMs: Int, silenceMs: Int) -> [Action] {
        if silenceMs == 0 { lastSpeechAtMs = nowMs }
        if let p = pending {
            guard nowMs - p.atMs >= finalWaitMs else { return [] }
            let text = sourceLine
            return close(text: text, trigger: p.trigger, triggerAtMs: p.atMs, nowMs: nowMs, timeout: true)
        }
        return draftIfDue(nowMs: nowMs) + observe(nowMs: nowMs, silenceMs: silenceMs, asrFinal: false)
    }

    /// A capture gap over two seconds ends the old analyzer's source range immediately.
    public mutating func audioGap(nowMs: Int) -> [Action] {
        close(text: sourceLine, trigger: .stall, triggerAtMs: nowMs, nowMs: nowMs, timeout: true)
    }

    // MARK: - internals

    private var stableFinalsText: String { finals.joined(separator: " ") }

    private mutating func observe(nowMs: Int, silenceMs: Int, asrFinal: Bool) -> [Action] {
        guard pending == nil else { return [] }
        let stable = stableText
        guard let kind = trigger.observe(nowMs: nowMs, words: fullWords,
                                         stableEndsWithSentencePunct: FinalizeTrigger.endsWithSentencePunct(stable),
                                         silenceMs: silenceMs, asrFinal: asrFinal) else { return [] }
        // Everything heard is already final (a mid-sentence final, then silence): nothing for
        // finalize(through:) to add, so close now instead of waiting finalWaitMs.
        if volatile.isEmpty, !finals.isEmpty {
            return close(text: stableFinalsText, trigger: kind, triggerAtMs: nowMs, nowMs: nowMs, timeout: false)
        }
        pending = (kind, nowMs)
        return [.finalize(sentence: sentence, trigger: kind, throughMs: nowMs)]
    }

    private mutating func draftIfDue(nowMs: Int) -> [Action] {
        let text = stableText
        let words = FinalizeTrigger.wordCount(text)
        guard words > lastDraftWords else { return [] }
        let minGap = 1000 / max(1, draft.maxUpdatesPerS)
        if let last = lastDraftAtMs, nowMs - last < minGap { return [] }
        let grewEnough = words - lastDraftWords >= draft.minNewWords
        let intervalDue = lastDraftAtMs.map { nowMs - $0 >= draft.maxIntervalMs }
            ?? (firstWordAtMs.map { nowMs - $0 >= draft.maxIntervalMs } ?? false)
        guard grewEnough || intervalDue else { return [] }
        lastDraftAtMs = nowMs
        lastDraftWords = words
        return [.draft(sentence: sentence, text: text)]
    }

    private mutating func close(text: String, trigger kind: FinalizeTrigger.Kind, triggerAtMs: Int,
                                nowMs: Int, timeout: Bool) -> [Action] {
        let id = sentence
        let first = firstWordAtMs
        sentence += 1
        finals = []
        pending = nil
        lcp.reset()
        trigger.reset()
        lastDraftAtMs = nil
        lastDraftWords = 0
        firstWordAtMs = nil
        volatile = ""
        var out: [Action] = []
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            out.append(.sentenceFinal(SentenceFinal(sentence: id, text: clean, trigger: kind, triggerAtMs: triggerAtMs,
                                                    finalAtMs: nowMs, finalTimeout: timeout, firstWordAtMs: first)))
        }
        return out
    }
}
