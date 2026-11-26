import Foundation
import Testing
@testable import TalkTalkCore

/// Soft phrases (ARCHITECTURE §5.2): a segment with no voiced frame whose words the covering preview
/// shows closes at its own long pause and is kept below the release floor; without such words faint
/// audio is still dropped. Frames are 20 ms; layouts and text are invented.
struct SpeakSoftPhraseTests {
    private func ns(_ seconds: Double) -> HostTime { UInt64(seconds * 1e9) }
    private func t(_ frame: Int) -> HostTime { ns(Double(frame) * 0.02) }
    private func near(_ time: HostTime?, _ seconds: Double) -> Bool {
        guard let time else { return false }
        return abs(Int64(bitPattern: time) - Int64(bitPattern: ns(seconds))) < 1_000_000
    }

    /// Soft speech VAD hears only as faint frames: 160 ms runs with 40 ms gaps over `frames`.
    private func soft(_ frames: Range<Int>) -> (Int) -> Bool {
        { frames.contains($0) && ($0 - frames.lowerBound) % 10 < 8 }
    }

    /// A 200 ms phrase voiced at 1.20-1.40 s whose preview ("明天开会", through 1.40 s, sent at 1.44 s)
    /// closes it at its long pause (0.2-1.9 s), then `faint` frames with `previews` (text, through frame,
    /// sent at frame) for the audio since the last emitted cut. `queued` previews still start at 0, as if
    /// queued before that first cut. Previews stop at key-up; 15 frames follow it.
    private func press(keyUp: Int, faint: @escaping (Int) -> Bool, previews: [(String, Int, Int)],
                       queued: [(String, Int, Int)] = [],
                       speech: @escaping (Int) -> Bool = { (60..<70).contains($0) }, trustsFaint: Bool = true)
        throws -> (cuts: [(frame: Int, commit: SpeakSegmenter.Commit)], segmenter: SpeakSegmenter) {
        var profile = try TestResources.profile().speak
        profile.boundary.stallMs = 10_000
        var s = SpeakSegmenter(profile: profile, target: .en, start: 0, trustsFaint: trustsFaint)
        var cuts: [(frame: Int, commit: SpeakSegmenter.Commit)] = []
        let sent = [("明天开会", 70, 72, false)] + previews.map { ($0.0, $0.1, $0.2, false) }
            + queued.map { ($0.0, $0.1, $0.2, true) }
        for i in 0..<(keyUp + 15) {
            if i < keyUp {
                for (text, through, at, early) in sent where at == i {
                    let from = early ? 0 : cuts.last?.commit.end ?? 0
                    cuts += s.preview(stableText: text, through: t(through), at: t(at),
                                      boundary: .init(from: from, fullyStable: false)).map { (i, $0) }
                }
            }
            if i == keyUp { cuts += s.release(at: t(i)).map { (i, $0) } }
            let voiced = speech(i)
            for c in s.audio(.init(start: t(i), end: t(i + 1), speech: voiced, energy: voiced ? 1 : 0, faint: faint(i))) {
                cuts.append((i, c))
            }
        }
        return (cuts, s)
    }

    /// The soft sentence at 3.00-4.96 s and its two previews (the second covers its last faint run).
    private let sentence: (Int) -> Bool = { ($0 >= 150 && $0 < 250) && ($0 - 150) % 10 < 8 }
    private let words = [("我们下午", 200, 215), ("我们下午三点讨论", 248, 260)]

