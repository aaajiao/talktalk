import Foundation

/// The audio-first commit test from §5.2. Preview can veto only after its audio time catches
/// up with the candidate; a slow recognizer never postpones an otherwise valid boundary.
public struct SpeakCommitter: Sendable {
    public let minimum: PolicyProfile.Speak.CommitMin
    public let charactersPerSecond: Double
    public init(profile: PolicyProfile.Speak, target: Lang, charactersPerSecond: Double? = nil) {
        minimum = profile.commitMin(for: target)
        let rate = charactersPerSecond ?? minimum.defaultCjkPerS
        self.charactersPerSecond = rate.isFinite && rate > 0 ? rate : minimum.defaultCjkPerS
    }

    public func allows(speechS: Double, sinceOnsetS: Double, cutAt: HostTime,
                       previewCharacters: Int?, previewThrough: HostTime?) -> Bool {
        guard speechS >= minimum.speechS, speechS * charactersPerSecond >= Double(minimum.estCjk),
              sinceOnsetS >= minimum.sinceOnsetS else { return false }
        let tolerance = UInt64(max(0, minimum.previewVetoCaughtUpMs)) * 1_000_000
        let caughtUpAt = cutAt > tolerance ? cutAt - tolerance : 0
        if let previewCharacters, let previewThrough, previewThrough >= caughtUpAt,
           previewCharacters < minimum.estCjk { return false }
        return true
    }
}

/// One press's pure cutting policy. Audio stays in the caller's floor-enforcing ring; only
/// VAD/energy/time facts are retained here. Commits are non-overlapping host ranges; leading
/// silence left out of a clip and dropped sub-floor segments leave gaps between them.
public struct SpeakSegmenter: Sendable {
    public struct Frame: Sendable, Equatable {
        public var start, end: HostTime
        public var speech: Bool
        /// Mean-square energy (same scale for every frame); used only to compare cut windows.
        public var energy: Double
        /// SpeakVAD's faint flag (libfvad voice just under the energy threshold). Never speech: it moves
        /// no clock, speech total or dropped-speech flag, and silence and dip runs count it as quiet. With
        /// `trustsFaint` it extends the lead kept before the first voiced frame (leadBound, for leading
        /// silence and a cap restart's cut), holds a textSilence cut (textSilenceCut), keeps a longSilence
        /// cut out of a faint run that has ended (longSilenceCut), makes a soft phrase of a segment with no
        /// voiced frame whose words the covering preview shows (softPhraseEnd) and counts faintOnlyDropped;
        /// the faint diagnostics measure it either way.
        public var faint: Bool
        public init(start: HostTime, end: HostTime, speech: Bool, energy: Double, faint: Bool = false) {
            self.start = start; self.end = end; self.speech = speech; self.energy = energy; self.faint = faint && !speech
        }
    }
    public enum Reason: String, Sendable {
        case punctuation, asrFinal, silence, textSilence, longSilence, clauseDip, stall, forcedDip, hardCap, release, shortReply
    }
    public struct Commit: Sendable, Equatable {
        public var start, end: HostTime
        public var index: Int
        public var speechMs: Int
        public var isFinalChunk: Bool
        public var reason: Reason
        /// First and last voiced instants inside [start, end]; nil when no frame was voiced. Diagnostics only.
        public var speechStart: HostTime?
        public var speechEnd: HostTime?
        /// Preview updates ignored as belonging to an earlier segment while this one, or a dropped one
        /// just before it, was open. Diagnostics only.
        public var previewsIgnored = 0
        /// CJK ideographs in the latest stable preview text since the last emitted cut, as held at
        /// this cut; nil when no preview update arrived. Diagnostics only.
        public var previewCjk: Int?
        /// Emitted although its speech is under the release floor (see `keepsBelowFloor`); the
        /// pipeline must not apply that floor again.
        public var keptBelowFloor = false
        /// VAD speech in sub-floor segments dropped since the previous emitted commit. Diagnostics only.
        public var droppedSpeechMs = 0
        /// This segment was opened by a hard-cap cut moved back to the pause before speech going
        /// on across the cap (see capRestart). Diagnostics only.
        public var capRestart = false
        /// Faint audio in the clip before its first voiced frame, and the faint lead the clipMaxS bound
        /// left out before the clip; in a clip with no voiced frame (a soft phrase), all of its faint audio
        /// and what that bound left out. Diagnostics only.
        public var faintLeadMs: Int?
        public var faintCutMs: Int?
        /// Faint audio the leading-silence bound left out since the previous emitted commit. Diagnostics only.
        public var faintTrimmedMs = 0
        /// Faint audio after the clip's last voiced frame, up to the cut; nil without a voiced frame.
        /// Diagnostics only.
        public var faintTailMs: Int?
        /// How long faint runs held back a textSilence cut (under the release floor, a longSilence cut)
        /// the VAD silence alone would have made in this segment, to this commit's decision; nil when
        /// none did. Diagnostics only.
        public var faintHeldMs: Int?
        /// The clip holds voiced audio that arrived after faint runs first held this segment's textSilence
        /// or longSilence cut: the held short clause merged with the speech that followed. Implies faintHeldMs.
        /// Diagnostics only.
        public var faintHeldMerged = false
    }
    public let profile: PolicyProfile.Speak
    public let committer: SpeakCommitter
    public let clipMaxS: Double
    /// Faint frames count as the user's own soft speech: a faint chain may keep a longer lead
    /// (leadBound, softPhraseLead), faint runs hold a textSilence cut (textSilenceCut) and keep a
    /// longSilence cut out of a faint run that has ended (longSilenceCut), a segment with no voiced
    /// frame can be a soft phrase (softPhraseEnd), and faint-only drops are counted (faintOnlyDropped).
    /// Off in speaker mode, where remote speech leaks into the faint band; the
    /// measurement-only diagnostics (faintLeadMs, faintCutMs, faintTrimmedMs, faintTailMs) are still measured.
    private let trustsFaint: Bool
    public private(set) var start: HostTime
    public private(set) var finished = false
    private var frames: [Frame] = []
    private var audioEnd: HostTime
    private var index = 0
    private var stable = ""
    private var previewCharacters: Int?
    private var previewThrough: HostTime?
    private var previewCjk: Int?
    private var previewsIgnored = 0
    /// End of the last emitted commit: preview text describes the audio from here. Leading
    /// silence left out of a clip and dropped segments after it do not move the caller's
    /// preview, so they stay inside the text; `droppedSpeech` says a dropped one held voiced frames.
    private var textFloor: HostTime
    private var droppedSpeech = false
    private var droppedSpeechMs = 0
    private var openedByCapRestart = false
    /// Faint audio boundLeadingSilence left out since the last emitted commit; dropped ones carry it.
    private var faintTrimmed: UInt64 = 0
    /// boundLeadingSilence left out an onset-length faint run of this segment (faintOnlyDropped).
    private var trimmedFaintRun = false
    /// Set when the last emitted commit was a textSilence or longSilence cut: when that segment's
    /// forced cut would have come due, or under the release floor its hard cap (the forced cut needs
    /// the floor before its dip). A word in the release remainder that was voiced by then would have
    /// been in that clip had the commit test allowed no cut there.
    private var relaxedCutDeadline: HostTime?
    /// When faint runs first held back this segment's textSilence cut, or under the release floor its
    /// longSilence cut (see textSilenceCut, longSilenceCut).
    private var faintHeldAt: HostTime?
    /// `through` of the first preview since the last cut whose stable text named a word
    /// (wordIdeographsMin ideographs beyond fillers): under the release floor a longSilence cut needs
    /// it by the cut, so words recognized from the next phrase's soft onset do not keep a click or a
    /// filler as a clip of its own (see pauseCloses).
    private var wordTextThrough: HostTime?
    /// Ideographs beyond fillers the text since the last cut already held for faint audio this segment
    /// left out: a soft phrase must name wordIdeographsMin more, so the words of soft speech left out do
    /// not make a later breath or noise a clip (softWordsNamed). Raised when boundLeadingSilence moves
    /// `start` past the `through` a preview reached with them (wordRecords), also as a soft phrase's hold
    /// slides with clipMaxS; to the whole text when it trims an onset-length faint run outside that hold;
    /// when a preview first names them with nothing of this segment heard before its `through`; and when
    /// a preview arrives only for audio before `start`.
    private var staleIdeographs = 0
    /// Each new high of ideographsBeyondFillers since the last cut, with the `through` of the first
    /// preview that reached it: its words were named from audio before that point.
    private var wordRecords: [(ideographs: Int, through: HostTime)] = []
    /// Release and stop remainders dropped with no voiced frame but an onset-length faint run, in the
    /// remainder or in its leading silence the leading-silence bound left out; keepsBelowFloor keeps such
    /// a remainder only as a soft phrase the covering preview shows (softPhraseEnd). Counted only with
    /// `trustsFaint`. Diagnostics only.
    public private(set) var faintOnlyDropped = 0
    private var lastStableAt: HostTime
    private var punctuationAt: HostTime?
    private var finalThrough: HostTime?
    private struct ShortPreview {
        var from, through, settledAt: HostTime
        var text: String
    }
    private var shortPreview: ShortPreview?
    private static let shortTimestampTolerance: UInt64 = 1_000_000 // 1 ms hardware/SRC timestamp rounding
    /// Unvoiced audio kept before a segment's first voiced frame: VAD misses soft onsets, and
    /// the preview may already show their words. A faint chain reaching that frame keeps more, up to
    /// faintLeadMax (see leadBound), and a soft phrase's held lead up to clipMaxS (softPhraseLead), which
    /// voiced speech arriving within its hold keeps; older leading audio is left out of the clip
    /// (boundLeadingSilence) or, after a cap restart, dropped with the segment before it (restartPause).
    /// The clip stays within clipMaxS, so a cut more than clipMaxS minus the kept lead after that
    /// frame keeps less of this lead, down to the press pre-roll at the hard cap.
    private static let leadKeep: UInt64 = 1_000_000_000
    /// A chain of faint runs reaching the first voiced frame (while nothing is voiced, the newest audio)
    /// keeps the lead from the press pre-roll before its first run, up to this much before that frame
    /// (a soft phrase's held lead goes further: softPhraseLead).
    private static let faintLeadMax: UInt64 = 2_500_000_000
    /// Faint runs past the point the preview reached that a soft phrase still takes as its tail (a
    /// breath or noise the recognizer never names): more waits for the preview (previewCovers).
    private static let softTailMax: UInt64 = 300_000_000
    /// SpeakVAD reports speech only after 3 voiced 20 ms frames in a row; a shorter voiced run
    /// (a key click) does not make a remainder worth a clip of its own.
    private static let voicedRunMin: UInt64 = 60_000_000
    /// A textSilence cut at the silence midpoint keeps this much faint-free audio before it.
    private static let faintClearance: UInt64 = 60_000_000
    /// Quiet after the last faint run that a held textSilence cut waits for (it goes in its middle):
    /// for the text cut, faint audio counts as voice. Levers if held cuts mostly end merged into the
    /// next clause (Commit.faintHeldMerged): 250 ms, or SpeakVAD.faintMarginDb = 0, which empties the
    /// faint band (build 98).
    private static let faintQuietMs = 350
    /// CJK ideographs beyond leading fillers that name a word.
    private static let wordIdeographsMin = 2
    /// Stable text ending in one of these (or "...") says the recognizer hears the clause go on.
    private static let continuationMarks: Set<Character> = ["，", "、", "；", "：", ",", ";", ":", "…"]
    public private(set) var releaseThrough: HostTime?

