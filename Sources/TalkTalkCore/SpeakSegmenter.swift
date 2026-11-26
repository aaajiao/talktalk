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
        public init(start: HostTime, end: HostTime, speech: Bool, energy: Double) {
            self.start = start; self.end = end; self.speech = speech; self.energy = energy
        }
    }
    public enum Reason: String, Sendable {
        case punctuation, asrFinal, silence, textSilence, clauseDip, stall, forcedDip, hardCap, release, shortReply
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
    }
    public let profile: PolicyProfile.Speak
    public let committer: SpeakCommitter
    public let clipMaxS: Double
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
    /// Set when the last emitted commit was a text-permitted silence cut: when that segment's
    /// forced cut would have come due. A release remainder ending by then would have been in
    /// that clip had the audio estimate allowed no cut there.
    private var textSilenceDeadline: HostTime?
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
    /// the preview may already show their words. Older leading silence is left out of the clip.
    /// The clip stays within clipMaxS, so a cut more than clipMaxS - leadKeep after that frame
    /// keeps less of this lead, down to the press pre-roll at the hard cap.
    private static let leadKeep: UInt64 = 1_000_000_000
    /// SpeakVAD reports speech only after 3 voiced 20 ms frames in a row; a shorter voiced run
    /// (a key click) does not make a remainder worth a clip of its own.
    private static let voicedRunMin: UInt64 = 60_000_000
    public private(set) var releaseThrough: HostTime?

    /// Until SPEAK's stepped-ASR acceptance is complete, the caller keeps the 4.5 s profile
    /// limit. Passing profile.forceCut.clipMaxS explicitly enables the later 6 s limit.
    public init(profile: PolicyProfile.Speak, target: Lang, start: HostTime,
                charactersPerSecond: Double? = nil, clipMaxS: Double? = nil) {
        self.profile = profile; self.start = start; audioEnd = start; lastStableAt = start; textFloor = start
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
    /// covering preview already shows its words or it follows a text-permitted silence cut
    /// (see keepsBelowFloor).
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
                    if let c = commit(at: energyCut(through: cap, leavingSpeechS: head), reason: .hardCap) { out.append(c) }
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
            if let silence = silenceStart(at: audioEnd), HostClock.ms(silence, to: audioEnd) >= profile.boundary.vadSilenceMs {
                candidates.append((silence + (audioEnd - silence) / 2, .silence))
            }
            // From clauseDipAfterS on, or once the preview is stale (it says nothing about the
            // audio), a dipMs pause that closes a clause and already has the release floor of
            // speech after it commits without waiting for vadSilenceMs or the forced cut.
            let aged = Double(HostClock.ms(clock, to: audioEnd)) / 1000 >= profile.boundary.clauseDipAfterS
            if aged || HostClock.ms(max(lastStableAt, clock), to: audioEnd) >= profile.boundary.stallMs,
               let dip = shortPauseCut() {
                candidates.append((dip, aged ? .clauseDip : .stall))
            }
            // Earliest allowed cut; a tie keeps the order above. A silence the audio estimate
            // refuses still closes once the caught-up preview holds the character minimum.
            guard let candidate = candidates.enumerated().sorted(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) })
                .map(\.element).compactMap({ cut, reason -> (HostTime, Reason)? in
                    if closesClause(at: cut) { return (cut, reason) }
                    return reason == .silence && textCloses(at: cut) ? (cut, .textSilence) : nil
                }).first else { break }
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
        var quietStart = audioEnd, observedQuiet: UInt64 = 0
        for frame in frames.reversed() {
            guard !frame.speech,
                  frame.end >= quietStart || quietStart - frame.end <= Self.shortTimestampTolerance else { break }
            let end = min(frame.end, quietStart)
            if end > frame.start { observedQuiet += end - frame.start }
            quietStart = frame.start
        }
        let quietMs = Int(observedQuiet / 1_000_000)
        guard quietMs >= max(500, profile.boundary.vadSilenceMs),
              speechSeconds(through: quietStart) >= max(0.4, profile.release.commitRemainderMinSpeechS) else { return nil }
        // Keep the existing release tail inside observed silence; ASR timestamps never cut PCM.
        let tailMs = max(250, profile.ptt.tailMs)
        guard quietMs >= tailMs else { return nil }
        return quietStart + UInt64(tailMs) * 1_000_000
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

    /// While nothing is voiced, keep only `leadKeep` of audio before the newest frame.
    private mutating func boundLeadingSilence() {
        guard audioEnd > start + Self.leadKeep, !frames.contains(where: \.speech) else { return }
        let bounded = audioEnd - Self.leadKeep
        start = bounded
        frames.removeAll { $0.end <= bounded }
        if !frames.isEmpty, frames[0].start < bounded { frames[0].start = bounded }
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

    /// Voiced audio under the release floor is still a clip when the covering preview shows at
    /// least two CJK ideographs beyond leading fillers, such as a short last word after a cut,
    /// or when it is the release remainder right after a text-permitted silence cut, ends before
    /// that segment's forced cut would have come due and holds an onset-length voiced run: the
    /// preview reopens at that cut and stops at key-up, so it rarely covers that remainder in time.
    private func keepsBelowFloor(through cut: HostTime, final: Bool) -> Bool {
        if final, let deadline = textSilenceDeadline, cut <= deadline, !droppedSpeech,
           longestVoicedRun(through: cut) >= Self.voicedRunMin { return true }
        guard previewCovers(cut) else { return false }
        var rest = Substring(stable.filter { $0.isLetter || $0.isNumber })
        let fillers = profile.fillers.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        while let filler = fillers.first(where: { rest.hasPrefix($0) }) { rest = rest.dropFirst(filler.count) }
        return rest.unicodeScalars.filter(\.properties.isIdeographic).count >= 2
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

    private mutating func commit(at end: HostTime, reason: Reason, final: Bool = false) -> Commit? {
        guard end > start else { return nil }
        let clock = clockStart
        let seconds = speechSeconds(through: end)
        let voiced = frames.filter { $0.speech && $0.start < end && $0.end > start }
        let reachesFloor = seconds + 1e-9 >= profile.release.commitRemainderMinSpeechS
        let keep = reachesFloor || (!voiced.isEmpty && keepsBelowFloor(through: end, final: final))
        // Cuts never pass clockStart + clipMaxS, so this bound only leaves out audio before the
        // clock; a cut more than clipMaxS - leadKeep after the first voiced frame trims the lead.
        let clip = nanos(clipMaxS)
        let pcmStart = max(start, end > clip ? end - clip : 0)
        let result = Commit(start: pcmStart, end: end, index: index, speechMs: Int((seconds * 1000).rounded()),
                            isFinalChunk: final, reason: reason,
                            speechStart: voiced.first.map { max(pcmStart, $0.start) },
                            speechEnd: voiced.last.map { min(end, $0.end) }, previewsIgnored: previewsIgnored,
                            previewCjk: previewCjk, keptBelowFloor: !reachesFloor)
        start = end
        frames.removeAll { $0.end <= end }
        if !frames.isEmpty, frames[0].start < end { frames[0].start = end }
        stable = ""; previewCharacters = nil; previewCjk = nil; previewThrough = nil; punctuationAt = nil; finalThrough = nil
        shortPreview = nil
        lastStableAt = end
        guard keep else {
            if !voiced.isEmpty { droppedSpeech = true }
            return nil
        }
        previewsIgnored = 0; textFloor = end; droppedSpeech = false
        textSilenceDeadline = reason == .textSilence ? clock + nanos(profile.forceCut.sinceLastS) : nil
        index += 1
        return result
    }

    private func nanos(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) * 1_000_000_000) }
}
