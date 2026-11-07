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
/// VAD/energy/time facts are retained here. Commits are adjacent, non-overlapping host ranges.
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
    public enum Reason: String, Sendable { case punctuation, asrFinal, silence, stall, forcedDip, hardCap, release, shortReply }
    public struct Commit: Sendable, Equatable {
        public var start, end: HostTime
        public var index: Int
        public var speechMs: Int
        public var isFinalChunk: Bool
        public var reason: Reason
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
    private var lastStableAt: HostTime
    private var punctuationAt: HostTime?
    private var finalThrough: HostTime?
    private struct ShortPreview {
        var from, through, settledAt: HostTime
        var text: String
    }
    private var shortPreview: ShortPreview?
    private static let shortTimestampTolerance: UInt64 = 1_000_000 // 1 ms hardware/SRC timestamp rounding
    public private(set) var releaseThrough: HostTime?

    /// Until SPEAK's stepped-ASR acceptance is complete, the caller keeps the 4.5 s profile
    /// limit. Passing profile.forceCut.clipMaxS explicitly enables the later 6 s limit.
    public init(profile: PolicyProfile.Speak, target: Lang, start: HostTime,
                charactersPerSecond: Double? = nil, clipMaxS: Double? = nil) {
        self.profile = profile; self.start = start; audioEnd = start; lastStableAt = start
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
        if let releaseThrough, audioEnd >= releaseThrough { return finish(at: releaseThrough) }
        return cuts()
    }

    /// Text must describe the current uncommitted segment (the caller removes already
    /// committed preview text). Late updates through an earlier cut are ignored.
    public mutating func preview(stableText: String, through: HostTime, at now: HostTime,
                                  isFinal: Bool = false, boundary: SpeakPreviewBoundary? = nil) -> [Commit] {
        guard !finished, through > start else { return [] }
        // A callback queued before the microphone worker cut a segment can arrive after
        // the cut but before SpeakPipeline has advanced its preview floor.
        if let boundary, boundary.from < start { return [] }
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
    /// remainder contains less than the profile's 0.4 s of actual VAD speech.
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
            let cap = start + nanos(clipMaxS)
            let hard = audioEnd >= cap
            let due = hard || Double(HostClock.ms(start, to: audioEnd)) / 1000 >= profile.forceCut.sinceLastS
                || speechSeconds(through: audioEnd) * committer.charactersPerSecond >= Double(profile.forceCut.cjk)
            if due, (!forceOnly || hard) {
                let limit = min(cap, audioEnd)
                if let dip = latestDip(through: limit) {
                    if let c = commit(at: dip, reason: .forcedDip) { out.append(c) }
                    continue
                }
                if hard {
                    if let c = commit(at: energyCut(through: cap), reason: .hardCap) { out.append(c) }
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
            if HostClock.ms(lastStableAt, to: audioEnd) >= profile.boundary.stallMs { candidates.append((audioEnd, .stall)) }
            guard let candidate = candidates.sorted(by: { $0.0 < $1.0 }).first(where: { cut, _ in
                let onset = frames.first(where: { $0.speech && $0.start < cut })?.start ?? cut
                return committer.allows(speechS: speechSeconds(through: cut),
                    sinceOnsetS: Double(HostClock.ms(onset, to: cut)) / 1000, cutAt: cut,
                    previewCharacters: previewCharacters, previewThrough: previewThrough)
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
        guard releaseThrough == nil, let evidence = shortPreview,
              evidence.from >= start, evidence.through <= audioEnd,
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

    private func latestDip(through end: HostTime) -> HostTime? {
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
        return cuts.last { $0 > start && speechSeconds(through: $0) >= profile.release.commitRemainderMinSpeechS }
    }

    private func energyCut(through end: HostTime) -> HostTime {
        let window = UInt64(max(1, profile.forceCut.minEnergyWindowMs)) * 1_000_000
        var best: (energy: Double, cut: HostTime)?
        for frame in frames where frame.start >= start && frame.start < end {
            let lo = frame.start, hi = min(end, lo + window)
            guard hi - lo == window else { continue }
            let cut = lo + window / 2
            // Do not repeatedly select the silent pre-roll and generate tiny empty clips.
            guard speechSeconds(through: cut) >= profile.release.commitRemainderMinSpeechS else { continue }
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
        let seconds = speechSeconds(through: end)
        let result = Commit(start: start, end: end, index: index, speechMs: Int((seconds * 1000).rounded()),
                            isFinalChunk: final, reason: reason)
        start = end
        frames.removeAll { $0.end <= end }
        if !frames.isEmpty, frames[0].start < end { frames[0].start = end }
        stable = ""; previewCharacters = nil; previewThrough = nil; punctuationAt = nil; finalThrough = nil
        shortPreview = nil
        lastStableAt = end
        guard seconds + 1e-9 >= profile.release.commitRemainderMinSpeechS else { return nil }
        index += 1
        return result
    }

    private func nanos(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) * 1_000_000_000) }
}