    @Test func softSentenceAfterAShortPhraseClosesAtItsLongPause() throws {
        // Build 100 dropped such a sentence (no voiced frame) whatever its preview showed, at key-up or
        // to the leading-silence bound. It now closes 1 s after its last faint run, in that quiet.
        let late = try press(keyUp: 400, faint: sentence, previews: words)
        #expect(late.cuts.map(\.commit.reason) == [.longSilence, .longSilence])
        #expect(late.cuts.map(\.frame) == [119, 297])
        let phrase = try #require(late.cuts.first?.commit)
        #expect(near(phrase.start, 0.2) && near(phrase.end, 1.9) && phrase.keptBelowFloor && phrase.speechMs == 200)
        let clip = try #require(late.cuts.last?.commit)
        #expect(near(clip.start, 2.7) && near(clip.end, 5.46) && clip.keptBelowFloor && clip.speechMs == 0)
        #expect(clip.speechStart == nil && clip.previewCjk == 8 && clip.index == 1 && clip.faintHeldMs == nil)
        #expect(clip.faintLeadMs == 1600 && clip.faintCutMs == 0 && clip.faintTailMs == nil)
        #expect(late.segmenter.finished && late.segmenter.faintOnlyDropped == 0)
        // A covering preview up to 1.35 s after the last faint run still finds the sentence held (cut
        // where it arrives, 6.10 s); one 1.44 s after it finds it left out, so it is dropped and counted.
        let held = try press(keyUp: 400, faint: sentence, previews: [words[0], ("我们下午三点讨论", 248, 305)])
        #expect(held.cuts.map(\.frame) == [119, 305] && held.cuts.last?.commit.reason == .longSilence)
        #expect(near(held.cuts.last?.commit.start, 2.7) && near(held.cuts.last?.commit.end, 5.53))
        let lapsed = try press(keyUp: 400, faint: sentence, previews: [words[0], ("我们下午三点讨论", 248, 320)])
        #expect(lapsed.cuts.map(\.commit.reason) == [.longSilence] && lapsed.segmenter.faintOnlyDropped == 1)
        // More words named past the cut (through 5.90 s) do not hold it back: the first preview that named
        // the sentence's words is when they were recognized.
        let more = try press(keyUp: 400, faint: sentence, previews: words + [("我们下午三点讨论预算", 295, 296)])
        #expect(more.cuts.map(\.frame) == [119, 297] && more.cuts.last?.commit.previewCjk == 10)
        // An 80 ms faint run the recognizer never names (a breath at 5.50 s) is the sentence's tail: the
        // cut waits 1 s after it. A 400 ms one is more than a tail, so the sentence waits for the preview.
        let breath = try press(keyUp: 450, faint: { sentence($0) || (275..<279).contains($0) }, previews: words)
        #expect(breath.cuts.map(\.frame) == [119, 328] && breath.cuts.last?.commit.reason == .longSilence)
        #expect(near(breath.cuts.last?.commit.start, 2.7) && near(breath.cuts.last?.commit.end, 6.08))
        let untold = try press(keyUp: 450, faint: { sentence($0) || (275..<295).contains($0) }, previews: words)
        #expect(untold.cuts.map(\.commit.reason) == [.longSilence] && untold.segmenter.faintOnlyDropped == 1)
        // One long faint run (3.00-3.80 s) needs the preview within 200 ms of its end, as a voiced one does:
        // through 3.64 s closes it; through 3.40 s, a 200 ms untold tail inside that run, does not.
        let whole = try press(keyUp: 300, faint: { (150..<190).contains($0) }, previews: [("我们下午三点", 182, 185)])
        #expect(whole.cuts.map(\.commit.reason) == [.longSilence, .longSilence])
        let inside = try press(keyUp: 300, faint: { (150..<190).contains($0) }, previews: [("我们下午三点", 170, 185)])
        #expect(inside.cuts.map(\.commit.reason) == [.longSilence] && inside.segmenter.faintOnlyDropped == 1)
        // A short one (3.00-3.56 s) is cut in the middle of the quiet after it too (4.06 s), not at the
        // middle of the whole unvoiced segment (3.63 s), 70 ms after it.
        let short = try press(keyUp: 300, faint: soft(150..<180), previews: [("周五见面", 178, 190)])
        #expect(short.cuts.map(\.commit.reason) == [.longSilence, .longSilence])
        #expect(near(short.cuts.last?.commit.start, 2.7) && near(short.cuts.last?.commit.end, 4.06))
        // Key-up before that pause: the covering preview keeps the release remainder.
        let early = try press(keyUp: 270, faint: sentence, previews: words)
        #expect(early.cuts.map(\.commit.reason) == [.longSilence, .release])
        let tail = try #require(early.cuts.last?.commit)
        #expect(near(tail.start, 2.7) && near(tail.end, 5.4) && tail.keptBelowFloor && tail.isFinalChunk)
        #expect(early.segmenter.faintOnlyDropped == 0)
    }

    @Test func ruleOneAfterASoftPhraseCountsFromItsLead() throws {
        // An 80 ms word with no preview after the soft clip (2.70-5.46 s): rule one keeps it when it is
        // voiced by that clip's lead start + 4.5 s (7.20 s), as it does after a voiced sub-floor phrase.
        let kept = try press(keyUp: 360, faint: sentence, previews: words,
                             speech: { (60..<70).contains($0) || (340..<344).contains($0) })
        #expect(kept.cuts.map(\.commit.reason) == [.longSilence, .longSilence, .release])
        #expect(kept.cuts.last?.commit.keptBelowFloor == true && kept.cuts.last?.commit.speechMs == 80)
        let dropped = try press(keyUp: 385, faint: sentence, previews: words,
                                speech: { (60..<70).contains($0) || (365..<369).contains($0) })
        #expect(dropped.cuts.map(\.commit.reason) == [.longSilence, .longSilence] && dropped.segmenter.finished)
    }

