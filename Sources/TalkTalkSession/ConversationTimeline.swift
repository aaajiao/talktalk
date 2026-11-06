// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkCore

/// The meeting/phone conversation as one ordered list of pair rows (redesign §4): the remote
/// sentence pairs of `SubtitleBoard` and my push-to-translate turns, merged by arrival time.
/// It keeps the same bounded reading window as the board (about 60 s, at most 24 pairs,
/// about 6,000 source + translation characters, whole pairs only, always the newest pair).
/// In memory only: nothing here is logged, persisted or sent to a model.
public struct ConversationTimeline: Sendable, Equatable {
    public enum Speaker: Sendable, Equatable { case remote, me }

    public enum RowID: Sendable, Hashable {
        /// A remote sentence pair (draft or final), by sentence.
        case remote(UInt64)
        /// Recognized remote speech before any translation exists, by recognition epoch.
        case remoteLive(Int)
        /// One of my turns, by press.
        case me(UInt64)
    }

    /// Delivery label at the end of my translation (§4 送达标签, §5).
    public enum Delivery: Sendable, Equatable {
        /// Meeting: translated audio was played into TalkTalk Mic.
        case sent
        /// Meeting: nothing of this translation was played.
        case notSent
        /// Phone: played while Phone read TalkTalk Mic. Not proof that anyone heard it.
        case phoneSent
        /// Phone: played locally only; Phone was not reading TalkTalk Mic.
        case phoneLocalOnly
        /// Phone's reader changed mid-turn; the turn was stopped.
        case aborted

        public var title: String {
            switch self {
            case .sent: String(localized: "已送出")
            case .notSent: String(localized: "未发送")
            case .phoneSent: String(localized: "已送入 Phone")
            case .phoneLocalOnly: String(localized: "仅本机 · Phone 未接收")
            case .aborted: String(localized: "已中止")
            }
        }

        /// Tooltip and VoiceOver text of the label. It starts with the visible word, so
        /// VoiceOver keeps the safety word, and never claims that the other side heard it.
        public var help: String {
            switch self {
            case .sent: String(localized: "已送出：译音已播放到 TalkTalk Mic")
            case .notSent: String(localized: "未发送：这句译音没有播放，对方听不到")
            case .phoneSent: String(localized: "已送入 Phone：不代表对方已听到")
            case .phoneLocalOnly: String(localized: "仅本机：译音只在本机播放，Phone 没有读取 TalkTalk Mic")
            case .aborted: String(localized: "已中止：Phone 连接变化，本句已停止")
            }
        }

        public var symbol: String? {
            switch self {
            case .sent: SubtitleTokens.ConversationIcon.delivered
            case .notSent: ConversationTextRules.unsentSymbol
            case .phoneSent: SubtitleTokens.VoiceIcon.sentToPhone
            case .phoneLocalOnly: SubtitleTokens.VoiceIcon.thisMac
            case .aborted: SubtitleTokens.VoiceIcon.aborted
            }
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: RowID
        public var speaker: Speaker
        public var source: String
        /// Recognition is still running (text.sourceLive with a static caret).
        public var sourceIsLive: Bool
        public var translation: String
        /// false: a draft (text.draft, "…", draft bar).
        public var translationIsFinal: Bool
        /// Apple fallback final: "备用翻译" badge.
        public var fallback: Bool
        /// My preview-only tail that was never submitted ("未发送" badge).
        public var unsentSource: String
        public var delivery: Delivery?
        /// Ordering key: when this pair first appeared.
        public var arrivedAt: HostTime
        /// When the pair became final or the turn was committed; nil while open. Retention
        /// measures the 60 s window from here, so a long turn is not evicted at once.
        public var settledAt: HostTime?
        /// Insertion order, the tie-breaker for equal arrival times.
        public var order: UInt64

        public init(id: RowID, speaker: Speaker, source: String, sourceIsLive: Bool, translation: String,
                    translationIsFinal: Bool, fallback: Bool, unsentSource: String, delivery: Delivery?,
                    arrivedAt: HostTime, settledAt: HostTime?, order: UInt64) {
            self.id = id; self.speaker = speaker; self.source = source; self.sourceIsLive = sourceIsLive
            self.translation = translation; self.translationIsFinal = translationIsFinal; self.fallback = fallback
            self.unsentSource = unsentSource; self.delivery = delivery
            self.arrivedAt = arrivedAt; self.settledAt = settledAt; self.order = order
        }

        public var isSettled: Bool { settledAt != nil }
        var characters: Int { source.count + translation.count + unsentSource.count }
    }

