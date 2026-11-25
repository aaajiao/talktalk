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
}