    @Test func softSentenceKeepsItsWholeLeadUpToTheClipBound() throws {
        // A 3.6 s soft sentence (3.00-6.56 s): its lead stays from 2.70 s past faintLeadMax (2.5 s).
        let long = try press(keyUp: 450, faint: soft(150..<330),
                             previews: [("我们下午", 200, 215), ("我们下午三点讨论一下预算", 328, 340)])
        #expect(long.cuts.map(\.commit.reason) == [.longSilence, .longSilence])
        #expect(near(long.cuts.last?.commit.start, 2.7) && near(long.cuts.last?.commit.end, 7.06))
        // A 5 s one (3.00-7.96 s) keeps the 4.5 s before its cut (8.46 s).
        let longer = try press(keyUp: 500, faint: soft(150..<400),
                               previews: [("我们下午", 200, 215), ("我们下午三点讨论一下明年的预算", 398, 410)])
        #expect(longer.cuts.map(\.commit.reason) == [.longSilence, .longSilence])
        #expect(near(longer.cuts.last?.commit.start, 3.96) && near(longer.cuts.last?.commit.end, 8.46))
        #expect(longer.cuts.last?.commit.faintTrimmedMs == 800)
        // More soft words 1.20 s after the sentence, before its covering preview: the hold links them
        // (gaps up to 1.35 s, not leadKeep), so the clip keeps the sentence the preview names.
        let more = try press(keyUp: 450, faint: { sentence($0) || soft(308..<326)($0) },
                             previews: [words[0], ("我们下午三点讨论", 248, 312), ("我们下午三点讨论一下", 328, 340)])
        #expect(more.cuts.map(\.commit.reason) == [.longSilence, .longSilence])
        #expect(near(more.cuts.last?.commit.start, 2.7) && near(more.cuts.last?.commit.end, 7.02))
        #expect(more.cuts.last?.commit.faintLeadMs == 1920)
    }

    @Test func softPhraseNeedsWordsBeyondTheTextOfSoftAudioLeftOut() throws {
        // The sentence's audio is left out before its words count: its covering preview comes 1.44 s after
        // it, or the text ends in a comma so its pause waits until the hold lapses. A breath at 7.00 s
        // with the preview through it is then no soft phrase, mid-press or at key-up.
        let breath: (Int) -> Bool = { sentence($0) || (350..<354).contains($0) }
        let comma = [words[0], ("我们下午三点，", 248, 260), ("我们下午三点，", 356, 360)]
        for keyUp in [380, 450] {
            let late = try press(keyUp: keyUp, faint: breath,
                                 previews: [("我们下午三点讨论", 248, 320), ("我们下午三点讨论", 356, 360)])
            #expect(late.cuts.map(\.commit.reason) == [.longSilence], "key-up \(keyUp)")
            #expect(late.segmenter.faintOnlyDropped == 1, "key-up \(keyUp)")
            let paused = try press(keyUp: keyUp, faint: breath, previews: comma)
            #expect(paused.cuts.map(\.commit.reason) == [.longSilence], "key-up \(keyUp)")
            #expect(paused.segmenter.faintOnlyDropped == 1, "key-up \(keyUp)")
            // Stable text lagging `through`: the words first appear only after the sentence was left out,
            // through 6.80 s (past where the breath's kept lead starts), with nothing of the segment heard
            // before that. They are stale as well.
            let lagging = try press(keyUp: keyUp, faint: breath,
                                    previews: [words[0], ("我们下午三点讨论", 340, 342), ("我们下午三点讨论", 356, 360)])
            #expect(lagging.cuts.map(\.commit.reason) == [.longSilence], "key-up \(keyUp)")
            #expect(lagging.segmenter.faintOnlyDropped == 1, "key-up \(keyUp)")
        }
        // Text through 6.20 s, sent while the comma-ended sentence is still held, is all stale once the hold
        // lapses and the sentence is trimmed, though that trim stops short of 6.20 s: a breath at 6.40 s,
        // held from 6.10 s, is no soft phrase at key-up.
        let trimmed = try press(keyUp: 340, faint: { sentence($0) || (320..<324).contains($0) },
                                previews: [words[0], ("我们下午三点，", 310, 312), ("我们下午三点，", 326, 330)])
        #expect(trimmed.cuts.map(\.commit.reason) == [.longSilence] && trimmed.segmenter.faintOnlyDropped == 1)
        // New words recognized only through 8.00 s (sent at 8.06 s, while the breath is still kept), later
        // than any cut the breath's hold allows (up to 7.75 s) + 200 ms, may come from the next phrase's
        // onset: the breath still gets no clip.
        let next = try press(keyUp: 450, faint: breath, previews: [words[0], ("我们下午三点，", 248, 260),
                                                                   ("我们下午三点，然后讨论", 400, 403)])
        #expect(next.cuts.map(\.commit.reason) == [.longSilence] && next.segmenter.faintOnlyDropped == 1)
        // Two more words, with soft audio of their own (7.00-7.96 s), make a soft phrase again.
        let again = try press(keyUp: 500, faint: { sentence($0) || soft(350..<400)($0) },
                              previews: [words[0], ("我们下午三点，", 248, 260), ("我们下午三点，然后讨论预算", 398, 410)])
        #expect(again.cuts.map(\.commit.reason) == [.longSilence, .longSilence])
        #expect(near(again.cuts.last?.commit.start, 6.7) && near(again.cuts.last?.commit.end, 8.46))
        #expect(again.cuts.last?.commit.previewCjk == 12 && again.segmenter.faintOnlyDropped == 0)
    }