    /// One of my turns as the dock last showed it.
    public struct Turn: Sendable, Equatable {
        public var press: UInt64
        public var source: String
        public var translation: String
        public var unsentSource: String
        public var isFinal: Bool
        public var startedAt: HostTime
        public var delivery: Delivery?

        public init(press: UInt64, source: String, translation: String, unsentSource: String = "",
                    isFinal: Bool, startedAt: HostTime, delivery: Delivery? = nil) {
            self.press = press; self.source = source; self.translation = translation
            self.unsentSource = unsentSource; self.isFinal = isFinal
            self.startedAt = startedAt; self.delivery = delivery
        }

        public init(_ transcript: SpeakTranscript, startedAt: HostTime, delivery: Delivery? = nil) {
            self.init(press: transcript.press, source: transcript.source, translation: transcript.target,
                      unsentSource: transcript.unsubmittedSource, isFinal: transcript.isFinal,
                      startedAt: startedAt, delivery: delivery)
        }

        public var isEmpty: Bool { source.isEmpty && translation.isEmpty && unsentSource.isEmpty }
    }

    public let retention: SubtitleRetentionPolicy
    public private(set) var rows: [Row] = []

    // Remote arrival bookkeeping. Recognition text belongs to one "epoch" until the source
    // line empties (the sentence closed); a draft received in the current epoch pairs with the
    // live text, an older draft keeps its own submitted source.
    private struct Utterance: Sendable, Equatable {
        var epoch: Int
        var arrival: HostTime
        var sentence: UInt64?
    }
    private var epoch = 0
    private var sourceOpen = false
    private var utterances: [Utterance] = []
    private var draftEpochs: [UInt64: Int] = [:]
    private var retiredRemoteThrough: UInt64 = 0
    private var retiredMeThrough: UInt64 = 0
    private var nextOrder: UInt64 = 0
    private static let utteranceLimit = 16

