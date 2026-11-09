import Foundation
import TalkTalkCore

/// Video presents one bilingual cue. Draft and final are states of that same cue, never
/// additional paragraphs. The view owns measured paging and decides when to call advance.
public struct VideoSubtitleBoard: Sendable, Equatable {
    public struct Cue: Sendable, Equatable {
        public var line: SubtitleBoard.Line
        public var isFinal: Bool

        public init(line: SubtitleBoard.Line, isFinal: Bool) {
            self.line = line
            self.isFinal = isFinal
        }
    }

    public private(set) var current: Cue?
    private var pending: [Cue] = []
    private var newestDisplayed: UInt64?
    /// Draft cancellation is monotonic for newly arriving draft identities. Keep current
    /// and queued pairs revisable, and never suppress a valid final with this watermark.
    private var discardedDraftThrough: UInt64?
    /// Every sentence the board has heard of, so a late final can tell "never shown" from "passed".
    private var known: Set<UInt64> = []
    /// The draft most recently replaced by a newer sentence, in case its final arrives just after.
    private var passedDraft: Cue?
    /// When each pending sentence first arrived, for the lag signal (§6 视觉反馈).
    private var queuedAt: [UInt64: HostTime] = [:]
    /// Finals dropped from the pending queue without ever being displayed. The view shows
    /// "已跳过 N 句" when this grows.
    public private(set) var skippedCount = 0
    private static let pendingLimit = 2
    /// Subtitles count as lagging once the next pending cue has waited this long.
    public static let lagThresholdSeconds: Double = 5

    public init() {}

    /// Seconds the oldest pending cue has waited; 0 without pending cues.
    public func lagSeconds(at now: HostTime) -> Double {
        guard let first = pending.first, let queued = queuedAt[first.line.sentence], now > queued else { return 0 }
        return Double(now - queued) / 1_000_000_000
    }

    /// Whole seconds behind once over the threshold; nil while on time.
    public func lag(at now: HostTime) -> Int? {
        let seconds = lagSeconds(at: now)
        return seconds > Self.lagThresholdSeconds ? Int(seconds.rounded(.down)) : nil
    }

    /// Hidden or minimised time is a deliberate pause, not lag: queued cues stop ageing while
    /// the window is not on screen.
    public mutating func excludeHiddenTime(_ duration: HostTime) {
        guard duration > 0 else { return }
        queuedAt = queuedAt.mapValues { $0 &+ duration }
    }

    public var pendingSentenceIDs: [UInt64] { pending.map { $0.line.sentence } }
    public var pendingFinalSentenceIDs: [UInt64] { pending.filter(\.isFinal).map { $0.line.sentence } }
    public var pendingDraftSentenceIDs: [UInt64] { pending.filter { !$0.isFinal }.map { $0.line.sentence } }

    /// Returns whether the visible cue changed. Updating the pending queue alone is not a
    /// display event. In particular, volatile raw source cannot alter a translated pair.
    @discardableResult
    public mutating func apply(_ update: SubtitleUpdate, at now: HostTime = HostClock.now()) -> Bool {
        let before = current
        arrival = now
        defer { trimQueueTimes() }
        switch update {
        case .source:
            break
        case let .draft(sentence, text, source):
            accept(Cue(line: .init(sentence: sentence, text: text, source: source,
                                   approx: false, numberWarning: false), isFinal: false))
        case let .final(sentence, text, source, approx, warning):
            accept(Cue(line: .init(sentence: sentence, text: text, source: source,
                                   approx: approx, numberWarning: warning), isFinal: true))
        case let .dropped(sentence):
            if current?.line.sentence != sentence || current?.isFinal == false {
                discardedDraftThrough = max(discardedDraftThrough ?? 0, sentence)
            }
            pending.removeAll { $0.line.sentence == sentence && !$0.isFinal }
            if current?.line.sentence == sentence, current?.isFinal == false { current = nil }
        }
        return before != current
    }