    @Test func holdSlidingPastWhereItsWordsWereNamedLeavesThemStale() throws {
        // The recognizer names the sentence (through 4.96 s) and keeps re-sending that text while its
        // `through` follows linked murmur it never names (5.80-9.36 s). Once the hold's 4.5 s bound slides
        // past 4.96 s, the words no longer count: the murmur gets no clip at key-up (10.00 s) or at its
        // long pause, and is dropped and counted.
        let follow = words + stride(from: 265, to: 560, by: 5).map { ("我们下午三点讨论", $0 - 10, $0) }
        for keyUp in [500, 560] {
            let run = try press(keyUp: keyUp, faint: { sentence($0) || soft(290..<470)($0) }, previews: follow)
            #expect(run.cuts.map(\.commit.reason) == [.longSilence], "key-up \(keyUp)")
            #expect(run.segmenter.faintOnlyDropped == 1, "key-up \(keyUp)")
        }
    }

    @Test func staleWordsCountOnlyTextForSoftAudioLeftOutSinceTheLastCut() throws {
        // The comma-ended sentence is left out (its six ideographs stale), a voiced clause (7.00-7.60 s)
        // is cut, and the text after that cut is new: a soft phrase (9.00-9.96 s) needs only its own words.
        let previews = [words[0], ("我们下午三点，", 248, 260), ("我们下午三点，然后讨论明年预算", 380, 385),
                        ("周五见面", 498, 510)]
        let after = try press(keyUp: 560, faint: { sentence($0) || soft(450..<500)($0) }, previews: previews,
                              speech: { (60..<70).contains($0) || (350..<380).contains($0) })
        #expect(after.cuts.map(\.commit.reason) == [.longSilence, .textSilence, .longSilence])
        let clip = try #require(after.cuts.last?.commit)
        #expect(near(clip.start, 8.7) && near(clip.end, 10.46) && clip.speechMs == 0 && clip.previewCjk == 4)
        #expect(after.segmenter.faintOnlyDropped == 0)
        // A preview queued before the first cut (from 0, through 1.92 s) that arrives at 2.96 s describes
        // audio that clip took, not soft audio left out: the sentence after it is still a soft phrase.
        let queued = try press(keyUp: 400, faint: sentence, previews: words, queued: [("明天开会，我们下午", 96, 148)])
        #expect(queued.cuts.map(\.frame) == [119, 297] && queued.segmenter.faintOnlyDropped == 0)
    }

    @Test func softAudioWithoutAWordIsStillDroppedAndCounted() throws {
        // No preview, fillers only, one ideograph, or a preview short of the last faint run: the soft
        // sentence is dropped at key-up, or left out by the leading-silence bound before a later one.
        let cases: [[(String, Int, Int)]] = [[], [("嗯", 248, 260)], [("那个嗯", 248, 260)], [("好", 248, 260)],
                                             [("我们下午", 200, 215)]]
        for previews in cases {
            for keyUp in [270, 400] {
                let run = try press(keyUp: keyUp, faint: sentence, previews: previews)
                #expect(run.cuts.map(\.commit.reason) == [.longSilence], "\(previews) key-up \(keyUp)")
                #expect(run.segmenter.finished && run.segmenter.faintOnlyDropped == 1, "\(previews) key-up \(keyUp)")
            }
        }
        // Words recognized before a short soft run (through 2.80 s, run 3.00-3.16 s) do not cover it.
        for keyUp in [270, 400] {
            let before = try press(keyUp: keyUp, faint: soft(150..<158), previews: [("周五见面", 140, 145)])
            #expect(before.cuts.map(\.commit.reason) == [.longSilence], "key-up \(keyUp)")
            #expect(before.segmenter.faintOnlyDropped == 1, "key-up \(keyUp)")
        }
        // Speaker mode: faint frames are not the user's own soft speech, so nothing changes.
        for keyUp in [270, 400] {
            let speaker = try press(keyUp: keyUp, faint: sentence, previews: words, trustsFaint: false)
            #expect(speaker.cuts.map(\.commit.reason) == [.longSilence] && speaker.segmenter.faintOnlyDropped == 0)
        }
    }
}