    public init(retention: SubtitleRetentionPolicy = .meeting) {
        self.retention = retention
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var settledCount: Int { rows.filter(\.isSettled).count }

    /// Every raw remote update, before board pacing, records when an utterance arrived and
    /// which recognition epoch a draft belongs to. It changes no row.
    public mutating func noteRemote(_ update: SubtitleUpdate, at now: HostTime) {
        switch update {
        case let .source(text):
            if text.isEmpty {
                if sourceOpen { epoch += 1; sourceOpen = false }
            } else {
                sourceOpen = true
                if !utterances.contains(where: { $0.epoch == epoch }) {
                    utterances.append(Utterance(epoch: epoch, arrival: now, sentence: nil))
                }
            }
        case let .draft(sentence, _, _):
            if draftEpochs[sentence] == nil { draftEpochs[sentence] = epoch }
            if !utterances.contains(where: { $0.sentence == sentence }) {
                if let index = utterances.firstIndex(where: { $0.epoch == epoch && $0.sentence == nil }) {
                    utterances[index].sentence = sentence
                } else {
                    utterances.append(Utterance(epoch: epoch, arrival: now, sentence: sentence))
                }
            }
        case let .final(sentence, _, _, _, _):
            if !utterances.contains(where: { $0.sentence == sentence }) {
                // A final without a draft belongs to the oldest closed utterance not yet paired.
                if let index = utterances.firstIndex(where: { $0.sentence == nil && $0.epoch < epoch }) {
                    utterances[index].sentence = sentence
                } else {
                    utterances.append(Utterance(epoch: -1, arrival: now, sentence: sentence))
                }
            }
        case let .dropped(sentence):
            draftEpochs[sentence] = nil
            utterances.removeAll { $0.sentence == sentence }
        }
        if utterances.count > Self.utteranceLimit { utterances.removeFirst(utterances.count - Self.utteranceLimit) }
        if draftEpochs.count > Self.utteranceLimit, let oldest = draftEpochs.keys.min() { draftEpochs[oldest] = nil }
    }

    private func arrival(sentence: UInt64) -> HostTime? {
        utterances.first { $0.sentence == sentence }?.arrival
    }

    private mutating func order(for id: RowID) -> UInt64 {
        if let row = rows.first(where: { $0.id == id }) { return row.order }
        nextOrder += 1
        return nextOrder
    }

    /// Mirrors the board's displayed state (after its pacing and the panel's 500 ms preview
    /// cadence): finals, the open draft and the live source. Returns true if any row changed.
    @discardableResult
    public mutating func syncRemote(finals: [SubtitleBoard.Line], draft: SubtitleBoard.Line?,
                                    liveSource: String, at now: HostTime) -> Bool {
        var next = rows.filter { $0.speaker == .me }
        for line in finals where line.sentence > retiredRemoteThrough {
            let id = RowID.remote(line.sentence)
            let old = rows.first { $0.id == id }
            next.append(Row(id: id, speaker: .remote, source: line.source, sourceIsLive: false,
                            translation: line.display, translationIsFinal: true, fallback: line.showsFallbackBadge,
                            unsentSource: "", delivery: nil,
                            arrivedAt: old?.arrivedAt ?? arrival(sentence: line.sentence) ?? now,
                            settledAt: old?.settledAt ?? now, order: order(for: id)))
        }
        var liveShown = !liveSource.isEmpty
        if let draft, draft.sentence > retiredRemoteThrough,
           !finals.contains(where: { $0.sentence == draft.sentence }) {
            let sameEpoch = sourceOpen && draftEpochs[draft.sentence] == epoch
            let id = RowID.remote(draft.sentence)
            let old = rows.first { $0.id == id }
            let source = sameEpoch && !liveSource.isEmpty ? liveSource : draft.source
            next.append(Row(id: id, speaker: .remote, source: source, sourceIsLive: sameEpoch,
                            translation: draft.text, translationIsFinal: false, fallback: false,
                            unsentSource: "", delivery: nil,
                            arrivedAt: old?.arrivedAt ?? arrival(sentence: draft.sentence) ?? now,
                            settledAt: nil, order: order(for: id)))
            if sameEpoch { liveShown = false }
        }
        if liveShown {
            // Raw recognition is shown alone; it never pairs with another sentence's translation.
            let id = RowID.remoteLive(epoch)
            let old = rows.first { $0.id == id }
            let arrived = old?.arrivedAt ?? utterances.first { $0.epoch == epoch }?.arrival ?? now
            next.append(Row(id: id, speaker: .remote, source: liveSource, sourceIsLive: true,
                            translation: "", translationIsFinal: false, fallback: false,
                            unsentSource: "", delivery: nil, arrivedAt: arrived, settledAt: nil,
                            order: order(for: id)))
        }
        return replace(with: next, now: now)
    }

    /// Adds or updates one of my turns as a settled row. Returns true if any row changed.
    @discardableResult
    public mutating func commit(_ turn: Turn, at now: HostTime) -> Bool {
        guard turn.press > retiredMeThrough, !turn.isEmpty else { return false }
        let id = RowID.me(turn.press)
        let old = rows.first { $0.id == id }
        var next = rows.filter { $0.id != id }
        next.append(Row(id: id, speaker: .me, source: turn.source, sourceIsLive: false,
                        translation: turn.translation, translationIsFinal: turn.isFinal, fallback: false,
                        unsentSource: turn.unsentSource, delivery: turn.delivery,
                        arrivedAt: old?.arrivedAt ?? turn.startedAt, settledAt: old?.settledAt ?? now,
                        order: order(for: id)))
        return replace(with: next, now: now)
    }

    /// The rows plus my in-progress turn as an open last-arrived row, for a window too low to
    /// expand the dock. The live turn is not retained.
    public func rows(including live: Turn?) -> [Row] {
        guard let live, !live.isEmpty, live.press > retiredMeThrough,
              !rows.contains(where: { $0.id == .me(live.press) }) else { return rows }
        var result = rows
        result.append(Row(id: .me(live.press), speaker: .me, source: live.source, sourceIsLive: !live.isFinal,
                          translation: live.translation, translationIsFinal: live.isFinal, fallback: false,
                          unsentSource: live.unsentSource, delivery: nil, arrivedAt: live.startedAt,
                          settledAt: nil, order: nextOrder + 1))
        return Self.sorted(result)
    }

    public mutating func clear() {
        clearRemote()
        rows = []
        retiredMeThrough = 0; nextOrder = 0
    }

    /// A subtitle reset (recognition language or configuration change): the remote pairs go,
    /// my turns stay. Sentence numbering may start again, so nothing remote stays retired.
    public mutating func clearRemote() {
        rows.removeAll { $0.speaker == .remote }
        epoch = 0; sourceOpen = false; utterances = []; draftEpochs = [:]
        retiredRemoteThrough = 0
    }

    private static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { $0.arrivedAt == $1.arrivedAt ? $0.order < $1.order : $0.arrivedAt < $1.arrivedAt }
    }

