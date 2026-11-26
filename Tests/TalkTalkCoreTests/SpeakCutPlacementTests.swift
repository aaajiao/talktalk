import Foundation
import Testing
@testable import TalkTalkCore

/// Where SPEAK cuts land relative to speech (ARCHITECTURE §5.2): never inside voicing when a
/// pause will do, and never a sub-minimum head that waits out the forced-cut timer alone.
/// Frames are 20 ms; layouts are invented.
struct SpeakCutPlacementTests {
    private func ns(_ seconds: Double) -> HostTime { UInt64(seconds * 1e9) }
    private func t(_ frame: Int) -> HostTime { ns(Double(frame) * 0.02) }
    private func near(_ time: HostTime?, _ seconds: Double) -> Bool {
        guard let time else { return false }
        return abs(Int64(bitPattern: time) - Int64(bitPattern: ns(seconds))) < 1_000_000
    }
    private func profile(stallMs: Int? = nil) throws -> PolicyProfile.Speak {
        var profile = try TestResources.profile().speak
        if let stallMs { profile.boundary.stallMs = stallMs }
        return profile
    }
    private func feed(_ s: inout SpeakSegmenter, _ frames: Range<Int>, speech: (Int) -> Bool,
                      energy: ((Int) -> Double)? = nil) -> [(frame: Int, commit: SpeakSegmenter.Commit)] {
        var out: [(frame: Int, commit: SpeakSegmenter.Commit)] = []
        for i in frames {
            let voiced = speech(i)
            for c in s.audio(.init(start: t(i), end: t(i + 1), speech: voiced, energy: energy?(i) ?? (voiced ? 1 : 0))) {
                out.append((i, c))
            }
        }
        return out
    }