    /// Until SPEAK's stepped-ASR acceptance is complete, the caller keeps the 4.5 s profile
    /// limit. Passing profile.forceCut.clipMaxS explicitly enables the later 6 s limit.
    /// `trustsFaint` false (speaker mode: remote speech leaks into the faint band) keeps the plain
    /// leadKeep rule, cuts textSilence and longSilence at the VAD silence midpoint whatever faint runs
    /// lie there, and counts no faint-only drop; the faint diagnostics are still measured.
    public init(profile: PolicyProfile.Speak, target: Lang, start: HostTime,
                charactersPerSecond: Double? = nil, clipMaxS: Double? = nil, trustsFaint: Bool = true) {
        self.profile = profile; self.start = start; audioEnd = start; lastStableAt = start; textFloor = start
        self.trustsFaint = trustsFaint
        committer = SpeakCommitter(profile: profile, target: target, charactersPerSecond: charactersPerSecond)
        self.clipMaxS = max(0.1, clipMaxS ?? profile.forceCut.clipMaxSUntilSteppedASR)
    }

    public mutating func audio(_ input: Frame) -> [Commit] {
        guard !finished, input.end > audioEnd else { return [] }
        // Host timestamps may have a small gap between IO blocks. A tail ending in that
        // gap still closes capture, using only audio already observed.
        if let releaseThrough, input.start >= releaseThrough { return finish(at: releaseThrough) }
        var frame = input
        frame.start = max(frame.start, audioEnd)
        if let releaseThrough { frame.end = min(frame.end, releaseThrough) }
        guard frame.end > frame.start else { return [] }
        // New speech or unobserved audio breaks the short reply's completion evidence.
        if frame.speech || frame.start - audioEnd > Self.shortTimestampTolerance { shortPreview = nil }
        frame.energy = frame.energy.isFinite ? max(0, frame.energy) : Double.greatestFiniteMagnitude
        frames.append(frame); audioEnd = frame.end
        boundLeadingSilence()
        if let releaseThrough, audioEnd >= releaseThrough { return finish(at: releaseThrough) }
        return cuts()
    }