    private mutating func replace(with candidate: [Row], now: HostTime) -> Bool {
        var next = Self.sorted(candidate)
        // Settled pairs share the window, like the board's finals: whole pairs only and the
        // newest always stays. Open rows (draft, live text) never count and are never evicted.
        let settled = next.indices.filter { next[$0].isSettled }
        let entries = settled.map {
            SubtitleRetentionPolicy.Entry(at: next[$0].settledAt ?? now, characters: next[$0].characters)
        }
        let start = retention.retainedStartIndex(in: entries)
        if start > 0 {
            let evicted = Set(settled.prefix(start))
            for index in evicted {
                switch next[index].id {
                case let .remote(sentence): retiredRemoteThrough = max(retiredRemoteThrough, sentence)
                case let .me(press): retiredMeThrough = max(retiredMeThrough, press)
                case .remoteLive: break
                }
            }
            next = next.indices.filter { !evicted.contains($0) }.map { next[$0] }
        }
        guard next != rows else { return false }
        rows = next
        return true
    }
}

/// What one of my turns actually delivered, observed while it is the current turn (§4, §5).
/// `playing` must mean that this turn's own audio is playing (the pipeline reports playing
/// presses), so neither the tail of an earlier turn nor a later one is credited to it.
/// Playback counts only once the turn has translated text. "已中止" is recorded only while the
/// turn is still live (capture, pending work or its own playback): a Phone reader change after
/// a finished turn never relabels it. `isolated`: no raw gate exists (onboarding demo), so
/// playback is local only and nothing can be "已送出".
public struct TurnDelivery: Sendable, Equatable {
    public private(set) var sent = false
    public private(set) var localOnly = false
    public private(set) var aborted = false

    public init() {}

    public mutating func observe(voice: VoiceState.Kind?, playing: Bool, hasTranslation: Bool, live: Bool,
                                 isolated: Bool = false) {
        if isolated {
            if playing, hasTranslation { localOnly = true }
            return
        }
        if voice == .phoneReconnecting, live { aborted = true }
        guard playing, hasTranslation, let voice else { return }
        switch voice {
        case .phoneLocalOnly, .phoneLocalTrial, .localPlayback: localOnly = true
        case .translating, .processing, .playingTranslation: sent = true
        default: break
        }
    }

    /// Meeting: 已送出 or 未发送 (nothing for local-only playback). Phone: 已中止, 仅本机 ·
    /// Phone 未接收 or 已送入 Phone; nothing otherwise (the phone table's "—"). Video has no turns.
    public func label(scene: SubtitleScene, hasTranslation: Bool) -> ConversationTimeline.Delivery? {
        switch scene {
        case .phone:
            if aborted { return .aborted }
            if localOnly { return .phoneLocalOnly }
            return sent ? .phoneSent : nil
        case .meeting:
            if sent { return .sent }
            // Local-only playback (demo): nothing was meant to reach anyone.
            if localOnly { return nil }
            return hasTranslation ? .notSent : nil
        case .video:
            return nil
        }
    }
}

/// Follow / freeze for the whole timeline (§4 冻结与回到最新). While the reader scrolls back,
/// the view keeps its frozen rows and only one latest snapshot is held beside them.
public struct TimelineFollow: Sendable, Equatable {
    public private(set) var frozen: [ConversationTimeline.Row]?
    public private(set) var latest: [ConversationTimeline.Row] = []

    public init() {}

    public var isFrozen: Bool { frozen != nil }
    public var displayed: [ConversationTimeline.Row] { frozen ?? latest }

    /// Replaces the one latest snapshot; the frozen rows stay as they are.
    public mutating func update(_ rows: [ConversationTimeline.Row]) { latest = rows }

    /// Manual scroll back: freeze what is on screen.
    public mutating func freeze() { if frozen == nil { frozen = latest } }

    /// "↓ N 条新字幕", scrolling back to the end, a new own turn or a reset.
    public mutating func follow() { frozen = nil }

    /// Pairs that became final after the frozen snapshot.
    public var newFinalCount: Int {
        guard let frozen else { return 0 }
        let settled = Set(frozen.filter(\.isSettled).map(\.id))
        return latest.filter { $0.isSettled && !settled.contains($0.id) }.count
    }
}
