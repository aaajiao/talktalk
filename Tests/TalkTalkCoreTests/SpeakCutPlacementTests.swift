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
    private func feed(_ s: inout SpeakSegmenter, _ frames: Range<Int>, faint: (Int) -> Bool = { _ in false },
                      speech: (Int) -> Bool,
                      energy: ((Int) -> Double)? = nil) -> [(frame: Int, commit: SpeakSegmenter.Commit)] {
        var out: [(frame: Int, commit: SpeakSegmenter.Commit)] = []
        for i in frames {
            let voiced = speech(i)
            for c in s.audio(.init(start: t(i), end: t(i + 1), speech: voiced, energy: energy?(i) ?? (voiced ? 1 : 0),
                                   faint: faint(i))) {
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

    /// Feeds a layout with its faint frames and again without them. The faint lead never moves a cut
    /// or its speech facts; it only starts the clip at or before the plain one.
    private func feedBoth(_ frames: Range<Int>, start: HostTime = 0, trustsFaint: Bool = true,
                           faint: (Int) -> Bool, speech: (Int) -> Bool) throws -> [(frame: Int, commit: SpeakSegmenter.Commit)] {
        let profile = try profile()
        var with = SpeakSegmenter(profile: profile, target: .en, start: start, trustsFaint: trustsFaint)
        var plain = SpeakSegmenter(profile: profile, target: .en, start: start)
        let cuts = feed(&with, frames, faint: faint, speech: speech), old = feed(&plain, frames, speech: speech)
        #expect(cuts.map(\.frame) == old.map(\.frame))
        for (new, old) in zip(cuts.map(\.commit), old.map(\.commit)) {
            #expect(new.end == old.end && new.reason == old.reason && new.speechMs == old.speechMs)
            #expect(new.speechStart == old.speechStart && new.start <= old.start)
        }
        return cuts
    }

    @Test func faintLeadBeforeTheFirstVoicedFrameStaysInTheClip() throws {
        // A soft start 0.3 s before the first voiced frame: the clip keeps it from 300 ms before it.
        let soft = try feedBoth(0..<260, faint: { (40..<105).contains($0) }) { (120..<220).contains($0) }
        #expect(soft.count == 1 && soft[0].frame == 237)
        let clip = soft[0].commit
        #expect(clip.reason == .silence && near(clip.start, 0.5) && near(clip.end, 4.58))
        #expect(clip.speechMs == 2000 && clip.speechStart == t(120))
        #expect(clip.faintLeadMs == 1300 && clip.faintCutMs == 0 && clip.faintTrimmedMs == 0)
        var plain = SpeakSegmenter(profile: try profile(), target: .en, start: 0)
        let old = feed(&plain, 0..<260) { (120..<220).contains($0) }
        #expect(near(old.first?.commit.start, 1.4) && old.first?.commit.faintLeadMs == 0)
        // Speaker mode keeps the 1 s rule; the faint audio it leaves out is counted.
        let speaker = try feedBoth(0..<260, trustsFaint: false, faint: { (40..<105).contains($0) }) { (120..<220).contains($0) }
        #expect(near(speaker.first?.commit.start, 1.4) && speaker.first?.commit.faintLeadMs == 700)
        #expect(speaker.first?.commit.faintTrimmedMs == 600)

        // Runs less than 1 s apart chain; a 1.1 s gap breaks the chain, 40 ms blips never anchor it,
        // and a chain ending more than 1 s before the first voiced frame is stale.
        for (frames, faint, speech, frame, start) in [
            (0..<260, { (20..<45).contains($0) || (80..<100).contains($0) }, { (115..<215).contains($0) }, 232, 0.10),
            (0..<270, { (20..<45).contains($0) || (100..<120).contains($0) }, { (130..<230).contains($0) }, 247, 1.60),
            (0..<260, { $0 < 115 && $0 % 10 < 2 }, { (120..<220).contains($0) }, 237, 1.40),
            (0..<290, { (40..<90).contains($0) }, { (150..<250).contains($0) }, 267, 2.00),
        ] as [(Range<Int>, (Int) -> Bool, (Int) -> Bool, Int, Double)] {
            let cuts = try feedBoth(frames, faint: faint, speech: speech)
            #expect(cuts.map(\.frame) == [frame] && near(cuts.first?.commit.start, start), "start \(start)")
        }
        // A long faint chain keeps at most 2.5 s before the newest audio.
        let long = try feedBoth(0..<330, faint: { $0 < 200 }) { (200..<290).contains($0) }
        #expect(long.map(\.frame) == [307] && near(long.first?.commit.start, 1.5) && near(long.first?.commit.end, 5.98))
        #expect(long.first?.commit.faintLeadMs == 2500 && long.first?.commit.faintTrimmedMs == 1500)
        // Never before the segment start (the press floor): build 98 started at 1.50 s.
        let floor = try feedBoth(0..<250, start: ns(1), faint: { (55..<120).contains($0) }) { (125..<230).contains($0) }
        #expect(floor.map(\.frame) == [247] && floor.first?.commit.start == ns(1) && near(floor.first?.commit.end, 4.78))
        #expect(floor.first?.commit.faintLeadMs == 1300)
        // After an emitted cut, the next clip's faint lead starts after it (build 98: 5.80 s).
        let second = try feedBoth(0..<520, faint: { (250..<262).contains($0) || (290..<330).contains($0) }) {
            (20..<200).contains($0) || (340..<440).contains($0)
        }
        #expect(second.map(\.frame) == [207, 457] && second.map(\.commit.reason) == [.forcedDip, .silence])
        #expect(second.first?.commit.start == 0 && near(second.first?.commit.end, 4.08))
        #expect(near(second.last?.commit.start, 4.7) && near(second.last?.commit.end, 8.98))
        #expect(second.last?.commit.faintLeadMs == 1040)
        // Faint audio left out before a dropped blip is reported on the next emitted clip, then reset.
        let carried = try feedBoth(0..<730, faint: { $0 < 150 }) {
            (150..<160).contains($0) || (400..<500).contains($0) || (600..<700).contains($0)
        }
        #expect(carried.map(\.commit.reason) == [.silence, .silence] && near(carried.first?.commit.start, 7.2))
        #expect(carried.first?.commit.droppedSpeechMs == 200 && carried.map(\.commit.faintTrimmedMs) == [500, 0])
    }

    @Test func faintLeadNeverMovesTheClockOrCountsAsSpeech() throws {
        // Continuous speech after a faint lead: the cap still counts from 300 ms before the first voiced
        // frame, and the 4.5 s clip bound trims the faint lead (a clock anchored on it would cap near 5.0 s).
        let capped = try feedBoth(0..<360, faint: { (40..<105).contains($0) }) { (120..<360).contains($0) }
        #expect(capped.map(\.frame) == [329])
        let clip = try #require(capped.first?.commit)
        #expect(clip.reason == .hardCap && clip.end == t(327) + 25_000_000 && clip.end - clip.start == 4_500_000_000)
        #expect(clip.speechStart == t(120) && clip.faintLeadMs == 35 && clip.faintCutMs == 1265)
        // 0.3 s of speech with a faint tail stays under the release floor: dropped on release, and at the cap.
        let layout: (Int) -> Bool = { $0 < 15 }, tail: (Int) -> Bool = { (15..<60).contains($0) }
        var released = SpeakSegmenter(profile: try profile(), target: .en, start: 0)
        var cuts = feed(&released, 0..<80, faint: tail, speech: layout).map(\.commit)
        cuts += released.release(at: t(80))
        #expect(released.finished && cuts.isEmpty)
        var held = SpeakSegmenter(profile: try profile(), target: .en, start: 0)
        #expect(feed(&held, 0..<300, faint: tail, speech: layout).isEmpty)
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
        let german = run(speechFrames: 35, text: "明天下午三点钟开会吧", through: 35, frames: 36..<60, target: .de)
        #expect(german.count == 1 && german[0].reason == .textSilence && german[0].previewCjk == 10)
        // Too few ideographs for the character minimum: the clause closes once 1 s of quiet is captured.
        for (text, target) in [("明天下午三点开会吧", Lang.de), ("明天下午开会", .en)] {
            #expect(run(speechFrames: 35, text: text, through: 35, frames: 36..<84, target: target).isEmpty)
            let pause = run(speechFrames: 35, text: text, through: 35, frames: 36..<190, target: target)
            #expect(pause.map(\.reason) == [.longSilence] && near(pause.first?.end, 1.2))
        }
        // A preview that has not reached the last word, or Latin letters: the clause still waits.
        for (text, through) in [("明天下午三点开会吧", 20), ("see you at three", 35)] {
            #expect(run(speechFrames: 35, text: text, through: through, frames: 36..<190).isEmpty)
        }
        // Under the 0.4 s release floor of speech the character minimum does not close it at 350 ms;
        // the long pause does at 1 s, below the floor (build 99 waited for the 4.5 s cap).
        #expect(run(speechFrames: 15, text: "明天下午三点开会吧", through: 15, frames: 16..<64).isEmpty)
        let soft = run(speechFrames: 15, text: "明天下午三点开会吧", through: 15, frames: 16..<190)
        #expect(soft.map(\.reason) == [.longSilence] && near(soft.first?.end, 0.8))
        #expect(soft.first?.keptBelowFloor == true && soft.first?.speechMs == 300)
        // After a dropped voiced blip the text may hold its words, so the clause waits for the forced cut.
        var dropped = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let blip: (Int) -> Bool = { $0 < 10 || (300..<335).contains($0) }
        var late = feed(&dropped, 0..<336, speech: blip).map(\.commit)
        late += dropped.preview(stableText: "明天下午三点开会吧", through: t(335), at: t(336),
                                boundary: .init(from: 0, fullyStable: true))
        late += feed(&dropped, 336..<490, speech: blip).map(\.commit)
        #expect(late.count == 1 && late[0].reason == .forcedDip)
    }

    @Test func longPauseClosesAShortPhraseItsPreviewShows() throws {
        let profile = try profile(stallMs: 10_000)
        // `speech` voiced frames, then quiet; the preview arrives one frame after the last voiced one.
        func run(_ text: String?, through: Int? = nil, speech: Int = 30, target: Lang = .en,
                 feeds: [Range<Int>]? = nil) -> [(frame: Int, commit: SpeakSegmenter.Commit)] {
            var s = SpeakSegmenter(profile: profile, target: target, start: 0)
            var cuts = feed(&s, 0..<(speech + 1)) { $0 < speech }
            if let text {
                cuts += s.preview(stableText: text, through: t(through ?? speech), at: t(speech + 1),
                                  boundary: .init(from: 0, fullyStable: true)).map { (speech, $0) }
            }
            for range in feeds ?? [(speech + 1)..<230] { cuts += feed(&s, range) { $0 < speech } }
            return cuts
        }
        // 0.6 s of speech, 4 ideographs covering it: commits at 1 s of captured quiet, not at 4 s.
        for target in [Lang.en, .de] {
            let cuts = run("明天开会", target: target)
            #expect(cuts.map(\.frame) == [79] && cuts.first?.commit.reason == .longSilence)
            let cut = try #require(cuts.first?.commit)
            #expect(near(cut.end, 1.1) && cut.speechMs == 600 && cut.previewCjk == 4 && !cut.keptBelowFloor)
        }
        // No preview, only fillers, one ideograph beyond them, a preview short of the last voiced
        // frame, Latin letters, or text the recognizer hears going on: the forced cut takes the pause.
        for (text, through) in [(nil, 30), ("那个嗯", 30), ("嗯好", 30), ("明天开会", 15), ("see you", 30),
                                ("明天开会，", 30), ("明天开会...", 30)] as [(String?, Int)] {
            let forced = run(text, through: through)
            #expect(forced.map(\.frame) == [199] && forced.first?.commit.reason == .forcedDip)
            #expect(near(forced.first?.commit.end, 2.3))
        }
        // Under the 0.4 s release floor the covering preview closes it the same way and keeps it
        // (build 99 waited for the 4.5 s cap and cut there).
        let short = run("好吗", speech: 15)
        #expect(short.map(\.frame) == [64] && short.first?.commit.reason == .longSilence)
        let kept = try #require(short.first?.commit)
        #expect(near(kept.end, 0.8) && kept.keptBelowFloor && kept.speechMs == 300 && kept.previewCjk == 2)
        // Soft speech the VAD hears only in part (build 99 meeting, clause 35): a faint stretch, 260 ms
        // voiced, then quiet. The clip closes at the long pause with its faint lead; the cap cut would
        // come 3.9 s later, and its 4.5 s bound would trim 300 ms of that lead.
        var soft = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let voiced: (Int) -> Bool = { (60..<73).contains($0) }
        let faint: (Int) -> Bool = { (30..<60).contains($0) || (73..<90).contains($0) }
        var softCuts = feed(&soft, 0..<91, faint: faint, speech: voiced)
        softCuts += soft.preview(stableText: "明天下午三点开会", through: t(90), at: t(91),
                                 boundary: .init(from: 0, fullyStable: true)).map { (90, $0) }
        softCuts += feed(&soft, 91..<300, faint: faint, speech: voiced)
        #expect(softCuts.map(\.frame) == [122] && softCuts.first?.commit.reason == .longSilence)
        let lead = try #require(softCuts.first?.commit)
        #expect(near(lead.start, 0.2) && near(lead.end, 1.96) && lead.keptBelowFloor && lead.speechMs == 260)
        #expect(lead.faintLeadMs == 600 && lead.faintCutMs == 0)
        // A 300 ms timestamp gap is no pause: 1 s of quiet must be captured after it. The cut
        // stays at the middle of the whole quiet span.
        let gap = run("明天开会", feeds: [31..<55, 70..<130])
        #expect(gap.map(\.frame) == [119] && gap.first?.commit.reason == .longSilence && near(gap.first?.commit.end, 1.5))
        // A 2 s clause the caught-up preview vetoes (4 < 8 characters) closes at the long pause,
        // not at the forced cut. The refreshed preview stays caught up with the pause.
        var vetoed = SpeakSegmenter(profile: profile, target: .en, start: 0)
        var closed: [(frame: Int, commit: SpeakSegmenter.Commit)] = []
        for i in 0..<230 {
            closed += feed(&vetoed, i..<(i + 1)) { $0 < 100 }
            if i >= 100 {
                closed += vetoed.preview(stableText: "明天开会", through: t(i + 1), at: t(i + 1),
                                         boundary: .init(from: 0, fullyStable: true)).map { (i, $0) }
            }
        }
        #expect(closed.map(\.frame) == [149] && closed.first?.commit.reason == .longSilence)
        #expect(near(closed.first?.commit.end, 2.5) && closed.first?.commit.speechMs == 2000)
        // After a dropped voiced blip the text may hold its words, so the phrase waits for the forced cut.
        var dropped = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let blip: (Int) -> Bool = { $0 < 10 || (300..<330).contains($0) }
        var late = feed(&dropped, 0..<331, speech: blip)
        late += dropped.preview(stableText: "明天开会", through: t(330), at: t(331),
                                boundary: .init(from: 0, fullyStable: true)).map { (330, $0) }
        late += feed(&dropped, 331..<500, speech: blip)
        #expect(late.map(\.frame) == [484] && late.first?.commit.reason == .forcedDip && near(late.first?.commit.end, 8.15))
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
        // Key-up: the preview reopens at the cut and stops at key-up, so a remainder voiced
        // before the clause's forced cut would have come due is kept whatever it has shown.
        for text in ["好吗", "嗯", nil] as [String?] {
            let released = run(text)
            #expect(released.map(\.reason) == [.textSilence, .release] && near(released.first?.end, 0.88))
            #expect(released.first?.keptBelowFloor == false && released.last?.keptBelowFloor == true)
            #expect(released.last?.speechMs == 300 && released.last?.isFinalChunk == true)
        }
        // A 60 ms voiced run is enough, also with a key-up after that forced cut would have come
        // due (4.0 s); a single voiced frame (a key click) or a word voiced only after it is not,
        // without a covering preview.
        #expect(run(nil, tail: { (60..<63).contains($0) }).last?.speechMs == 60)
        #expect(run(nil, tail: { $0 == 60 }).map(\.reason) == [.textSilence])
        #expect(run(nil, keyUp: 205).map(\.reason) == [.textSilence, .release])
        #expect(run(nil, keyUp: 230, tail: { (205..<220).contains($0) }).map(\.reason) == [.textSilence])
        // A covering preview closes the word at the long pause, before a late key-up and hands-free
        // without one (build 99 waited for the key-up or the cap).
        #expect(run("好吗", keyUp: 205).map(\.reason) == [.textSilence, .longSilence])
        let latched = run("好吗", latched: true)
        #expect(latched.map(\.reason) == [.textSilence, .longSilence] && latched.last?.speechMs == 300)
        #expect(latched.last?.keptBelowFloor == true && near(latched.last?.end, 1.9))
        // One ideograph, only fillers, a preview short of the word, or no preview: dropped there.
        for (text, through) in [("嗯", 70), ("那个", 70), ("好吗", 55), (nil, 70)] as [(String?, Int)] {
            #expect(run(text, through: through, latched: true).map(\.reason) == [.textSilence])
        }
    }

    /// `speech` and `faint` frames; `text` covers the clause through frame 35 (sent at frame 36) and,
    /// with `again`, through frame 75 (sent at frame 76); `keyUp` releases before that frame;
    /// `trustsFaint` false is speaker mode.
    private func faintRun(_ frames: Range<Int>, text: String? = "明天下午三点开会吧", again: Bool = false,
                          keyUp: Int? = nil, trustsFaint: Bool = true, faint: @escaping (Int) -> Bool,
                          speech: @escaping (Int) -> Bool = { $0 < 35 })
        throws -> (cuts: [(frame: Int, commit: SpeakSegmenter.Commit)], segmenter: SpeakSegmenter) {
        var s = SpeakSegmenter(profile: try profile(stallMs: 10_000), target: .en, start: 0, trustsFaint: trustsFaint)
        var cuts: [(frame: Int, commit: SpeakSegmenter.Commit)] = []
        for i in frames {
            if let text, i == 36 || (again && i == 76) {
                cuts += s.preview(stableText: text, through: t(i - 1), at: t(i),
                                  boundary: .init(from: 0, fullyStable: true)).map { (i, $0) }
            }
            if i == keyUp { cuts += s.release(at: t(i)).map { (i, $0) } }
            cuts += feed(&s, i..<(i + 1), faint: faint, speech: speech)
        }
        return (cuts, s)
    }

    @Test func textSilenceStaysClearOfFaintRuns() throws {
        // A 0.7 s clause whose 9 ideographs cover it; build 98 cut every layout here at the silence
        // midpoint, 0.88 s, on frame 52. Soft words VAD misses (faint 35..<60): the cut waits for 350 ms
        // of quiet after them and goes in its middle.
        let soft: (Int) -> Bool = { (35..<60).contains($0) }
        let held = try faintRun(0..<80, faint: soft).cuts
        #expect(held.map(\.frame) == [77])
        let clip = try #require(held.first?.commit)
        #expect(clip.reason == .textSilence && near(clip.end, 1.38) && clip.speechMs == 700 && clip.speechEnd == t(35))
        #expect(clip.faintTailMs == 500 && clip.faintHeldMs == 500 && !clip.faintHeldMerged)
        // Speaker mode does not trust faint frames: the cut stays at the midpoint, as in build 98; the
        // faint tail is still measured.
        let speaker = try faintRun(0..<80, trustsFaint: false, faint: soft).cuts
        #expect(speaker.map(\.frame) == [52] && speaker.first?.commit.reason == .textSilence)
        #expect(near(speaker.first?.commit.end, 0.88) && speaker.first?.commit.faintTailMs == 180)
        #expect(speaker.first?.commit.faintHeldMs == nil)
        // Remote speech leaking into the faint band after a clause whose text goes on ("，", so the
        // long-pause rule waits): trusted, it holds the cut to 1.88 s and pulls the leak into the clip.
        for trusts in [true, false] {
            let leak = try faintRun(0..<120, text: "明天下午三点开会，", trustsFaint: trusts, faint: { (38..<85).contains($0) }).cuts
            #expect(leak.map(\.frame) == [trusts ? 102 : 52] && leak.first?.commit.reason == .textSilence, "trusts \(trusts)")
            #expect(near(leak.first?.commit.end, trusts ? 1.88 : 0.88) && leak.first?.commit.faintHeldMs == (trusts ? 1000 : nil))
        }
        // Key-up during the soft words: one release clip holds them (build 98 dropped 0.88-1.20 s).
        let released = try faintRun(0..<70, keyUp: 60, faint: soft)
        #expect(released.segmenter.finished && released.cuts.map(\.frame) == [60])
        let tail = try #require(released.cuts.first?.commit)
        #expect(tail.reason == .release && tail.isFinalChunk && tail.start == 0 && near(tail.end, 1.2))
        #expect(tail.speechMs == 700 && !tail.keptBelowFloor && tail.faintTailMs == 500 && tail.faintHeldMs == 140)
        // Blips under 60 ms and up to 6 faint frames right after the clause (libfvad's hangover) cost
        // nothing: the midpoint stays 60 ms clear of them. Each further frame costs 40 ms.
        for (faint, frame, end, tailMs, heldMs) in [
            ({ [38, 39, 42].contains($0) }, 52, 0.88, 60, nil),
            ({ (35..<40).contains($0) }, 52, 0.88, 100, nil),
            ({ (35..<41).contains($0) }, 52, 0.88, 120, nil),
            ({ (35..<42).contains($0) }, 54, 0.90, 140, 40),
        ] as [((Int) -> Bool, Int, Double, Int, Int?)] {
            let cuts = try faintRun(0..<80, faint: faint).cuts
            #expect(cuts.map(\.frame) == [frame] && cuts.first?.commit.reason == .textSilence, "frame \(frame)")
            #expect(near(cuts.first?.commit.end, end) && cuts.first?.commit.faintTailMs == tailMs)
            #expect(cuts.first?.commit.faintHeldMs == heldMs)
        }
        // Speech resuming after the soft words: one clip (build 98 split them across two), marked merged.
        // The next clip (a word after it, kept on release) carries no hold.
        let resumed = try faintRun(0..<150, text: "明天下午三点开会好不好", again: true, keyUp: 140, faint: soft,
                                   speech: { $0 < 35 || (60..<75).contains($0) || (100..<130).contains($0) }).cuts
        #expect(resumed.map(\.frame) == [92, 142] && resumed.map(\.commit.reason) == [.textSilence, .release])
        #expect(near(resumed.first?.commit.end, 1.68) && resumed.first?.commit.speechMs == 1000)
        #expect(resumed.first?.commit.faintHeldMs == 800 && resumed.first?.commit.faintHeldMerged == true)
        #expect(resumed.last?.commit.faintHeldMs == nil && resumed.last?.commit.faintHeldMerged == false)
        // A forced cut back to the held pause after speech resumed: that clip is the short clause alone,
        // so it is not marked merged; the resumed speech is the next clip, with neither field.
        let back = try faintRun(0..<310, again: true, faint: { (77..<92).contains($0) },
                                speech: { $0 < 75 || (100..<300).contains($0) }).cuts
        #expect(back.map(\.frame) == [199, 307] && back.map(\.commit.reason) == [.forcedDip, .forcedDip])
        #expect(near(back.first?.commit.end, 1.75) && back.first?.commit.faintHeldMs == 2140)
        #expect(back.first?.commit.faintHeldMerged == false && back.last?.commit.faintHeldMerged == false)
        #expect(back.last?.commit.faintHeldMs == nil)
        // Faint audio that never ends (noise libfvad takes for voice): the long-pause rule, which treats
        // it as quiet, takes the held cut at the silence midpoint once 1 s of quiet is captured. Where
        // that rule waits too (text going on), the forced cut does, as in build 97.
        let capped = try faintRun(0..<230, faint: { $0 >= 35 }).cuts
        #expect(capped.map(\.frame) == [84] && capped.first?.commit.reason == .longSilence)
        #expect(near(capped.first?.commit.end, 1.2) && capped.first?.commit.faintTailMs == 500)
        #expect(capped.first?.commit.faintHeldMs == 640)
        let forced = try faintRun(0..<230, text: "明天下午三点开会吧，", faint: { $0 >= 35 }).cuts
        #expect(forced.map(\.frame) == [199] && forced.first?.commit.reason == .forcedDip)
        let fallback = try #require(forced.first?.commit)
        #expect(near(fallback.end, 2.35) && fallback.speechMs == 700 && fallback.faintTailMs == 1650)
        #expect(fallback.faintHeldMs == 2940 && !fallback.faintHeldMerged)
        // A breath in the faint band right after the clause counts as voice for the text cut: in a 500 ms
        // pause the clause merges with the next one (faintHeldMerged), in a 700 ms pause it is cut 340 ms
        // later, and a 60 ms blip at build 98's decision costs 360 ms.
        let breath: (Int) -> Bool = { (37..<52).contains($0) }
        let merged = try faintRun(0..<150, faint: breath, speech: { $0 < 35 || (60..<120).contains($0) }).cuts
        #expect(merged.map(\.frame) == [137] && merged.first?.commit.reason == .silence)
        #expect(near(merged.first?.commit.end, 2.58) && merged.first?.commit.speechMs == 1900)
        #expect(merged.first?.commit.faintHeldMs == 1700 && merged.first?.commit.faintHeldMerged == true)
        let later = try faintRun(0..<140, faint: breath, speech: { $0 < 35 || (70..<130).contains($0) }).cuts
        #expect(later.map(\.frame) == [69] && later.first?.commit.reason == .textSilence)
        #expect(near(later.first?.commit.end, 1.22) && later.first?.commit.faintHeldMs == 340)
        let blip = try faintRun(0..<90, faint: { (50..<53).contains($0) }).cuts
        #expect(blip.map(\.frame) == [70] && blip.first?.commit.reason == .textSilence)
        #expect(near(blip.first?.commit.end, 1.24) && blip.first?.commit.faintHeldMs == 360)
    }

    @Test func longSilenceDoesNotCutInsideAnEndedFaintRun() throws {
        // A 0.7 s clause whose 4 ideographs are under the character minimum, so only the long-pause rule
        // closes it, and soft words VAD misses (faint 50..<75) that end before its decision. The cut goes
        // in the middle of the quiet after them; the midpoint, 1.20 s, left 300 ms of them to key-up's drop.
        let soft: (Int) -> Bool = { (50..<75).contains($0) }
        let run = try faintRun(0..<100, text: "明天开会", keyUp: 95, faint: soft)
        #expect(run.cuts.map(\.frame) == [84] && run.cuts.first?.commit.reason == .longSilence)
        let clip = try #require(run.cuts.first?.commit)
        #expect(near(clip.end, 1.6) && clip.speechMs == 700 && clip.faintTailMs == 500)
        #expect(run.segmenter.finished && run.segmenter.faintOnlyDropped == 0)
        // A later faint run still going at the decision (78..<90) bounds that quiet: the cut stays before it.
        let bounded = try faintRun(0..<100, text: "明天开会", faint: { soft($0) || (78..<90).contains($0) }).cuts
        #expect(bounded.map(\.frame) == [84] && bounded.first?.commit.reason == .longSilence)
        #expect(near(bounded.first?.commit.end, 1.53))
        // A later run that has ended too (78..<82) is passed: the cut goes after it and nothing is dropped.
        let passed = try faintRun(0..<100, text: "明天开会", keyUp: 95, faint: { soft($0) || (78..<82).contains($0) })
        #expect(passed.cuts.map(\.frame) == [84] && passed.cuts.first?.commit.reason == .longSilence)
        #expect(near(passed.cuts.first?.commit.end, 1.67) && passed.segmenter.finished)
        #expect(passed.segmenter.faintOnlyDropped == 0)
        // The midpoint in an 80 ms gap inside the soft words (faint 35..<58 and 62..<75) is held too: the
        // cut goes after both runs (at the midpoint, 1.20 s, it left the second to key-up's drop).
        let gap = try faintRun(0..<100, text: "明天开会", keyUp: 95,
                               faint: { (35..<58).contains($0) || (62..<75).contains($0) })
        #expect(gap.cuts.map(\.frame) == [84] && gap.cuts.first?.commit.reason == .longSilence)
        #expect(near(gap.cuts.first?.commit.end, 1.6) && gap.segmenter.finished && gap.segmenter.faintOnlyDropped == 0)
        // With 9 ideographs and soft words in two ended runs, textSilence's point after both wins the tie
        // (stopping at the gap between them, 1.24 s, left the second run to key-up's drop).
        let pair = try faintRun(0..<100, keyUp: 95, faint: { (50..<61).contains($0) || (63..<67).contains($0) })
        #expect(pair.cuts.map(\.frame) == [84] && pair.cuts.first?.commit.reason == .textSilence)
        #expect(near(pair.cuts.first?.commit.end, 1.52) && pair.segmenter.finished)
        #expect(pair.segmenter.faintOnlyDropped == 0)
        // Speaker mode keeps the midpoint; the faint-only remainder is dropped and not counted.
        let speaker = try faintRun(0..<100, text: "明天开会", keyUp: 95, trustsFaint: false, faint: soft)
        #expect(speaker.cuts.map(\.frame) == [84] && speaker.cuts.first?.commit.reason == .longSilence)
        #expect(near(speaker.cuts.first?.commit.end, 1.2) && speaker.segmenter.finished)
        #expect(speaker.segmenter.faintOnlyDropped == 0)
        // 9 ideographs and faint 50..<67: both rules come due on frame 84 at the same point, the middle of
        // the quiet after the run; textSilence, listed first, wins the tie.
        let tie = try faintRun(0..<100, faint: { (50..<67).contains($0) }).cuts
        #expect(tie.map(\.frame) == [84] && tie.first?.commit.reason == .textSilence)
        #expect(near(tie.first?.commit.end, 1.52) && tie.first?.commit.faintTailMs == 340)
    }

    @Test func longPauseBelowTheFloorWaitsForSoftWords() throws {
        let profile = try profile(stallMs: 10_000)
        // Build 99 clause 35's shape (260 ms voiced at 60..<73, its text through 1.80 s) with soft words
        // after it. Under the floor only longSilence closes it at a pause, so its cut waits for faint
        // audio as textSilence's does; build 100 first cut at the 1.96 s midpoint inside them.
        func run(faint: @escaping (Int) -> Bool, keyUp: Int?)
            -> (cuts: [(frame: Int, commit: SpeakSegmenter.Commit)], segmenter: SpeakSegmenter) {
            var s = SpeakSegmenter(profile: profile, target: .en, start: 0)
            let voiced: (Int) -> Bool = { (60..<73).contains($0) }
            var cuts = feed(&s, 0..<91, faint: faint, speech: voiced)
            cuts += s.preview(stableText: "明天下午三点开会", through: t(90), at: t(91),
                              boundary: .init(from: 0, fullyStable: true)).map { (90, $0) }
            cuts += feed(&s, 91..<(keyUp ?? 300), faint: faint, speech: voiced)
            if let keyUp {
                cuts += s.release(at: t(keyUp)).map { (keyUp, $0) }
                cuts += feed(&s, keyUp..<(keyUp + 15), faint: faint, speech: voiced)
            }
            return (cuts, s)
        }
        // Still going at the 1 s decision (2.46 s) and ending at 2.80 s: the cut goes in the quiet after
        // them and records the hold (the midpoint cut left 1.96-2.80 s to a key-up at 3.40 s, which
        // dropped it); a key-up while they go on keeps the phrase whole.
        let going: (Int) -> Bool = { (73..<140).contains($0) }
        for keyUp in [170, nil] as [Int?] {
            let after = run(faint: going, keyUp: keyUp)
            #expect(after.cuts.map(\.frame) == [157] && after.cuts.first?.commit.reason == .longSilence)
            let clip = try #require(after.cuts.first?.commit)
            #expect(near(clip.start, 0.2) && near(clip.end, 2.98) && clip.keptBelowFloor && clip.speechMs == 260)
            #expect(clip.faintTailMs == 1340 && clip.faintHeldMs == 700 && !clip.faintHeldMerged)
            #expect(after.segmenter.faintOnlyDropped == 0)
        }
        let released = run(faint: going, keyUp: 130)
        #expect(released.cuts.map(\.commit.reason) == [.release])
        let whole = try #require(released.cuts.first?.commit)
        #expect(near(whole.start, 0.2) && near(whole.end, 2.6) && whole.keptBelowFloor && whole.faintTailMs == 1140)
        #expect(whole.faintHeldMs == 140)
        // Two runs 80 ms apart (73..<96, 100..<115): the cut goes in the quiet after the second (the
        // midpoint, in the gap, left the second to key-up's drop).
        let pair = run(faint: { (73..<96).contains($0) || (100..<115).contains($0) }, keyUp: 140)
        #expect(pair.cuts.map(\.frame) == [132] && pair.cuts.first?.commit.reason == .longSilence)
        #expect(near(pair.cuts.first?.commit.end, 2.48) && pair.segmenter.finished)
        #expect(pair.segmenter.faintOnlyDropped == 0)
        // Speaker mode keeps the midpoint, as before.
        var speaker = SpeakSegmenter(profile: profile, target: .en, start: 0, trustsFaint: false)
        var speakerCuts = feed(&speaker, 0..<91, faint: going, speech: { (60..<73).contains($0) })
        speakerCuts += speaker.preview(stableText: "明天下午三点开会", through: t(90), at: t(91),
                                       boundary: .init(from: 0, fullyStable: true)).map { (90, $0) }
        speakerCuts += feed(&speaker, 91..<300, faint: going, speech: { (60..<73).contains($0) })
        #expect(speakerCuts.map(\.frame) == [122] && near(speakerCuts.first?.commit.end, 1.96))
    }

    @Test func longPauseBelowTheFloorNeedsItsWordRecognizedByTheCut() throws {
        let profile = try profile(stallMs: 10_000)
        // A 60 ms click, then a preview through 4.28 s arriving before VAD fires on the next phrase
        // (4.44 s): its words come from that phrase's soft onset, so the click gets no clip of its own;
        // the cap restart drops it, as in build 99 (build 100 first kept it as longSilence 0-2.41 s).
        let click = try press({ (20..<23).contains($0) || (222..<300).contains($0) }, keyUp: 330,
                              preview: ("我们明天", 214, 218))
        #expect(click.map(\.reason) == [.release])
        #expect(near(click.first?.start, 3.44) && click.first?.droppedSpeechMs == 60 && click.first?.capRestart == true)
        // A voiced filler, then a preview through 1.90 s naming words of the phrase VAD hears from
        // 2.00 s: the filler stays with that phrase (build 100 first cut a filler-only clip at 1.08 s).
        var filler = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let layout: (Int) -> Bool = { $0 < 10 || (100..<160).contains($0) }
        var cuts = feed(&filler, 0..<11, speech: layout).map(\.commit)
        cuts += filler.preview(stableText: "嗯", through: t(10), at: t(11), boundary: .init(from: 0, fullyStable: true))
        cuts += feed(&filler, 11..<98, speech: layout).map(\.commit)
        cuts += filler.preview(stableText: "嗯我们明天", through: t(95), at: t(98), boundary: .init(from: 0, fullyStable: true))
        cuts += feed(&filler, 98..<180, speech: layout).map(\.commit)
        cuts += filler.release(at: t(180))
        cuts += feed(&filler, 180..<195, speech: layout).map(\.commit)
        #expect(cuts.map(\.reason) == [.release] && near(cuts.first?.start, 0) && cuts.first?.speechMs == 1400)
        // PTT: a 0.3 s phrase closed at its long pause, then a one-ideograph word voiced 4.00-4.20 s
        // after its clock, with no preview before key-up. The phrase's forced cut could not have cut
        // between them (it needs 0.4 s of speech before the dip), so the word is kept up to the phrase's
        // 4.5 s cap (build 100 first kept it only to 4.0 s and dropped it; build 99 merged the two).
        var word = SpeakSegmenter(profile: profile, target: .en, start: 0)
        let late: (Int) -> Bool = { $0 < 15 || (200..<210).contains($0) }
        var wordCuts = feed(&word, 0..<16, speech: late).map(\.commit)
        wordCuts += word.preview(stableText: "明天开会", through: t(15), at: t(16), boundary: .init(from: 0, fullyStable: true))
        wordCuts += feed(&word, 16..<220, speech: late).map(\.commit)
        wordCuts += word.release(at: t(220))
        wordCuts += feed(&word, 220..<235, speech: late).map(\.commit)
        #expect(wordCuts.map(\.reason) == [.longSilence, .release] && near(wordCuts.first?.end, 0.8))
        #expect(wordCuts.last?.keptBelowFloor == true && wordCuts.last?.speechMs == 200)
    }

    @Test func faintLeavesTheAudioSilenceCutAndFaintOnlyRemaindersAlone() throws {
        // The audio silence cut treats faint audio as quiet: a 1.9 s clause is still cut inside the
        // soft words after it, which faintTailMs shows.
        let silence = try faintRun(0..<140, text: nil, faint: { (95..<125).contains($0) }, speech: { $0 < 95 }).cuts
        #expect(silence.map(\.frame) == [112] && silence.first?.commit.reason == .silence)
        let clip = try #require(silence.first?.commit)
        #expect(near(clip.end, 2.08) && clip.speechMs == 1900 && clip.faintTailMs == 180 && clip.faintHeldMs == nil)
        // A faint-only remainder after a textSilence cut is still dropped at key-up (rule (a) needs a
        // voiced run) and counted, also when key-up comes more than 1 s after the soft words and the
        // leading-silence bound has already left them out; a 40 ms blip is not counted, in the remainder
        // or left out by the bound.
        for (faint, keyUp, counted) in [({ (80..<95).contains($0) }, 95, 1), ({ (80..<95).contains($0) }, 150, 1),
                                        ({ (80..<82).contains($0) }, 95, 0), ({ (80..<82).contains($0) }, 150, 0)]
                as [((Int) -> Bool, Int, Int)] {
            let run = try faintRun(0..<(keyUp + 15), keyUp: keyUp, faint: { (35..<60).contains($0) || faint($0) })
            #expect(run.cuts.map(\.commit.reason) == [.textSilence] && near(run.cuts.first?.commit.end, 1.38))
            #expect(run.segmenter.finished && run.segmenter.faintOnlyDropped == counted, "key-up \(keyUp)")
        }
        // Soft audio the bound left out before a kept clip's speech is not counted for a later empty remainder.
        let early = try faintRun(0..<210, text: nil, keyUp: 200, faint: { $0 < 5 }, speech: { (60..<160).contains($0) })
        #expect(early.cuts.map(\.commit.reason) == [.silence] && near(early.cuts.first?.commit.start, 0.2))
        #expect(early.segmenter.finished && early.segmenter.faintOnlyDropped == 0)
    }

    @Test func shortLastWordAfterALongSilenceCutIsKept() throws {
        let profile = try profile(stallMs: 10_000)
        // A 0.6 s phrase with 4 ideographs, a long pause, then (by default) a 0.3 s last word.
        let word: (Int) -> Bool = { (100..<115).contains($0) }
        func run(_ text: String? = nil, keyUp: Int? = 125,
                 tail: @escaping (Int) -> Bool = word) -> [SpeakSegmenter.Commit] {
            let layout: (Int) -> Bool = { $0 < 30 || tail($0) }
            var s = SpeakSegmenter(profile: profile, target: .en, start: 0)
            var cuts = feed(&s, 0..<31, speech: layout).map(\.commit)
            cuts += s.preview(stableText: "明天开会", through: t(30), at: t(31), boundary: .init(from: 0, fullyStable: true))
            cuts += feed(&s, 31..<116, speech: layout).map(\.commit)
            if let text, let floor = cuts.first?.end {
                cuts += s.preview(stableText: text, through: t(115), at: t(116),
                                  boundary: .init(from: floor, fullyStable: true))
            }
            guard let keyUp else { return cuts + feed(&s, 116..<320, speech: layout).map(\.commit) }
            cuts += feed(&s, 116..<keyUp, speech: layout).map(\.commit)
            cuts += s.release(at: t(keyUp))
            return cuts + feed(&s, keyUp..<(keyUp + 10), speech: layout).map(\.commit)
        }
        // No preview covers the word; it is kept because it was voiced before the phrase's forced
        // cut would have come due (4.0 s), also with a key-up after that, up to the remainder's own
        // 4.5 s cap (its clock 1.70 s + 4.5 s = 6.20 s, the end of frame 309).
        for keyUp in [125, 205] {
            let released = run(keyUp: keyUp)
            #expect(released.map(\.reason) == [.longSilence, .release] && near(released.first?.end, 1.1))
            #expect(released.first?.keptBelowFloor == false && released.last?.keptBelowFloor == true)
            #expect(released.last?.speechMs == 300 && released.last?.isFinalChunk == true)
        }
        // A key-up at or after that cap comes too late: the cap cut is not final, so it drops the word.
        #expect(run(keyUp: 310).map(\.reason) == [.longSilence])
        // Only the voicing before that point counts: 80 ms of a word straddling it is enough, 20 ms,
        // a word voiced after it or a single voiced frame (a key click) is not.
        #expect(run(keyUp: 230, tail: { (196..<211).contains($0) }).map(\.reason) == [.longSilence, .release])
        for (keyUp, tail) in [(230, { (199..<214).contains($0) }), (230, { (205..<220).contains($0) }),
                              (125, { $0 == 100 })] as [(Int, (Int) -> Bool)] {
            #expect(run(keyUp: keyUp, tail: tail).map(\.reason) == [.longSilence])
        }
        // Hands-free: no release, so the covering preview closes it at its own long pause
        // (build 99 waited for the cap).
        let latched = run("好吗", keyUp: nil)
        #expect(latched.map(\.reason) == [.longSilence, .longSilence] && latched.last?.keptBelowFloor == true)
        #expect(latched.last?.speechMs == 300)
        for text in [nil, "好"] as [String?] { #expect(run(text, keyUp: nil).map(\.reason) == [.longSilence]) }
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

    /// An 80 ms blip at 0.40 s: the clock starts at 0.10 s, so the 4.5 s cap falls at 4.60 s
    /// (frame 230) with under 0.4 s of speech.
    private func capBlip(_ i: Int) -> Bool { (20..<24).contains(i) }
    /// Feeds `layout` (and `faint` frames) through key-up, releases there and feeds 15 more frames; an
    /// optional preview (from 0, fully stable) arrives once `at` frames are in.
    private func press(_ layout: (Int) -> Bool, keyUp: Int, target: Lang = .en, trustsFaint: Bool = true,
                       faint: (Int) -> Bool = { _ in false },
                       preview: (text: String, through: Int, at: Int)? = nil) throws -> [SpeakSegmenter.Commit] {
        var s = SpeakSegmenter(profile: try profile(stallMs: 10_000), target: target, start: 0, trustsFaint: trustsFaint)
        let at = preview?.at ?? 0
        var cuts = feed(&s, 0..<at, faint: faint, speech: layout).map(\.commit)
        if let preview {
            cuts += s.preview(stableText: preview.text, through: t(preview.through), at: t(at),
                              boundary: .init(from: 0, fullyStable: true))
        }
        cuts += feed(&s, at..<keyUp, faint: faint, speech: layout).map(\.commit)
        cuts += s.release(at: t(keyUp))
        return cuts + feed(&s, keyUp..<(keyUp + 15), faint: faint, speech: layout).map(\.commit)
    }

    @Test func capCutsBackToThePauseBeforeAWordStartingAtIt() throws {
        // A word voiced just before the cap goes on across it: the cut moves back to the pause before the
        // word (one ending at most 0.75 s before the last voiced end before the cap, or the cap if voicing
        // reaches it), at most 1 s before the word, and only the blip is dropped (build 98 cut at 4.60 s).
        let cases: [(layout: (Int) -> Bool, keyUp: Int, start: Double, end: Double, speechMs: Int, first: Int)] = [
            ({ (220..<300).contains($0) }, 330, 3.40, 6.60, 1600, 220),                           // build 98: 1400
            ({ (215..<220).contains($0) || (228..<300).contains($0) }, 330, 3.30, 6.60, 1540, 215), // a 160 ms dip
            ({ (222..<229).contains($0) || (232..<300).contains($0) }, 330, 3.44, 6.60, 1500, 222), // cap in a 60 ms gap
            ({ (216..<240).contains($0) }, 240, 3.32, 5.05, 480, 216),                            // build 98: nothing
            ({ (220..<240).contains($0) }, 230, 3.40, 4.85, 400, 220),                            // key-up at the cap
            ({ (205..<208).contains($0) || (222..<300).contains($0) }, 330, 3.10, 6.60, 1620, 205), // 0.5 s before the cap
            // Single voiced frames up to 4.30 s, the phrase from 4.60 s: the pause ends 0.60 s before the
            // last voiced end (0.90 s before the cap).
            ({ [185, 200, 214].contains($0) || (230..<300).contains($0) }, 330, 2.70, 6.60, 1460, 185),
        ]
        for c in cases {
            for target in [Lang.en, .de] {
                let cuts = try press({ capBlip($0) || c.layout($0) }, keyUp: c.keyUp, target: target)
                #expect(cuts.map(\.reason) == [.release])
                let cut = try #require(cuts.first)
                #expect(near(cut.start, c.start) && near(cut.end, c.end) && cut.speechMs == c.speechMs)
                #expect(cut.speechStart == t(c.first) && !cut.keptBelowFloor)
                #expect(cut.droppedSpeechMs == 80 && cut.capRestart)
            }
        }
        // A faint onset before the word (3.00-4.40 s) keeps the lead a leading silence would keep, from
        // 300 ms before it (a 1 s bound cut it at 3.40 s); speaker mode keeps the 1 s.
        for trusts in [true, false] {
            let soft = try press({ capBlip($0) || (220..<300).contains($0) }, keyUp: 305, trustsFaint: trusts,
                                 faint: { (150..<220).contains($0) })
            #expect(soft.map(\.reason) == [.release] && near(soft.first?.start, trusts ? 2.7 : 3.4), "trusts \(trusts)")
            #expect(soft.first?.faintLeadMs == (trusts ? 1400 : 1000) && soft.first?.droppedSpeechMs == 80)
            #expect(soft.first?.capRestart == true && soft.first?.speechMs == 1600)
        }
        // Real frames are re-anchored per IO block, so a voiced frame can straddle the cap: a 30 ms
        // frame at 2.00 s shifts the rest by 10 ms, and frame 229 spans 4.59-4.61 s.
        var straddle = SpeakSegmenter(profile: try profile(stallMs: 10_000), target: .en, start: 0)
        let shift: (Int) -> HostTime = { $0 <= 100 ? t($0) : t($0) + 10_000_000 }
        var shifted: [SpeakSegmenter.Commit] = []
        for i in 0..<345 {
            if i == 330 { shifted += straddle.release(at: shift(330)) }
            let voiced = capBlip(i) || (220..<300).contains(i)
            shifted += straddle.audio(.init(start: shift(i), end: shift(i + 1), speech: voiced, energy: voiced ? 1 : 0))
        }
        #expect(shifted.map(\.reason) == [.release] && shifted.first?.capRestart == true)
        #expect(near(shifted.first?.start, 3.41) && near(shifted.first?.end, 6.61) && shifted.first?.speechMs == 1600)
        // Hands-free: the phrase commits whole at its own forced cut, 4.0 s after its clock; the next
        // clip carries no restart marks.
        var latched = SpeakSegmenter(profile: try profile(stallMs: 10_000), target: .en, start: 0)
        let held = feed(&latched, 0..<700) { capBlip($0) || (220..<300).contains($0) || (450..<530).contains($0) }
        #expect(held.map(\.frame) == [404, 634] && held.map(\.commit.reason) == [.forcedDip, .forcedDip])
        let phrase = try #require(held.first?.commit), next = try #require(held.last?.commit)
        #expect(near(phrase.start, 3.40) && near(phrase.end, 7.05) && phrase.speechMs == 1600)
        #expect(phrase.droppedSpeechMs == 80 && phrase.capRestart)
        #expect(next.speechMs == 1600 && next.droppedSpeechMs == 0 && !next.capRestart)
    }

    @Test func capStillDropsASparseSegmentWhenNoSpeechCrossesIt() throws {
        // Voiced audio before the cap ends more than 350 ms before the next speech (a 100 ms word, then
        // a phrase from 4.80 s), or no 350 ms pause precedes it (single voiced frames every 300 ms):
        // the whole segment is dropped at the cap, as in build 98.
        for (layout, speechMs, dropped) in [
            ({ (210..<215).contains($0) || (240..<300).contains($0) }, 1200, 180),
            ({ ($0 >= 24 && $0 < 230 && ($0 - 24) % 15 == 0) || (232..<300).contains($0) }, 1360, 360),
        ] as [((Int) -> Bool, Int, Int)] {
            let cuts = try press({ capBlip($0) || layout($0) }, keyUp: 330)
            #expect(cuts.map(\.reason) == [.release])
            #expect(near(cuts.first?.start, 4.6) && cuts.first?.speechMs == speechMs)
            #expect(cuts.first?.droppedSpeechMs == dropped && cuts.first?.capRestart == false)
        }
        // Single voiced frames every 300 ms from 3.00 s, after a real pause (0.48-3.00 s), then a phrase
        // crossing the cap: that pause ends more than 0.75 s before the last voiced end before the cap,
        // so the frames cannot be the phrase's onset; the phrase commits whole from the cap (a restart
        // at that pause cut it at 7.165 s).
        let flicker = try press({
            capBlip($0) || ($0 >= 150 && $0 <= 225 && ($0 - 150) % 15 == 0) || (232..<400).contains($0)
        }, keyUp: 420)
        #expect(flicker.map(\.reason) == [.silence] && near(flicker.first?.start, 4.6) && near(flicker.first?.end, 8.18))
        #expect(flicker.first?.speechMs == 3360 && flicker.first?.droppedSpeechMs == 200 && flicker.first?.capRestart == false)
        // 0.4 s of speech by the cap: the energy cut is unchanged.
        let split = try press({ capBlip($0) || (210..<300).contains($0) }, keyUp: 330)
        #expect(split.map(\.reason) == [.hardCap, .release] && split.first?.end == t(227) + 25_000_000)
        #expect(split.first?.speechMs == 445 && split.allSatisfy { $0.droppedSpeechMs == 0 && !$0.capRestart })
        // A covering preview keeps the cap clip, also when it arrives while the cut waits.
        for (layout, preview, speechMs) in [
            ({ (220..<300).contains($0) }, ("明天", 226, 226), 1400),
            ({ (216..<226).contains($0) || (236..<300).contains($0) }, ("我们", 224, 231), 1280),
        ] as [((Int) -> Bool, (String, Int, Int), Int)] {
            let kept = try press({ capBlip($0) || layout($0) }, keyUp: 330,
                                 preview: (preview.0, preview.1, preview.2))
            #expect(kept.map(\.reason) == [.hardCap, .release])
            #expect(kept.first?.keptBelowFloor == true && near(kept.first?.start, 0.1) && kept.first?.end == t(230))
            #expect(kept.first?.speechMs == 280 && near(kept.last?.start, 4.6) && kept.last?.speechMs == speechMs)
            #expect(kept.allSatisfy { !$0.capRestart })
        }
        // Two sparse segments dropped in a row: the next clip counts both.
        let twice = try press({ capBlip($0) || (250..<254).contains($0) || (470..<550).contains($0) }, keyUp: 580)
        #expect(twice.map(\.reason) == [.release] && near(twice.first?.start, 9.2) && twice.first?.speechMs == 1600)
        #expect(twice.first?.droppedSpeechMs == 160 && twice.first?.capRestart == false)
    }

    @Test func capRestartKeepsACoveredShortWordBeforeThePause() throws {
        // A preview that recognized the short word soon after it closes the word at the long pause, and
        // the phrase starts the next clip whole without a cap restart.
        let paused = try press({ capBlip($0) || (220..<300).contains($0) }, keyUp: 330, preview: ("好的", 25, 30))
        #expect(paused.map(\.reason) == [.longSilence, .release])
        let alone = try #require(paused.first), next = try #require(paused.last)
        #expect(alone.keptBelowFloor && alone.speechMs == 80 && near(alone.end, 0.98))
        #expect(near(next.start, 3.4) && next.speechMs == 1600 && !next.capRestart && next.droppedSpeechMs == 0)
        // One that only arrives once the phrase has started (no quiet left for the long pause): the
        // preview has recognized the word through the moved-back cut, so it is kept on its own, and the
        // phrase starts the next clip whole (build 98 dropped the word and 200 ms of the phrase).
        let cuts = try press({ capBlip($0) || (220..<300).contains($0) }, keyUp: 330, preview: ("好的", 25, 225))
        #expect(cuts.map(\.reason) == [.forcedDip, .release])
        let word = try #require(cuts.first), phrase = try #require(cuts.last)
        #expect(word.keptBelowFloor && word.speechMs == 80 && near(word.end, 3.4) && !word.capRestart)
        #expect(near(phrase.start, 3.4) && phrase.speechMs == 1600 && phrase.capRestart && phrase.droppedSpeechMs == 0)
    }

    @Test func capRestartIgnoresPreviewTextFromAfterTheCut() throws {
        // A 60 ms click, then speech whose soft onset VAD missed: the preview through 4.28 s covers the
        // click, but its words come from after the moved-back cut, so the click is still dropped.
        let cuts = try press({ (20..<23).contains($0) || (222..<300).contains($0) }, keyUp: 330,
                             preview: ("我们明天", 214, 229))
        #expect(cuts.map(\.reason) == [.release])
        let cut = try #require(cuts.first)
        #expect(near(cut.start, 3.44) && near(cut.end, 6.6) && cut.speechMs == 1560)
        #expect(cut.droppedSpeechMs == 60 && cut.capRestart && !cut.keptBelowFloor)
    }
}
