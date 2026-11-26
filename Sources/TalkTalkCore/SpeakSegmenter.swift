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
        /// cut out of a faint run that has ended (longSilenceCut) and counts faintOnlyDropped; the faint
        /// diagnostics measure it either way.
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
        /// left out before the clip; nil without a voiced frame. Diagnostics only.
        public var faintLeadMs: Int?
        public var faintCutMs: Int?
        /// Faint audio the leading-silence bound left out since the previous emitted commit. Diagnostics only.
        public var faintTrimmedMs = 0
        /// Faint audio after the clip's last voiced frame, up to the cut; nil without a voiced frame.
        /// Diagnostics only.
        public var faintTailMs: Int?
        /// How long faint runs held back a textSilence cut the VAD silence alone would have made in
        /// this segment, to this commit's decision; nil when none did. Diagnostics only.
        public var faintHeldMs: Int?
        /// The clip holds voiced audio that arrived after faint runs first held this segment's textSilence
        /// cut: the held short clause merged with the speech that followed. Implies faintHeldMs.
        /// Diagnostics only.
        public var faintHeldMerged = false
    }
    public let profile: PolicyProfile.Speak
    public let committer: SpeakCommitter
    public let clipMaxS: Double
    /// Faint frames count as the user's own soft speech: a faint chain may keep a longer lead
    /// (leadBound), faint runs hold a textSilence cut (textSilenceCut) and keep a longSilence
    /// cut out of a faint run that has ended (longSilenceCut), and faint-only drops are counted
    /// (faintOnlyDropped). Off in speaker mode, where remote speech leaks into the faint band; the
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
    /// forced cut would have come due. A word in the release remainder that was voiced by then
    /// would have been in that clip had the commit test allowed no cut there.
    private var relaxedCutDeadline: HostTime?
    /// When faint runs first held back this segment's textSilence cut (see textSilenceCut).
    private var faintHeldAt: HostTime?
    /// Release and stop remainders dropped with no voiced frame but an onset-length faint run, in the
    /// remainder or in its leading silence the leading-silence bound left out (key-up more than about
    /// leadKeep after the soft words); keepsBelowFloor keeps only voiced audio. Counted only with
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
    /// faintLeadMax (see leadBound); older leading audio is left out of the clip (boundLeadingSilence)
    /// or, after a cap restart, dropped with the segment before it (restartPause).
    /// The clip stays within clipMaxS, so a cut more than clipMaxS minus the kept lead after that
    /// frame keeps less of this lead, down to the press pre-roll at the hard cap.
    private static let leadKeep: UInt64 = 1_000_000_000
    /// A chain of faint runs reaching the first voiced frame (while nothing is voiced, the newest audio)
    /// keeps the lead from the press pre-roll before its first run, up to this much before that frame.
    private static let faintLeadMax: UInt64 = 2_500_000_000
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
        guard !finished, through > start else { return [] }
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
    /// remainder contains less than the profile's 0.4 s of actual VAD speech, unless the
    /// covering preview already shows its words or it follows a textSilence or longSilence cut
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
            // for its timing, so it caps a held textSilence cut, but it does not cut inside a faint run
            // that has ended; on a tie textSilence, listed first, wins.
            if let silence = silenceStart(at: audioEnd), HostClock.ms(silence, to: audioEnd) >= profile.boundary.vadSilenceMs {
                let mid = silence + (audioEnd - silence) / 2
                candidates.append((mid, .silence))
                if let cut = textSilenceCut(from: silence, mid: mid) { candidates.append((cut, .textSilence)) }
                else if faintHeldAt == nil, !closesClause(at: mid), textCloses(at: mid) { faintHeldAt = audioEnd }
                candidates.append((longSilenceCut(from: silence, mid: mid), .longSilence))
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

    /// Captured silence at the segment end; a timestamp gap over 1 ms ends it (a device gap is no pause).
    private func observedQuiet() -> (start: HostTime, ms: Int) {
        var quietStart = audioEnd, observed: UInt64 = 0
        for frame in frames.reversed() {
            guard !frame.speech,
                  frame.end >= quietStart || quietStart - frame.end <= Self.shortTimestampTolerance else { break }
            let end = min(frame.end, quietStart)
            if end > frame.start { observed += end - frame.start }
            quietStart = frame.start
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

    /// While nothing is voiced, keep the lead leadBound allows before the newest audio, never before
    /// the segment start.
    private mutating func boundLeadingSilence() {
        guard !frames.contains(where: \.speech) else { return }
        let bounded = leadBound(before: audioEnd, chainFrom: start)
        guard bounded > start else { return }
        faintTrimmed += faintNanos(from: start, to: bounded)
        if !faintRuns(from: start, through: bounded).isEmpty { trimmedFaintRun = true }
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

    /// First instant of the faint chain in [lo, hi) reaching `hi`: the newest run ends within leadKeep
    /// of `hi` and each earlier run less than leadKeep before the next. Nil when there is none.
    private func faintChainStart(from lo: HostTime, through hi: HostTime) -> HostTime? {
        let runs = faintRuns(from: lo, through: hi)
        guard var first = runs.last, hi <= first.end + Self.leadKeep else { return nil }
        for run in runs.dropLast().reversed() {
            guard first.start < run.end + Self.leadKeep else { break }
            first = run
        }
        return first.start
    }

    /// Faint audio inside [from, to).
    private func faintNanos(from lo: HostTime, to hi: HostTime) -> UInt64 {
        frames.reduce(0) { total, f in
            let a = max(lo, f.start), b = min(hi, f.end)
            return total + (f.faint && b > a ? b - a : 0)
        }
    }

    /// The caught-up preview covers the segment's last voiced frame before `cut`; no voiced
    /// segment was dropped since the last emitted cut, so all of its text belongs to this audio.
    private func previewCovers(_ cut: HostTime) -> Bool {
        guard !droppedSpeech, let previewThrough,
              let last = frames.last(where: { $0.speech && $0.start < cut }) else { return false }
        let tolerance = UInt64(max(0, committer.minimum.previewVetoCaughtUpMs)) * 1_000_000
        return previewThrough + tolerance >= min(cut, last.end)
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
    /// (with `trustsFaint`) a faint run (voicedRunMin or longer) holds `mid` and has already ended; then
    /// past every following such run that has also ended, in the middle of the quiet up to the next run
    /// still going or the newest audio (where all have ended, textSilence's point, which wins the tie).
    /// A run holding `mid` that is still going at the decision keeps `mid`, so longSilence still caps a
    /// held textSilence cut. Faint frames under voicedRunMin at the newest audio count as quiet here.
    /// No voiced frame lies between the two points, so pauseCloses answers the same at either.
    private func longSilenceCut(from silence: HostTime, mid: HostTime) -> HostTime {
        guard trustsFaint else { return mid }
        let runs = faintRuns(from: silence, through: audioEnd)
        guard var i = runs.firstIndex(where: { $0.start <= mid && mid < $0.end }), runs[i].end < audioEnd else { return mid }
        while i + 1 < runs.count, runs[i + 1].end < audioEnd { i += 1 }
        let next = i + 1 < runs.count ? runs[i + 1].start : audioEnd
        return runs[i].end + (next - runs[i].end) / 2
    }

    /// After boundary.longSilenceMs of captured silence, a phrase the commit test (preview veto
    /// included) and the character minimum refuse still closes when it holds the release floor of
    /// speech and the covering preview shows two ideographs beyond leading fillers. Noise,
    /// filler-only heads, unrecognized phrases, text ending in a continuation mark and a complete
    /// short reply still settling wait.
    private func pauseCloses(at cut: HostTime) -> Bool {
        let continues = (stable.last.map { Self.continuationMarks.contains($0) } ?? false) || stable.hasSuffix("...")
        guard !replySettling, !continues,
              speechSeconds(through: cut) + 1e-9 >= profile.release.commitRemainderMinSpeechS,
              ideographsBeyondFillers() >= Self.wordIdeographsMin, previewCovers(cut) else { return false }
        return observedQuiet().ms >= profile.boundary.longSilenceMs
    }

    /// CJK ideographs in the stable text once leading fillers are stripped.
    private func ideographsBeyondFillers() -> Int {
        var rest = Substring(stable.filter { $0.isLetter || $0.isNumber })
        let fillers = profile.fillers.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        while let filler = fillers.first(where: { rest.hasPrefix($0) }) { rest = rest.dropFirst(filler.count) }
        return rest.unicodeScalars.filter(\.properties.isIdeographic).count
    }

    /// Voiced audio under the release floor is still a clip when the covering preview shows at
    /// least two CJK ideographs beyond leading fillers, such as a short last word after a cut,
    /// or when it is the release remainder right after a textSilence or longSilence cut, holds an
    /// onset-length voiced run before that segment's forced cut would have come due (that forced
    /// cut would have taken the pause after the word), and key-up or a device stop ends it (`final`)
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
        let clock = clockStart
        let seconds = speechSeconds(through: end)
        let voiced = frames.filter { $0.speech && $0.start < end && $0.end > start }
        let reachesFloor = seconds + 1e-9 >= profile.release.commitRemainderMinSpeechS
        // A moved-back cap cut lies well before the newest audio: its covering preview may already show
        // words of the speech after the cut, so only text recognized through the cut can keep it.
        let textBeforeCut = !restart || previewThrough.map {
            $0 <= end + UInt64(max(0, committer.minimum.previewVetoCaughtUpMs)) * 1_000_000 } ?? false
        let keep = reachesFloor || (!voiced.isEmpty && textBeforeCut && keepsBelowFloor(through: end, final: final))
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
                            faintLeadMs: firstVoiced.map { ms(faintNanos(from: pcmStart, to: $0)) },
                            faintCutMs: firstVoiced.map { ms(faintNanos(from: start, to: min(pcmStart, $0))) },
                            faintTrimmedMs: ms(faintTrimmed),
                            faintTailMs: voiced.last.map { ms(faintNanos(from: min(end, $0.end), to: end)) },
                            faintHeldMs: held.flatMap { $0 > 0 ? $0 : nil }, faintHeldMerged: merged)
        start = end
        frames.removeAll { $0.end <= end }
        if !frames.isEmpty, frames[0].start < end { frames[0].start = end }
        stable = ""; previewCharacters = nil; previewCjk = nil; previewThrough = nil; punctuationAt = nil; finalThrough = nil
        shortPreview = nil
        lastStableAt = end
        openedByCapRestart = restart; faintHeldAt = nil; trimmedFaintRun = false
        guard keep else {
            if !voiced.isEmpty { droppedSpeech = true; droppedSpeechMs += Int((seconds * 1000).rounded()) }
            else if faintOnly { faintOnlyDropped += 1 }
            return nil
        }
        previewsIgnored = 0; textFloor = end; droppedSpeech = false; droppedSpeechMs = 0; faintTrimmed = 0
        relaxedCutDeadline = reason == .textSilence || reason == .longSilence ? clock + nanos(profile.forceCut.sinceLastS) : nil
        index += 1
        return result
    }

    private func nanos(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) * 1_000_000_000) }
}