    /// Text must describe the audio since the last emitted cut (the caller removes already
    /// committed preview text); leading silence left out of a clip and dropped segments since
    /// then may be in it.
    /// Late updates through an earlier emitted cut are ignored.
    public mutating func preview(stableText: String, through: HostTime, at now: HostTime,
                                  isFinal: Bool = false, boundary: SpeakPreviewBoundary? = nil) -> [Commit] {
        guard !finished else { return [] }
        guard through > start else {
            // Text only for audio left out since the last emitted cut names no word a soft phrase may claim.
            if through > textFloor, boundary.map({ $0.from + Self.shortTimestampTolerance >= textFloor }) ?? true {
                noteStaleWords(ideographsBeyondFillers(stableText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return []
        }
        // A callback queued before the microphone worker cut a segment can arrive after
        // the cut but before SpeakPipeline has advanced its preview floor. The floor is the
        // clip's sample-aligned end, up to one 16 kHz sample before a cut that falls between
        // samples, so that rounding does not make the rest of the press text-blind. Only
        // emitted clips move that floor, so left-out leading silence or a dropped segment does not.
        if let boundary, boundary.from + Self.shortTimestampTolerance < textFloor { previewsIgnored += 1; return [] }
        let boundary = boundary.map { SpeakPreviewBoundary(from: max($0.from, textFloor), fullyStable: $0.fullyStable) }
        let text = stableText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let boundary, boundary.fullyStable, Self.isCompleteShortReply(text) {
            let settledAt: HostTime
            if let previous = shortPreview, previous.from == boundary.from, previous.text == text {
                settledAt = previous.settledAt
            } else { settledAt = now }
            shortPreview = ShortPreview(from: boundary.from, through: through,
                                        settledAt: settledAt, text: text)
        } else {
            shortPreview = nil
        }
        if text != stable { lastStableAt = now; punctuationAt = nil }
        stable = text
        previewCharacters = text.filter { $0.isLetter || $0.isNumber }.count
        previewCjk = text.unicodeScalars.filter(\.properties.isIdeographic).count
        previewThrough = through
        let named = ideographsBeyondFillers()
        if wordTextThrough == nil, named >= Self.wordIdeographsMin { wordTextThrough = through }
        if named > (wordRecords.last?.ideographs ?? 0) {
            wordRecords.append((named, through))
            // Stable text lags `through`: words first named with no voiced frame or faint run of this
            // segment before it come from audio left out.
            if !frames.contains(where: { $0.speech && $0.start < through }), faintRuns(from: start, through: through).isEmpty {
                noteStaleWords(named)
            }
        }
        if let last = text.last, profile.boundary.punct.contains(last) {
            if punctuationAt == nil { punctuationAt = now }
        } else { punctuationAt = nil }
        if isFinal { finalThrough = through }
        return cuts()
    }

    /// Capture continues through `releaseThrough`. Existing trailing silence counts toward
    /// the tail. With enough silence already captured, return the final commit immediately;
    /// otherwise audio(_:) finishes when the tail arrives. Device stops use finish(at:).
    public mutating func release(at keyUp: HostTime) -> [Commit] {
        guard !finished, releaseThrough == nil else { return [] }
        let observedThrough = min(keyUp, audioEnd)
        let silent = silenceStart(at: observedThrough).map { max(0, HostClock.ms($0, to: observedThrough)) } ?? 0
        let tail = max(0, profile.ptt.tailMs - silent)
        let through = keyUp + UInt64(tail) * 1_000_000
        releaseThrough = through
        return through <= audioEnd ? finish(at: through) : []
    }

    /// End-of-capture (normal release or a device stop). No final clip is emitted when the
    /// remainder contains less than the profile's 0.4 s of actual VAD speech (none in a soft phrase),
    /// unless the covering preview already shows its words or it follows a textSilence or longSilence cut
    /// and was voiced before that segment's forced cut would have come due (see keepsBelowFloor);
    /// a remainder its own hard cap reached first was cut there, and kept only by the covering preview.
    public mutating func finish(at now: HostTime) -> [Commit] {
        guard !finished else { return [] }
        audioEnd = min(audioEnd, now)
        var result = cuts(forceOnly: true)
        if audioEnd > start, let tail = commit(at: audioEnd, reason: .release, final: true) { result.append(tail) }
        finished = true
        return result
    }

    private mutating func cuts(forceOnly: Bool = false) -> [Commit] {
        var out: [Commit] = []
        while audioEnd > start {
            let clock = clockStart
            let cap = clock + nanos(clipMaxS)
            let hard = audioEnd >= cap
            let due = hard || Double(HostClock.ms(clock, to: audioEnd)) / 1000 >= profile.forceCut.sinceLastS
                || speechSeconds(through: audioEnd) * committer.charactersPerSecond >= Double(profile.forceCut.cjk)
            if due, (!forceOnly || hard) {
                let limit = min(cap, audioEnd)
                let head = forcedHeadSpeechS(through: limit)
                if hard || !pauseIsOpening(at: limit), let dip = latestDip(through: limit, leavingSpeechS: head) {
                    if let c = commit(at: dip, reason: .forcedDip) { out.append(c) }
                    continue
                }
                if hard {
                    let energy = energyCut(through: cap, leavingSpeechS: head)
                    // A sparse segment the floor would drop whole while speech goes on across the
                    // cap: drop only the audio before that speech's pause, when the pause is recent
                    // (see capRestart). Nothing else can cut while this waits (at most vadSilenceMs
                    // past the cap).
                    if dropsWhole(at: energy) {
                        switch capRestart(cap: cap, settle: forceOnly) {
                        case .wait: return out
                        case .at(let pause):
                            if let c = commit(at: pause, reason: .forcedDip, restart: true) { out.append(c) }
                            continue
                        case .none: break
                        }
                    }
                    if let c = commit(at: energy, reason: .hardCap) { out.append(c) }
                    continue
                }
            }
            guard !forceOnly else { break }
            if let end = shortReplyCut() {
                if let c = commit(at: end, reason: .shortReply) { out.append(c) }
                continue
            }
            var candidates: [(HostTime, Reason)] = []
            if let through = finalThrough, through > start, through <= audioEnd { candidates.append((through, .asrFinal)) }
            if let seen = punctuationAt, HostClock.ms(seen, to: audioEnd) >= profile.boundary.punctHoldMs,
               let through = previewThrough, through > start, through <= audioEnd { candidates.append((through, .punctuation)) }
            // A silence the commit test refuses still closes once the caught-up preview holds the
            // character minimum (clear of faint runs), or after boundary.longSilenceMs of captured
            // silence once the covering preview shows a word. longSilence treats faint audio as quiet
            // for its timing, so it caps a held textSilence cut, but it does not cut inside faint
            // audio that has ended, nor below the release floor (where it is the only text cut) inside
            // faint audio at all; on a tie textSilence, listed first, wins.
            if let silence = silenceStart(at: audioEnd), HostClock.ms(silence, to: audioEnd) >= profile.boundary.vadSilenceMs {
                let mid = silence + (audioEnd - silence) / 2
                candidates.append((mid, .silence))
                if let cut = textSilenceCut(from: silence, mid: mid) { candidates.append((cut, .textSilence)) }
                else if faintHeldAt == nil, !closesClause(at: mid), textCloses(at: mid) { faintHeldAt = audioEnd }
                if let cut = longSilenceCut(from: silence, mid: mid) { candidates.append((cut, .longSilence)) }
                else if faintHeldAt == nil, pauseCloses(at: mid) { faintHeldAt = audioEnd }
            }
            // From clauseDipAfterS on, or once the preview is stale (it says nothing about the
            // audio), a dipMs pause that closes a clause and already has the release floor of
            // speech after it commits without waiting for vadSilenceMs or the forced cut.
            let aged = Double(HostClock.ms(clock, to: audioEnd)) / 1000 >= profile.boundary.clauseDipAfterS
            if aged || HostClock.ms(max(lastStableAt, clock), to: audioEnd) >= profile.boundary.stallMs,
               let dip = shortPauseCut() {
                candidates.append((dip, aged ? .clauseDip : .stall))
            }
            // Earliest allowed cut; a tie keeps the order above.
            guard let candidate = candidates.enumerated().sorted(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) })
                .map(\.element).first(where: { cut, reason in
                    switch reason {
                    case .textSilence: textCloses(at: cut)
                    case .longSilence: pauseCloses(at: cut)
                    default: closesClause(at: cut)
                    }
                }) else { break }
            if let c = commit(at: candidate.0, reason: candidate.1) { out.append(c) }
        }
        return out
    }

    /// A narrow early path for familiar complete replies, not a relaxed general sentence
    /// threshold. Numbers, names, unfinished clauses and abbreviations keep the old policy.
    private static func isCompleteShortReply(_ text: String) -> Bool {
        guard let last = text.last, "。！？.!?".contains(last) else { return false }
        let body = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return shortReplies.contains(body)
    }
    private static let shortReplies: Set<String> = [
        "好的", "可以", "明白了", "我明白了", "知道了", "我知道了", "收到", "谢谢", "谢谢你", "谢谢您",
        "不客气", "不用谢", "没问题", "没有问题", "是的", "不是", "同意", "不同意", "我同意", "我不同意",
        "再见", "明天见", "请稍等", "对的", "没错",
        "yes", "okay", "ok", "sure", "thanks", "thank you", "thank you very much", "no problem",
        "i understand", "understood", "i see", "got it", "of course", "exactly", "correct", "all right",
        "sounds good", "i agree", "i disagree", "that's right", "that’s right", "you’re welcome", "you're welcome",
        "sorry", "i'm sorry", "i’m sorry", "goodbye", "see you tomorrow", "please wait"
    ]

    private func shortReplyCut() -> HostTime? {
        // Leading silence left out before `start` may sit inside the reply's text; a dropped voiced segment may not.
        guard releaseThrough == nil, let evidence = shortPreview,
              evidence.from >= (droppedSpeech ? start : textFloor), evidence.through <= audioEnd,
              audioEnd >= evidence.settledAt,
              HostClock.ms(evidence.settledAt, to: audioEnd) >= max(300, profile.boundary.punctHoldMs),
              let firstSpeech = frames.first(where: \.speech), let lastSpeech = frames.last(where: \.speech),
              evidence.from <= firstSpeech.start, evidence.through >= lastSpeech.end else { return nil }
        // Require genuinely captured continuous silence; a device/timestamp gap is not a pause.
        let quiet = observedQuiet()
        guard quiet.ms >= max(500, profile.boundary.vadSilenceMs),
              speechSeconds(through: quiet.start) >= max(0.4, profile.release.commitRemainderMinSpeechS) else { return nil }
        // Keep the existing release tail inside observed silence; ASR timestamps never cut PCM.
        let tailMs = max(250, profile.ptt.tailMs)
        guard quiet.ms >= tailMs else { return nil }
        return quiet.start + UInt64(tailMs) * 1_000_000
    }

    /// A complete short reply has not yet held for its settle time: shortReplyCut may still take it.
    private var replySettling: Bool {
        guard let evidence = shortPreview else { return false }
        return audioEnd < evidence.settledAt
            || HostClock.ms(evidence.settledAt, to: audioEnd) < max(300, profile.boundary.punctHoldMs)
    }

    /// Captured silence at the segment end, from `floor` at the earliest; a timestamp gap over 1 ms ends
    /// it (a device gap is no pause).
    private func observedQuiet(since floor: HostTime = 0) -> (start: HostTime, ms: Int) {
        var quietStart = audioEnd, observed: UInt64 = 0
        for frame in frames.reversed() {
            guard !frame.speech, frame.end > floor,
                  frame.end >= quietStart || quietStart - frame.end <= Self.shortTimestampTolerance else { break }
            let end = min(frame.end, quietStart), lo = max(frame.start, floor)
            if end > lo { observed += end - lo }
            quietStart = lo
        }
        return (quietStart, Int(observed / 1_000_000))
    }

    private func speechSeconds(through end: HostTime) -> Double {
        frames.filter(\.speech).reduce(0) { total, f in
            let lo = max(start, f.start), hi = min(end, f.end)
            return total + (hi > lo ? Double(hi - lo) / 1e9 : 0)
        }
    }

    private func silenceStart(at end: HostTime) -> HostTime? {
        var beginning: HostTime?
        for f in frames.reversed() where f.start < end {
            if f.speech { break }
            beginning = max(start, f.start)
        }
        return beginning
    }

    /// Where the forced-cut, hard-cap, clause-dip and stall clocks start: the press pre-roll
    /// before the segment's first voiced frame (or before the newest audio while nothing is
    /// voiced), never earlier than the segment. Leading silence does not use up the cap.
    private var clockStart: HostTime {
        let preroll = nanos(Double(max(0, profile.ptt.prerollMs)) / 1000)
        let anchor = frames.first(where: \.speech)?.start ?? audioEnd
        return anchor > start + preroll ? anchor - preroll : start
    }

    /// While nothing is voiced, keep the lead leadBound allows before the newest audio (a soft phrase
    /// the preview shows: softPhraseLead), never before the segment start.
    private mutating func boundLeadingSilence() {
        guard !frames.contains(where: \.speech) else { return }
        var bounded = leadBound(before: audioEnd, chainFrom: start)
        let held = softPhraseLead()
        if let held { bounded = min(bounded, held) }
        guard bounded > start else { return }
        faintTrimmed += faintNanos(from: start, to: bounded)
        // Words named only from audio now left out stay in the text: they no longer count for a soft
        // phrase, also when its hold slides past them. Trimming an onset-length faint run outside that
        // hold leaves the whole text to the audio left out.
        if let named = wordRecords.last(where: { $0.through <= bounded }) { noteStaleWords(named.ideographs) }
        if !faintRuns(from: start, through: bounded).isEmpty {
            trimmedFaintRun = true
            if held == nil { noteStaleWords(ideographsBeyondFillers()) }
        }
        start = bounded
        frames.removeAll { $0.end <= bounded }
        if !frames.isEmpty, frames[0].start < bounded { frames[0].start = bounded }
    }

    /// Runs of contiguous faint frames of at least voicedRunMin inside [from, through), oldest first.
    private func faintRuns(from: HostTime, through: HostTime) -> [(start: HostTime, end: HostTime)] {
        var runs: [(start: HostTime, end: HostTime)] = [], open: (start: HostTime, end: HostTime)?
        func close() { if let r = open, r.end - r.start >= Self.voicedRunMin { runs.append(r) }; open = nil }
        for f in frames where f.end > from && f.start < through {
            let lo = max(from, f.start), hi = min(through, f.end)
            guard f.faint else { close(); continue }
            if let r = open, lo <= r.end + Self.shortTimestampTolerance { open = (r.start, hi) } else { close(); open = (lo, hi) }
        }
        close(); return runs
    }

    /// Where a clip's lead may start when its first voiced frame (while nothing is voiced, the newest
    /// audio) is at `hi`: `leadKeep` before it and, with `trustsFaint`, also from the press pre-roll
    /// before a faint chain in [lo, hi) reaching it, but never more than faintLeadMax before it.
    private func leadBound(before hi: HostTime, chainFrom lo: HostTime) -> HostTime {
        var bounded = hi > Self.leadKeep ? hi - Self.leadKeep : 0
        if trustsFaint, let chain = faintChainStart(from: lo, through: hi) {
            let preroll = nanos(Double(max(0, profile.ptt.prerollMs)) / 1000)
            let reach = hi > Self.faintLeadMax ? hi - Self.faintLeadMax : 0
            bounded = min(bounded, max(chain > preroll ? chain - preroll : 0, reach))
        }
        return bounded
    }

    /// First instant of the faint chain in [lo, hi) reaching `hi`: the newest run ends within `reach`
    /// of `hi` and each earlier run less than `link` before the next (both leadKeep unless given). Nil
    /// when there is none.
    private func faintChainStart(from lo: HostTime, through hi: HostTime, reach: UInt64 = SpeakSegmenter.leadKeep,
                                 link: UInt64 = SpeakSegmenter.leadKeep) -> HostTime? {
        let runs = faintRuns(from: lo, through: hi)
        guard var first = runs.last, hi <= first.end + reach else { return nil }
        for run in runs.dropLast().reversed() {
            guard first.start < run.end + link else { break }
            first = run
        }
        return first.start
    }

    /// The stable text names a soft phrase's word: wordIdeographsMin ideographs beyond fillers past
    /// those it held for soft audio already left out (staleIdeographs).
    private var softWordsNamed: Bool {
        ideographsBeyondFillers() >= staleIdeographs + Self.wordIdeographsMin
    }

    /// Text with `ideographs` (beyond fillers) describes faint audio left out of this segment. Only ever
    /// raised: a later revision of that text with fewer ideographs (三点 as 3点) keeps the higher count.
    private mutating func noteStaleWords(_ ideographs: Int) {
        staleIdeographs = max(staleIdeographs, ideographs)
    }

    /// wordTextThrough for a soft phrase: `through` of the first preview since the last cut whose text
    /// named wordIdeographsMin ideographs beyond staleIdeographs.
    private var softWordThrough: HostTime? {
        wordRecords.first { $0.ideographs >= staleIdeographs + Self.wordIdeographsMin }?.through
    }

    /// A segment with no voiced frame whose words the stable preview text since the last emitted cut
    /// shows (softWordsNamed, no voiced segment dropped since) is a soft phrase: VAD heard its speech
    /// only as faint frames. While the long-pause cut can still take it (its newest faint run ended at
    /// most longSilenceMs plus vadSilenceMs before the newest audio, and so did each earlier run of the
    /// chain before the next), its faint chain is kept from the press pre-roll before the chain, up to
    /// clipMaxS (not faintLeadMax) before where that cut would go (the middle of the quiet after the
    /// newest run), so the clip can carry the words the preview shows. Nil otherwise.
    private func softPhraseLead() -> HostTime? {
        guard trustsFaint, !droppedSpeech, softWordsNamed,
              let newest = faintRuns(from: start, through: audioEnd).last?.end else { return nil }
        let reach = UInt64(max(0, profile.boundary.longSilenceMs + profile.boundary.vadSilenceMs)) * 1_000_000
        guard let chain = faintChainStart(from: start, through: audioEnd, reach: reach, link: reach) else { return nil }
        let preroll = nanos(Double(max(0, profile.ptt.prerollMs)) / 1000), clip = nanos(clipMaxS)
        let cut = newest + (audioEnd - newest) / 2
        return max(chain > preroll ? chain - preroll : 0, cut > clip ? cut - clip : 0)
    }

    /// With `trustsFaint` and softWordsNamed, the end of the newest faint run (voicedRunMin or longer)
    /// before `cut` in a segment with no voiced frame before `cut`: where a soft phrase ends for its long
    /// pause and cut (previewCovers takes a short tail past what the preview reached). Nil with a voiced
    /// frame, without a faint run, without those words, or without `trustsFaint`.
    private func softPhraseEnd(before cut: HostTime) -> HostTime? {
        guard trustsFaint, softWordsNamed, !frames.contains(where: { $0.speech && $0.start < cut }) else { return nil }
        return faintRuns(from: start, through: cut).last?.end
    }

    /// Faint audio inside [from, to).
    private func faintNanos(from lo: HostTime, to hi: HostTime) -> UInt64 {
        frames.reduce(0) { total, f in
            let a = max(lo, f.start), b = min(hi, f.end)
            return total + (f.faint && b > a ? b - a : 0)
        }
    }

    /// The caught-up preview covers the segment's last voiced frame before `cut`; no voiced segment was
    /// dropped since the last emitted cut, so all of its text belongs to this audio. In a soft phrase
    /// (softPhraseEnd) it reached one of its faint runs and less than softTailMax of faint runs lies past
    /// that point: a short trailing run the recognizer never names (a breath) does not hold it up, as
    /// trailing faint audio after a voiced frame does not.
    private func previewCovers(_ cut: HostTime) -> Bool {
        guard !droppedSpeech, let previewThrough else { return false }
        let tolerance = UInt64(max(0, committer.minimum.previewVetoCaughtUpMs)) * 1_000_000
        if let last = frames.last(where: { $0.speech && $0.start < cut }) {
            return previewThrough + tolerance >= min(cut, last.end)
        }
        guard softPhraseEnd(before: cut) != nil else { return false }
        let reached = min(cut, previewThrough + tolerance)
        let runs = faintRuns(from: start, through: cut)
        let untold = runs.reduce(UInt64(0)) { $0 + ($1.end > reached ? $1.end - max($1.start, reached) : 0) }
        return runs.contains { $0.end <= reached } && untold < Self.softTailMax
    }

    /// A silence cut that the speech estimate refuses (VAD undercounts fast or soft speech):
    /// the covering preview holds the character minimum in CJK ideographs, and the clip keeps
    /// the release floor of speech.
    private func textCloses(at cut: HostTime) -> Bool {
        guard let previewCjk, previewCjk >= committer.minimum.estCjk,
              speechSeconds(through: cut) + 1e-9 >= profile.release.commitRemainderMinSpeechS else { return false }
        return previewCovers(cut)
    }

    /// Where a textSilence cut may go in the VAD quiet run from `silence` (already vadSilenceMs long):
    /// its current midpoint `mid` once no faint run (voicedRunMin or longer) ends later than
    /// faintClearance before it, otherwise the middle of the quiet after the last faint run once that
    /// quiet is faintQuietMs long, whichever comes first; nil until then. VAD misses soft speech, and
    /// a cut inside it strands the soft words in a remainder with no voiced frame. Only this cut
    /// waits: longSilence treats faint audio as quiet for its timing (it only moves its cut out of a
    /// faint run that has ended, see longSilenceCut), and the other silence, dip, stall and forced
    /// cuts treat it as quiet. Without `trustsFaint` always `mid`.
    private func textSilenceCut(from silence: HostTime, mid: HostTime) -> HostTime? {
        guard trustsFaint, let faint = faintRuns(from: silence, through: audioEnd).last?.end,
              faint + Self.faintClearance > mid else { return mid }
        return HostClock.ms(faint, to: audioEnd) >= Self.faintQuietMs ? faint + (audioEnd - faint) / 2 : nil
    }

    /// Where a longSilence cut goes in the VAD quiet run from `silence`: its midpoint `mid`, unless
    /// (with `trustsFaint`) a faint run (voicedRunMin or longer) holds `mid` (`mid` lies in it, or in a
    /// gap of less than faintQuietMs between it and the next run) and has already ended; then past every
    /// following such run that has also ended, in the middle of the quiet up to the next run still going
    /// or the newest audio (where all have ended, textSilence's point, which wins the tie). A run holding
    /// `mid` that is still going at the decision keeps `mid`, so longSilence still caps a held
    /// textSilence cut. Under the release floor no textSilence cut is held and nothing else closes the
    /// phrase at this pause, so the cut waits as textSilence's does (nil until then; the hard cap
    /// bounds the wait): a cut inside the soft words would strand them in a remainder with no voiced
    /// frame. Faint frames under voicedRunMin at the newest audio count as quiet here. No voiced frame
    /// lies between `mid` and the cut, so pauseCloses answers the same at either. A soft phrase
    /// (softPhraseEnd), whose VAD quiet run is the whole segment, is cut in the middle of the quiet after
    /// its last faint run, where softPhraseLead bounds its lead.
    private func longSilenceCut(from silence: HostTime, mid: HostTime) -> HostTime? {
        guard trustsFaint else { return mid }
        if let soft = softPhraseEnd(before: audioEnd) { return soft + (audioEnd - soft) / 2 }
        if speechSeconds(through: silence) + 1e-9 < profile.release.commitRemainderMinSpeechS {
            return textSilenceCut(from: silence, mid: mid)
        }
        let runs = faintRuns(from: silence, through: audioEnd)
        let gap = UInt64(Self.faintQuietMs) * 1_000_000
        guard var i = runs.indices.first(where: { k in
            runs[k].start <= mid && (mid < runs[k].end
                || (k + 1 < runs.count && mid < runs[k + 1].start && runs[k + 1].start < runs[k].end + gap))
        }), runs[i].end < audioEnd else { return mid }
        while i + 1 < runs.count, runs[i + 1].end < audioEnd { i += 1 }
        let next = i + 1 < runs.count ? runs[i + 1].start : audioEnd
        return runs[i].end + (next - runs[i].end) / 2
    }

    /// After boundary.longSilenceMs of captured silence, a phrase the commit test (preview veto
    /// included) and the character minimum refuse still closes when the covering preview shows two
    /// ideographs beyond leading fillers, also under the release floor of speech (VAD misses soft
    /// speech): keepsBelowFloor keeps that clip by the same preview test, as it would at the hard cap,
    /// which only came later, cut at the cap and could trim the lead for the trailing quiet. Under the
    /// floor the text decides alone, so its word must have been recognized through the cut (within
    /// previewVetoCaughtUpMs): the preview may already show the soft onset of the next phrase.
    /// previewCovers needs a voiced frame or, with `trustsFaint`, a soft phrase (softPhraseEnd), whose
    /// pause is the captured quiet after its last faint run and whose word is the one beyond the text
    /// of soft audio left out (softWordThrough). Noise, filler-only heads, unrecognized
    /// phrases, text ending in a continuation mark and a complete short reply still settling wait.
    private func pauseCloses(at cut: HostTime) -> Bool {
        let continues = (stable.last.map { Self.continuationMarks.contains($0) } ?? false) || stable.hasSuffix("...")
        guard !replySettling, !continues,
              ideographsBeyondFillers() >= Self.wordIdeographsMin, previewCovers(cut) else { return false }
        if speechSeconds(through: cut) + 1e-9 < profile.release.commitRemainderMinSpeechS {
            let tolerance = UInt64(max(0, committer.minimum.previewVetoCaughtUpMs)) * 1_000_000
            let word = softPhraseEnd(before: cut) != nil ? softWordThrough : wordTextThrough
            guard let word, word <= cut + tolerance else { return false }
        }
        let quiet = softPhraseEnd(before: audioEnd).map { observedQuiet(since: $0) } ?? observedQuiet()
        return quiet.ms >= profile.boundary.longSilenceMs
    }

    /// CJK ideographs in `text` (the stable text) once leading fillers are stripped.
    private func ideographsBeyondFillers(_ text: String? = nil) -> Int {
        var rest = Substring((text ?? stable).filter { $0.isLetter || $0.isNumber })
        let fillers = profile.fillers.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        while let filler = fillers.first(where: { rest.hasPrefix($0) }) { rest = rest.dropFirst(filler.count) }
        return rest.unicodeScalars.filter(\.properties.isIdeographic).count
    }

    /// Voiced audio under the release floor, or a soft phrase (softPhraseEnd), is still a clip when the
    /// covering preview shows at least two CJK ideographs beyond leading fillers, such as a short last
    /// word after a cut,
    /// or when it is the release remainder right after a textSilence or longSilence cut, holds an
    /// onset-length voiced run before that segment's forced cut would have come due (that forced
    /// cut would have taken the pause after the word; under the release floor it could not, so
    /// until that segment's hard cap), and key-up or a device stop ends it (`final`)
    /// before the remainder's own hard cap (its clock + clipMaxS). A cap or cap-restart cut before
    /// then is not final and drops it unless the covering preview keeps it. The preview reopens at
    /// the cut and stops at key-up, so it rarely covers that remainder in time.
    private func keepsBelowFloor(through cut: HostTime, final: Bool) -> Bool {
        if final, let deadline = relaxedCutDeadline, !droppedSpeech,
           longestVoicedRun(through: min(cut, deadline)) >= Self.voicedRunMin { return true }
        return previewCovers(cut) && ideographsBeyondFillers() >= Self.wordIdeographsMin
    }

    /// The longest contiguous voiced stretch of the segment before `cut`.
    private func longestVoicedRun(through cut: HostTime) -> UInt64 {
        var best: UInt64 = 0, run: UInt64 = 0, runEnd: HostTime?
        for f in frames where f.start < cut {
            let lo = max(start, f.start), hi = min(cut, f.end)
            guard f.speech, hi > lo else { run = 0; runEnd = nil; continue }
            if let runEnd, lo > runEnd + Self.shortTimestampTolerance { run = 0 }
            run += hi - lo; runEnd = hi; best = max(best, run)
        }
        return best
    }

    /// The normal commit test for a cut at `cut`, preview veto included.
    private func closesClause(at cut: HostTime) -> Bool {
        let onset = frames.first(where: { $0.speech && $0.start < cut })?.start ?? cut
        return committer.allows(speechS: speechSeconds(through: cut),
            sinceOnsetS: Double(HostClock.ms(onset, to: cut)) / 1000, cutAt: cut,
            previewCharacters: previewCharacters, previewThrough: previewThrough)
    }

    /// Midpoints of the quiet runs of at least dipMs before `end`, oldest first; a run still
    /// open at `end` counts once it is long enough.
    private func dips(through end: HostTime) -> [HostTime] {
        var quietStart: HostTime?, quietEnd: HostTime?, cuts: [HostTime] = []
        func collect() {
            if let lo = quietStart, let hi = quietEnd, HostClock.ms(lo, to: hi) >= profile.forceCut.dipMs {
                cuts.append(lo + (hi - lo) / 2)
            }
        }
        for f in frames where f.start < end {
            if f.speech { collect(); quietStart = nil; quietEnd = nil }
            else { if quietStart == nil { quietStart = max(start, f.start) }; quietEnd = min(end, f.end) }
        }
        collect()
        return cuts
    }

    /// The latest dip that closes a clause and is already followed by the release floor of speech.
    /// A pause still open at the end waits for vadSilenceMs instead: cutting it at dipMs would strand
    /// a short last word after it in a remainder that release drops.
    private func shortPauseCut() -> HostTime? {
        let total = speechSeconds(through: audioEnd), floor = profile.release.commitRemainderMinSpeechS
        return dips(through: audioEnd).last {
            $0 > start && total - speechSeconds(through: $0) + 1e-9 >= floor && closesClause(at: $0)
        }
    }

    private func latestDip(through end: HostTime, leavingSpeechS head: Double) -> HostTime? {
        dips(through: end).last { $0 > start && speechSeconds(through: $0) >= head }
    }

    /// A forced cut leaves the commit minimum before it once the segment holds that much speech,
    /// so a sub-minimum head never waits out the forced-cut timer of its own; a sparse segment
    /// keeps the release floor.
    private func forcedHeadSpeechS(through end: HostTime) -> Double {
        let floor = profile.release.commitRemainderMinSpeechS
        let full = max(floor, committer.minimum.speechS)
        return speechSeconds(through: end) >= full ? full : floor
    }

    /// The forced point fell inside a pause still shorter than dipMs, after a commit minimum of
    /// speech: let it become a dip (at most dipMs) instead of cutting back to an older one.
    private func pauseIsOpening(at end: HostTime) -> Bool {
        guard let quiet = silenceStart(at: end) else { return false }
        return HostClock.ms(quiet, to: end) < profile.forceCut.dipMs
            && speechSeconds(through: quiet) >= max(profile.release.commitRemainderMinSpeechS, committer.minimum.speechS)
    }

    /// A cut at `cut` would be dropped whole: under the release floor and not kept (keepsBelowFloor).
    private func dropsWhole(at cut: HostTime) -> Bool {
        speechSeconds(through: cut) + 1e-9 < profile.release.commitRemainderMinSpeechS
            && !keepsBelowFloor(through: cut, final: false)
    }

    private enum CapRestart { case none, wait, at(HostTime) }

    /// Speech goes on across the cap when voiced audio before it continues, or resumes after it,
    /// within vadSilenceMs: the cap would cut into a word that has just started. The cut moves back
    /// to the latest pause of at least vadSilenceMs before that speech that has older voiced audio
    /// before it, if that pause ends at most vadSilenceMs plus the release floor (0.75 s) before
    /// min(cap, last voiced end before it); otherwise the cap cut stands. So only voiced audio that
    /// could be the just-started word moves into the new segment, and its clock starts at most 0.75 s
    /// plus prerollMs (1.05 s) before that point. Undecided until vadSilenceMs has passed since the
    /// last voiced frame before the cap; at the end of capture (`settle`) only the observed audio counts.
    private func capRestart(cap: HostTime, settle: Bool) -> CapRestart {
        let window = UInt64(max(0, profile.boundary.vadSilenceMs)) * 1_000_000
        guard let last = frames.last(where: { $0.speech && $0.start < cap }) else { return .none }
        let near = min(cap, last.end)
        let reach = near + window
        guard frames.contains(where: { $0.speech && $0.end > cap && $0.start < reach }) else {
            return settle || audioEnd >= reach ? .none : .wait
        }
        let reachBack = window + nanos(profile.release.commitRemainderMinSpeechS)
        return restartPause(before: last.start, notEndingBefore: near > reachBack ? near - reachBack : 0)
            .map { .at($0) } ?? .none
    }

    /// The latest quiet run of at least vadSilenceMs that ends by `end` and has voiced audio of this
    /// segment before it, cut at the later of its midpoint and where leadBound starts the lead of the
    /// speech after it (so a faint chain before that speech stays with it, as in a leading silence);
    /// nil when there is none or that run ends before `floor`.
    private func restartPause(before end: HostTime, notEndingBefore floor: HostTime) -> HostTime? {
        var quietStart: HostTime?, quietEnd: HostTime?, voicedBefore = false, found: (cut: HostTime, end: HostTime)?
        for f in frames where f.start <= end {
            if f.speech {
                if voicedBefore, let lo = quietStart, let hi = quietEnd,
                   HostClock.ms(lo, to: hi) >= profile.boundary.vadSilenceMs {
                    found = (max(lo + (hi - lo) / 2, leadBound(before: hi, chainFrom: lo)), hi)
                }
                voicedBefore = true; quietStart = nil; quietEnd = nil
            } else {
                if quietStart == nil { quietStart = max(start, f.start) }
                quietEnd = f.end
            }
        }
        guard let found, found.end >= floor else { return nil }
        return found.cut
    }

    private func energyCut(through end: HostTime, leavingSpeechS head: Double) -> HostTime {
        let window = UInt64(max(1, profile.forceCut.minEnergyWindowMs)) * 1_000_000
        var best: (energy: Double, cut: HostTime)?
        for frame in frames where frame.start >= start && frame.start < end {
            let lo = frame.start, hi = min(end, lo + window)
            guard hi - lo == window else { continue }
            let cut = lo + window / 2
            // Do not repeatedly select the silent pre-roll and generate tiny empty clips.
            guard speechSeconds(through: cut) >= head else { continue }
            var sum = 0.0, duration = 0.0
            for f in frames where f.start < hi && f.end > lo {
                let n = Double(min(hi, f.end) - max(lo, f.start))
                sum += f.energy * n; duration += n
            }
            guard duration > 0 else { continue }
            let mean = sum / duration
            if best == nil || mean <= best!.energy { best = (mean, cut) }
        }
        return best?.cut ?? end
    }

    /// `restart`: a hard-cap cut moved back to the pause before speech going on across the cap.
    private mutating func commit(at end: HostTime, reason: Reason, final: Bool = false, restart: Bool = false) -> Commit? {
        guard end > start else { return nil }
        // A soft phrase has no voiced frame to start a clock; its kept lead stands in for it (relaxedCutDeadline).
        let clock = frames.contains(where: { $0.speech && $0.start < end }) ? clockStart : start
        let seconds = speechSeconds(through: end)
        let voiced = frames.filter { $0.speech && $0.start < end && $0.end > start }
        let reachesFloor = seconds + 1e-9 >= profile.release.commitRemainderMinSpeechS
        // A moved-back cap cut lies well before the newest audio: its covering preview may already show
        // words of the speech after the cut, so only text recognized through the cut can keep it.
        let textBeforeCut = !restart || previewThrough.map {
            $0 <= end + UInt64(max(0, committer.minimum.previewVetoCaughtUpMs)) * 1_000_000 } ?? false
        // keepsBelowFloor needs a voiced run (rule one) or the covering preview (rule two), whose
        // anchor is a voiced frame or, in a soft phrase, a faint run (softPhraseEnd).
        let keep = reachesFloor || (textBeforeCut && keepsBelowFloor(through: end, final: final))
        // Cuts never pass clockStart + clipMaxS, so this bound only leaves out audio before the
        // clock; a cut more than clipMaxS minus the kept lead after the first voiced frame trims
        // the oldest lead first, faint audio included (faintCutMs).
        let clip = nanos(clipMaxS)
        let pcmStart = max(start, end > clip ? end - clip : 0)
        let firstVoiced = voiced.first.map { max(start, $0.start) }
        let ms = { (ns: UInt64) in Int((Double(ns) / 1e6).rounded()) }
        let held = faintHeldAt.map { audioEnd > $0 ? ms(audioEnd - $0) : 0 }
        let merged = faintHeldAt.map { at in voiced.contains { $0.start >= at } } ?? false
        let faintOnly = trustsFaint && final && voiced.isEmpty
            && (trimmedFaintRun || !faintRuns(from: start, through: end).isEmpty)
        let result = Commit(start: pcmStart, end: end, index: index, speechMs: Int((seconds * 1000).rounded()),
                            isFinalChunk: final, reason: reason,
                            speechStart: voiced.first.map { max(pcmStart, $0.start) },
                            speechEnd: voiced.last.map { min(end, $0.end) }, previewsIgnored: previewsIgnored,
                            previewCjk: previewCjk, keptBelowFloor: !reachesFloor,
                            droppedSpeechMs: droppedSpeechMs, capRestart: openedByCapRestart,
                            faintLeadMs: ms(faintNanos(from: pcmStart, to: firstVoiced ?? end)),
                            faintCutMs: ms(faintNanos(from: start, to: min(pcmStart, firstVoiced ?? end))),
                            faintTrimmedMs: ms(faintTrimmed),
                            faintTailMs: voiced.last.map { ms(faintNanos(from: min(end, $0.end), to: end)) },
                            faintHeldMs: held.flatMap { $0 > 0 ? $0 : nil }, faintHeldMerged: merged)
        start = end
        frames.removeAll { $0.end <= end }
        if !frames.isEmpty, frames[0].start < end { frames[0].start = end }
        stable = ""; previewCharacters = nil; previewCjk = nil; previewThrough = nil; punctuationAt = nil; finalThrough = nil
        shortPreview = nil; wordTextThrough = nil; wordRecords = []; staleIdeographs = 0
        lastStableAt = end
        openedByCapRestart = restart; faintHeldAt = nil; trimmedFaintRun = false
        guard keep else {
            if !voiced.isEmpty { droppedSpeech = true; droppedSpeechMs += Int((seconds * 1000).rounded()) }
            else if faintOnly { faintOnlyDropped += 1 }
            return nil
        }
        previewsIgnored = 0; textFloor = end; droppedSpeech = false; droppedSpeechMs = 0; faintTrimmed = 0
        let due = reachesFloor ? profile.forceCut.sinceLastS : clipMaxS
        relaxedCutDeadline = reason == .textSilence || reason == .longSilence ? clock + nanos(due) : nil
        index += 1
        return result
    }

    private func nanos(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) * 1_000_000_000) }
}