    private var arrival: HostTime = 0

    private static func wording(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private mutating func trimQueueTimes() {
        let live = Set(pending.map(\.line.sentence))
        queuedAt = queuedAt.filter { live.contains($0.key) }
    }

    private mutating func accept(_ cue: Cue) {
        let sentence = cue.line.sentence
        let neverHeard = known.insert(sentence).inserted
        if known.count > 32 { known = known.filter { $0 + 16 >= sentence } }
        if current?.line.sentence == sentence {
            guard current?.isFinal != true || cue.isFinal else { return }
            current = cue
            return
        }
        // A final can replace a dropped draft until the display moves to a newer sentence.
        // Older results cannot rewind after that move, even if the new cue was later dropped.
        guard newestDisplayed.map({ sentence > $0 || (current == nil && cue.isFinal && sentence == $0) }) ?? true else {
            // A short sentence can still be translating when the next one reaches the screen.
            // Nothing of it has been shown, or only a draft that now reads differently, so it is
            // shown now instead of being lost. After a newer final the moment has passed.
            let correctsDraft = passedDraft.map { $0.line.sentence == sentence && Self.wording($0.line.text) != Self.wording(cue.line.text) } == true
                && current?.isFinal != true
            if neverHeard || correctsDraft, cue.isFinal, let newest = newestDisplayed, newest - sentence <= UInt64(Self.pendingLimit) {
                showLate(cue)
            }
            return
        }
        if let index = pending.firstIndex(where: { $0.line.sentence == sentence }) {
            guard !pending[index].isFinal || cue.isFinal else { return }
            pending[index] = cue
        } else {
            guard cue.isFinal || (discardedDraftThrough.map({ sentence > $0 }) ?? true) else { return }
            pending.append(cue)
            if queuedAt[sentence] == nil { queuedAt[sentence] = arrival }
            pending.sort { $0.line.sentence < $1.line.sentence }
            evictOverflow()
        }
        if current == nil { _ = advance() }
    }

    /// A draft is only a preview and its final still comes, so drafts leave before finals.
    private mutating func evictOverflow() {
        while pending.count > Self.pendingLimit {
            let victim = pending.firstIndex { !$0.isFinal } ?? 0
            if pending[victim].isFinal {
                skippedCount += 1
            } else {
                known.remove(pending[victim].line.sentence)   // nothing of it was shown, so its final may be
            }
            pending.remove(at: victim)
        }
    }

    /// A final on screen has been read or is being read, so showing it again would repeat it.
    /// The late cue waits behind it. A draft is only a preview and returns to the queue.
    private mutating func showLate(_ cue: Cue) {
        if let current, current.isFinal {
            pending.insert(cue, at: pending.firstIndex { $0.line.sentence > cue.line.sentence } ?? pending.endIndex)
            queuedAt[cue.line.sentence] = arrival
            return
        }
        if let current {
            pending.insert(current, at: 0)
            queuedAt[current.line.sentence] = arrival
        }
        current = cue
        newestDisplayed = cue.line.sentence
    }

    /// Advance only when the view has finished the current cue's reading/page interval.
    /// Pending pairs stay together, and the newest two bound latency and retained memory.
    @discardableResult
    public mutating func advance() -> Bool {
        guard !pending.isEmpty else { return false }
        if let current { passedDraft = current.isFinal ? nil : current }
        let next = pending.removeFirst()
        queuedAt[next.line.sentence] = nil
        current = next
        newestDisplayed = next.line.sentence
        if let discardedDraftThrough, next.line.sentence >= discardedDraftThrough {
            self.discardedDraftThrough = nil
        }
        return true
    }

    public mutating func clear() {
        current = nil
        pending.removeAll()
        newestDisplayed = nil
        discardedDraftThrough = nil
        known = []
        passedDraft = nil
        queuedAt = [:]
        skippedCount = 0
    }
}