    @Test func stallCutsOnlyAtAPauseThatSpeechHasResumedAfter() throws {
        // No preview: the stall is armed from 1 s, but continuous speech is never cut.
        var held = SpeakSegmenter(profile: try profile(), target: .en, start: 0)
        #expect(feed(&held, 0..<150) { _ in true }.isEmpty)

        // A 160 ms pause after a clause is cut once 0.4 s of speech follows it.
        var resumed = SpeakSegmenter(profile: try profile(), target: .en, start: 0)
        let cut = feed(&resumed, 0..<130) { $0 < 90 || $0 >= 98 }
        #expect(cut.count == 1 && (117...118).contains(cut[0].frame))
        #expect(cut[0].commit.reason == .stall && near(cut[0].commit.end, 1.88) && cut[0].commit.speechMs == 1800)

        // A pause still open at the end waits for vadSilenceMs.
        var trailing = SpeakSegmenter(profile: try profile(), target: .en, start: 0)
        let closed = feed(&trailing, 0..<140) { $0 < 115 }
        #expect(closed.count == 1 && closed[0].frame == 132)
        #expect(closed[0].commit.reason == .silence && near(closed[0].commit.end, 2.48))

        // After a forced cut back to an early pause, the remainder is not cut at once mid-speech.
        var forced = SpeakSegmenter(profile: try profile(), target: .en, start: 0)
        let cuts = feed(&forced, 0..<270) { $0 < 65 || (92..<240).contains($0) || $0 >= 248 }.map(\.commit)
        #expect(cuts.map(\.reason) == [.forcedDip, .clauseDip])
        #expect(near(cuts.first?.end, 1.57) && near(cuts.last?.end, 4.88) && near(cuts.last?.speechEnd, 4.8))
        // Both cuts end in a pause, not on a voiced frame.
        for cut in cuts { #expect(cut.speechEnd.map { $0 < cut.end } ?? true) }
    }

    @Test func shortLastWordAfterABriefPauseStaysInACommittedClip() throws {
        // A clause, a 300 ms or 160 ms pause, a last word under 0.4 s, then key-up: no speech is dropped.
        let cases: [(layout: (Int) -> Bool, keyUp: Int, speechMs: Int)] = [
            ({ $0 < 130 || (145..<160).contains($0) }, 180, 2900),
            ({ $0 < 100 || (108..<120).contains($0) }, 150, 2240),
        ]
        for c in cases {
            for stallMs in [10_000, 1_000] {
                var s = SpeakSegmenter(profile: try profile(stallMs: stallMs), target: .en, start: 0)
                var cuts = feed(&s, 0..<c.keyUp, speech: c.layout).map(\.commit)
                cuts += s.release(at: t(c.keyUp))
                cuts += feed(&s, c.keyUp..<(c.keyUp + 20), speech: c.layout).map(\.commit)
                #expect(s.finished && cuts.reduce(0) { $0 + $1.speechMs } == c.speechMs)
            }
        }
    }

    @Test func forcedCutKeepsAShortHeadWithItsClause() throws {
        let profile = try profile(stallMs: 10_000)
        // 600 ms head, a 540 ms pause, then a clause: the forced cut waits for the clause's own pause.
        var head = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let merged = feed(&head, 0..<215) { $0 < 30 || (57..<198).contains($0) }
        #expect(merged.count == 1 && merged[0].frame == 205)
        #expect(merged[0].commit.reason == .forcedDip && near(merged[0].commit.end, 4.04))
        #expect(merged[0].commit.speechMs == 3420)

        // Without a later pause the head stays with its clause up to the cap's energy minimum.
        var unbroken = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let capped = feed(&unbroken, 0..<240) { $0 < 30 || $0 >= 57 }.map(\.commit)
        #expect(capped.count == 1 && capped[0].reason == .hardCap)
        #expect(capped[0].end == t(222) + 25_000_000 && capped[0].speechMs == 3925)

        // A quiet window early in the press does not become a 0.7 s hard-cap clip.
        var quietEarly = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let energy = feed(&quietEarly, 0..<232, speech: { _ in true },
                          energy: { (35...37).contains($0) ? 0.01 : 1 }).map(\.commit)
        #expect(energy.count == 1 && energy[0].reason == .hardCap && energy[0].end == t(222) + 25_000_000)

        // A sparse segment that never reaches the commit minimum keeps the 0.4 s floor at 4 s.
        var sparse = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let lone = feed(&sparse, 0..<215) { $0 < 36 }
        #expect(lone.count == 1 && lone[0].frame == 199)
        #expect(lone[0].commit.reason == .forcedDip && near(lone[0].commit.end, 2.36) && lone[0].commit.speechMs == 720)
    }

    @Test func forcedHeadFollowsTheTargetCommitMinimum() throws {
        let profile = try profile(stallMs: 10_000)
        let layout: (Int) -> Bool = { $0 < 65 || $0 >= 92 }
        var english = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let en = feed(&english, 0..<240, speech: layout).map(\.commit)
        #expect(en.first?.reason == .forcedDip && near(en.first?.end, 1.57))
        // 1.3 s of speech is below the German 1.5 s minimum.
        var german = SpeakSegmenter(profile: profile, target: .de, start: 0)
        let de = feed(&german, 0..<240, speech: layout).map(\.commit)
        #expect(de.count == 1 && de[0].reason == .hardCap && de[0].end == t(222) + 25_000_000)
    }

    @Test func forcedCutWaitsForAPauseThatJustOpened() throws {
        let profile = try profile(stallMs: 10_000)
        let layout: (Int) -> Bool = { $0 < 80 || (95..<199).contains($0) }
        var opening = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let waited = feed(&opening, 0..<225, speech: layout)
        #expect(waited.count == 1 && waited[0].frame == 206)
        #expect(waited[0].commit.reason == .forcedDip && near(waited[0].commit.end, 4.06))
        #expect(waited[0].commit.speechMs == 3680)
        // Speech resumes before the pause reaches dipMs: the older pause is taken on that frame.
        var resumed = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let back = feed(&resumed, 0..<225) { layout($0) || $0 >= 203 }
        #expect(back.first?.frame == 203 && back.first?.commit.reason == .forcedDip && near(back.first?.commit.end, 1.75))
    }

    @Test func clausePauseCommitsFromClauseDipAfterS() throws {
        let profile = try profile(stallMs: 10_000)
        let layout: (Int) -> Bool = { $0 < 100 || $0 >= 108 }
        // A 160 ms pause after a 2 s clause is cut once the segment is 2.5 s old and 0.4 s of
        // speech follows it, not at 4 s.
        var clause = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let early = feed(&clause, 0..<130, speech: layout)
        #expect(early.count == 1 && (127...128).contains(early[0].frame))
        #expect(early[0].commit.reason == .clauseDip && near(early[0].commit.end, 2.08) && early[0].commit.speechMs == 2000)
        // A caught-up preview with too few characters vetoes it; the forced cut still takes the pause at 4 s.
        var vetoed = SpeakSegmenter(profile: profile, target: .en, start: 0)
        var cuts = feed(&vetoed, 0..<110, speech: layout).map(\.commit)
        cuts += vetoed.preview(stableText: "abc", through: t(110), at: t(110))
        cuts += feed(&vetoed, 110..<205, speech: layout).map(\.commit)
        #expect(cuts.count == 1 && cuts[0].reason == .forcedDip && near(cuts[0].end, 2.08))
    }

    @Test func leadingSilenceDoesNotStartTheForcedOrCapClocks() throws {
        let profile = try profile(stallMs: 10_000)
        // 2.2 s of silence, then 2.72 s of speech: the hard cap no longer lands inside it.
        var s = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let cuts = feed(&s, 0..<270) { (110..<246).contains($0) }
        #expect(cuts.count == 1 && cuts[0].frame == 263)
        let cut = cuts[0].commit
        // The clip keeps 1 s of audio before the first voiced frame, for a soft onset VAD missed.
        #expect(cut.reason == .silence && near(cut.start, 1.2) && near(cut.end, 5.10))
        #expect(cut.speechMs == 2720 && cut.speechStart == t(110))

        // The head-and-clause and unbroken layouts after 2 s of silence: the forced cut and the
        // cap count from 300 ms before the first word, and the clip still stays within 4.5 s.
        var head = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let merged = feed(&head, 0..<315) { (100..<130).contains($0) || (157..<298).contains($0) }
        #expect(merged.count == 1 && merged[0].frame == 305)
        #expect(merged[0].commit.reason == .forcedDip && near(merged[0].commit.end, 6.04))
        #expect(merged[0].commit.speechMs == 3420 && near(merged[0].commit.start, 1.54))
        var unbroken = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let capped = feed(&unbroken, 0..<320) { (100..<130).contains($0) || $0 >= 157 }.map(\.commit)
        #expect(capped.count == 1 && capped[0].reason == .hardCap && capped[0].end == t(307) + 25_000_000)
        #expect(capped[0].speechMs == 3625 && capped[0].end - capped[0].start == 4_500_000_000)
    }

    @Test func caughtUpCharactersCloseAShortClauseAtASilence() throws {
        let profile = try profile(stallMs: 10_000)
        func run(speechFrames: Int, text: String, through: Int, frames: Range<Int>,
                 target: Lang = .en) -> [SpeakSegmenter.Commit] {
            var s = SpeakSegmenter(profile: profile, target: target, start: 0)
            var cuts = feed(&s, 0..<(speechFrames + 1)) { $0 < speechFrames }.map(\.commit)
            cuts += s.preview(stableText: text, through: t(through), at: t(speechFrames + 1),
                              boundary: .init(from: 0, fullyStable: true))
            return cuts + feed(&s, frames) { $0 < speechFrames }.map(\.commit)
        }
        // 0.7 s of speech, 9 ideographs covering it: commits at 350 ms of silence, not at 4 s.
        let cut = run(speechFrames: 35, text: "明天下午三点开会吧", through: 35, frames: 36..<60)
        #expect(cut.count == 1 && cut[0].reason == .textSilence && near(cut[0].end, 0.88))
        #expect(cut[0].speechMs == 700 && cut[0].previewCjk == 9)
        // A 1.4 s head passes the speech minimum but not the 8-character estimate.
        let head = run(speechFrames: 70, text: "明天下午三点开会吧", through: 70, frames: 71..<95)
        #expect(head.count == 1 && head[0].reason == .textSilence && near(head[0].end, 1.58))
        // A German target needs 10 ideographs.
        #expect(run(speechFrames: 35, text: "明天下午三点开会吧", through: 35, frames: 36..<190, target: .de).isEmpty)
        let german = run(speechFrames: 35, text: "明天下午三点钟开会吧", through: 35, frames: 36..<60, target: .de)
        #expect(german.count == 1 && german[0].reason == .textSilence && german[0].previewCjk == 10)
        // Too few ideographs, a preview that has not reached the last word, Latin letters, or
        // less than the 0.4 s release floor of speech: the clause still waits.
        for (frames, text, through) in [(35, "明天下午开会", 35), (35, "明天下午三点开会吧", 20),
                                        (35, "see you at three", 35), (15, "明天下午三点开会吧", 15)] {
            #expect(run(speechFrames: frames, text: text, through: through, frames: (frames + 1)..<190).isEmpty)
        }
        // After a dropped voiced blip the text may hold its words, so the clause waits for the forced cut.
        var dropped = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let blip: (Int) -> Bool = { $0 < 10 || (300..<335).contains($0) }
        var late = feed(&dropped, 0..<336, speech: blip).map(\.commit)
        late += dropped.preview(stableText: "明天下午三点开会吧", through: t(335), at: t(336),
                                boundary: .init(from: 0, fullyStable: true))
        late += feed(&dropped, 336..<490, speech: blip).map(\.commit)
        #expect(late.count == 1 && late[0].reason == .forcedDip)
    }

    @Test func shortLastWordAfterATextSilenceCutIsKept() throws {
        let profile = try profile(stallMs: 10_000)
        // A 0.7 s clause with 8 ideographs, a 400 ms pause, then (by default) a 0.3 s last word.
        let word: (Int) -> Bool = { (55..<70).contains($0) }
        func run(_ text: String?, through: Int = 70, latched: Bool = false, keyUp: Int = 80,
                 tail: @escaping (Int) -> Bool = word) -> [SpeakSegmenter.Commit] {
            let layout: (Int) -> Bool = { $0 < 35 || tail($0) }
            var s = SpeakSegmenter(profile: profile, target: .en, start: 0)
            var cuts = feed(&s, 0..<36, speech: layout).map(\.commit)
            cuts += s.preview(stableText: "明天下午三点开会", through: t(35), at: t(36),
                              boundary: .init(from: 0, fullyStable: true))
            cuts += feed(&s, 36..<70, speech: layout).map(\.commit)
            if let text, let floor = cuts.first?.end {
                cuts += s.preview(stableText: text, through: t(through), at: t(70),
                                  boundary: .init(from: floor, fullyStable: true))
            }
            if latched { return cuts + feed(&s, 70..<275, speech: layout).map(\.commit) }
            cuts += feed(&s, 70..<keyUp, speech: layout).map(\.commit)
            cuts += s.release(at: t(keyUp))
            return cuts + feed(&s, keyUp..<(keyUp + 10), speech: layout).map(\.commit)
        }
        // Key-up: the preview reopens at the cut and stops at key-up, so a remainder that ends
        // before the clause's forced cut would have come due is kept whatever it has shown.
        for text in ["好吗", "嗯", nil] as [String?] {
            let released = run(text)
            #expect(released.map(\.reason) == [.textSilence, .release] && near(released.first?.end, 0.88))
            #expect(released.first?.keptBelowFloor == false && released.last?.keptBelowFloor == true)
            #expect(released.last?.speechMs == 300 && released.last?.isFinalChunk == true)
        }
        // A 60 ms voiced run is enough; a single voiced frame (a key click) or a key-up after
        // that forced cut would have come due is not, without a covering preview.
        #expect(run(nil, tail: { (60..<63).contains($0) }).last?.speechMs == 60)
        #expect(run(nil, tail: { $0 == 60 }).map(\.reason) == [.textSilence])
        #expect(run(nil, keyUp: 205).map(\.reason) == [.textSilence])
        #expect(run("好吗", keyUp: 205).map(\.reason) == [.textSilence, .release])
        // Hands-free: no release, so the covering preview decides at the cap.
        let latched = run("好吗", latched: true)
        #expect(latched.map(\.reason) == [.textSilence, .hardCap] && latched.last?.speechMs == 300)
        #expect(latched.last?.keptBelowFloor == true)
        // One ideograph, only fillers, a preview short of the word, or no preview: dropped there.
        for (text, through) in [("嗯", 70), ("那个", 70), ("好吗", 55), (nil, 70)] as [(String?, Int)] {
            #expect(run(text, through: through, latched: true).map(\.reason) == [.textSilence])
        }
    }

    @Test func shortLastWordAfterAnAudioSilenceCutNeedsItsPreview() throws {
        let profile = try profile(stallMs: 10_000)
        // A 1.9 s clause passes the commit test at its silence; a 0.3 s last word follows it.
        let layout: (Int) -> Bool = { $0 < 95 || (120..<135).contains($0) }
        func run(word: String?) -> [SpeakSegmenter.Commit] {
            var s = SpeakSegmenter(profile: profile, target: .en, start: 0)
            var cuts = feed(&s, 0..<135, speech: layout).map(\.commit)
            if let word, let floor = cuts.first?.end {
                cuts += s.preview(stableText: word, through: t(135), at: t(135),
                                  boundary: .init(from: floor, fullyStable: true))
            }
            cuts += feed(&s, 135..<145, speech: layout).map(\.commit)
            cuts += s.release(at: t(145))
            return cuts + feed(&s, 145..<155, speech: layout).map(\.commit)
        }
        #expect(run(word: nil).map(\.reason) == [.silence])
        let kept = run(word: "好吗")
        #expect(kept.map(\.reason) == [.silence, .release] && kept.last?.speechMs == 300)
        #expect(kept.last?.keptBelowFloor == true)
    }

    @Test func droppedSegmentLeavesThePreviewWithTheNextClause() throws {
        var s = SpeakSegmenter(profile: try profile(stallMs: 10_000), target: .en, start: 0)
        let layout: (Int) -> Bool = { $0 < 100 || (150..<160).contains($0) || (400..<500).contains($0) }
        let first = try #require(feed(&s, 0..<130, speech: layout).first?.commit)
        #expect(first.reason == .silence && near(first.end, 2.18))
        let stale = SpeakPreviewBoundary(from: first.end - 2_000_000, fullyStable: true)
        // The 0.2 s blip is dropped at the cap; the pipeline's preview still starts at `first.end`.
        var cuts = feed(&s, 130..<200, speech: layout).map(\.commit)
        cuts += s.preview(stableText: "旧的。", through: t(200), at: t(200), boundary: stale)
        cuts += feed(&s, 200..<501, speech: layout).map(\.commit)
        #expect(cuts.isEmpty)
        cuts += s.preview(stableText: "旧的。", through: t(500), at: t(501), boundary: stale)
        cuts += s.preview(stableText: "我们下周一开会讨论这个方案。", through: t(500), at: t(501),
                          boundary: .init(from: first.end, fullyStable: true))
        cuts += feed(&s, 501..<530, speech: layout).map(\.commit)
        #expect(cuts.count == 1 && cuts[0].reason == .punctuation && cuts[0].end == t(500))
        // The clip starts at the dropped segment's cap cut; both late updates are counted.
        #expect(near(cuts[0].start, 7.2) && cuts[0].previewsIgnored == 2 && cuts[0].previewCjk == 13)
    }
}
