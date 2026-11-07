import Foundation
import Testing
@testable import TalkTalkCore

struct SpeakShortReplyTests {
    private func ns(_ seconds: Double) -> HostTime { UInt64((seconds * 1e9).rounded()) }
    private func make(target: Lang = .en) throws -> SpeakSegmenter {
        SpeakSegmenter(profile: try TestResources.profile().speak, target: target, start: 0,
                       charactersPerSecond: 4.399)
    }
    private func feed(_ segmenter: inout SpeakSegmenter, _ from: Double, _ to: Double,
                      speech: Bool) -> [SpeakSegmenter.Commit] {
        segmenter.audio(.init(start: ns(from), end: ns(to), speech: speech, energy: speech ? 1 : 0))
    }
    private func preview(_ segmenter: inout SpeakSegmenter, text: String = "谢谢。", at: Double = 0.8,
                         from: Double = 0, through: Double = 0.8, complete: Bool = true,
                         final: Bool = false) -> [SpeakSegmenter.Commit] {
        segmenter.preview(stableText: text, through: ns(through), at: ns(at), isFinal: final,
                          boundary: .init(from: ns(from), fullyStable: complete))
    }

    @Test func completedRepliesCommitAfterObservedPauseWithOriginalAudioAndTail() throws {
        for target in [Lang.en, .de, .zh] {
            for text in ["谢谢。", "好的。", "没问题！", "Thank you.", "Yes.", "No problem!"] {
                var s = try make(target: target)
                #expect(feed(&s, 0, 0.8, speech: true).isEmpty)
                #expect(preview(&s, text: text).isEmpty)
                #expect(feed(&s, 0.8, 1.299, speech: false).isEmpty)
                let cut = try #require(feed(&s, 1.299, 1.3, speech: false).first)
                #expect(cut.reason == .shortReply && cut.start == 0 && cut.end == ns(1.05))
                #expect(cut.speechMs == 800 && !cut.isFinalChunk)
                #expect(feed(&s, 1.3, 1.6, speech: false).isEmpty)
            }
        }
    }

    @Test func oldPreviewCallersAndUnconfirmedHypothesesKeepOriginalMinimum() throws {
        var legacy = try make()
        _ = feed(&legacy, 0, 0.8, speech: true)
        _ = legacy.preview(stableText: "谢谢。", through: ns(0.8), at: ns(0.8), isFinal: true)
        #expect(feed(&legacy, 0.8, 1.5, speech: false).isEmpty)
        var incomplete = try make()
        _ = feed(&incomplete, 0, 0.8, speech: true)
        // A stable prefix saying "Yes." does not authorize a cut when the complete
        // revisable hypothesis already says "Yes, because ...".
        _ = preview(&incomplete, text: "Yes.", complete: false, final: true)
        #expect(feed(&incomplete, 0.8, 1.5, speech: false).isEmpty)
    }

    @Test func numbersNamesAbbreviationsAndUnfinishedClausesAreNotRelaxed() throws {
        for text in ["12.", "12.5.", "三十万。", "No.", "Dr.", "e.g.", "3 p.m.", "王先生。",
                     "Because.", "If.", "I think.", "因为。", "如果。", "yes...", "好的……", "好的，", "Okay,"] {
            var s = try make()
            _ = feed(&s, 0, 0.8, speech: true)
            _ = preview(&s, text: text, final: true)
            #expect(feed(&s, 0.8, 1.8, speech: false).isEmpty)
        }
    }

    @Test func completeHypothesisMustRemainStableAgainAfterARevision() throws {
        var s = try make()
        _ = feed(&s, 0, 0.8, speech: true)
        _ = preview(&s, text: "Yes.")
        _ = feed(&s, 0.8, 1.1, speech: false)
        _ = preview(&s, text: "Yes.", at: 1.1, complete: false)
        #expect(feed(&s, 1.1, 1.3, speech: false).isEmpty)
        #expect(preview(&s, text: "Yes.", at: 1.3).isEmpty)
        #expect(feed(&s, 1.3, 1.599, speech: false).isEmpty)
        #expect(feed(&s, 1.599, 1.6, speech: false).first?.reason == .shortReply)
    }

    @Test func resumedSpeechInvalidatesOldFinalAndOldCoverage() throws {
        var s = try make()
        _ = feed(&s, 0, 0.8, speech: true)
        _ = preview(&s, text: "Yes.", final: true)
        #expect(feed(&s, 0.8, 1.299, speech: false).isEmpty)
        #expect(feed(&s, 1.299, 1.499, speech: true).isEmpty)
        // Even a fully stable but old result cannot cover the newly spoken words.
        _ = preview(&s, text: "Yes.", at: 1.499, through: 0.8)
        #expect(feed(&s, 1.499, 2.1, speech: false).isEmpty)
        #expect(preview(&s, text: "Yes, because.", at: 2.1, through: 1.499, final: true).isEmpty)
    }

    @Test func sourceCoverageAndFutureAudioCannotAuthorizeEarlyCut() throws {
        for (from, through) in [(0.1, 0.8), (0, 0.79), (0, 2.0)] {
            var s = try make()
            _ = feed(&s, 0, 0.8, speech: true)
            _ = preview(&s, from: from, through: through)
            #expect(feed(&s, 0.8, 1.5, speech: false).isEmpty)
        }
    }

    @Test func oldSegmentCallbacksCannotCutTheNextReplyOrRepeatItsAudio() throws {
        var s = try make()
        _ = feed(&s, 0, 0.8, speech: true)
        _ = preview(&s)
        let first = try #require(feed(&s, 0.8, 1.3, speech: false).first)
        _ = feed(&s, 1.3, 2.1, speech: true)
        _ = preview(&s, text: "Yes.", at: 2.1, from: 0, through: 2.1, final: true)
        #expect(feed(&s, 2.1, 2.6, speech: false).isEmpty)
        _ = preview(&s, text: "Yes.", at: 2.6, from: 1.05, through: 2.1)
        let second = try #require(feed(&s, 2.6, 2.9, speech: false).first)
        #expect(first.end == second.start && second.end == ns(2.35))
        #expect(second.speechMs == 800 && second.index == first.index + 1)
    }

    @Test func audioGapIsNotCountedAsObservedPauseAndSubminimumSpeechStaysPending() throws {
        var gap = try make()
        _ = feed(&gap, 0, 0.8, speech: true)
        _ = preview(&gap)
        _ = feed(&gap, 0.8, 1.0, speech: false)
        #expect(feed(&gap, 1.3, 1.5, speech: false).isEmpty)
        _ = preview(&gap, at: 1.5)
        #expect(feed(&gap, 1.5, 1.799, speech: false).isEmpty)
        var short = try make()
        _ = feed(&short, 0, 0.399, speech: true)
        _ = preview(&short, at: 0.399, through: 0.399)
        #expect(feed(&short, 0.399, 1.0, speech: false).isEmpty)
    }

    @Test func explicitReleaseStillUsesOriginalTailAndFloor() throws {
        var s = try make()
        _ = feed(&s, 0, 0.8, speech: true)
        _ = preview(&s)
        #expect(s.release(at: ns(0.8)).isEmpty)
        let cut = try #require(feed(&s, 0.8, 1.3, speech: false).first)
        #expect(cut.reason == .release && cut.isFinalChunk && cut.end == ns(1.05))
    }

    @Test func tinyTimestampGapsDoNotDisableRepliesButAreNotCountedAsSilence() throws {
        var s = try make()
        _ = feed(&s, 0, 0.8, speech: true)
        _ = preview(&s)
        var cursor = 0.8
        for _ in 0..<24 {
            let from = cursor + 0.0005
            cursor = from + 0.02
            #expect(feed(&s, from, cursor, speech: false).isEmpty)
        }
        // The wall clock has advanced 492 ms but only 480 ms of silence was captured.
        #expect(feed(&s, cursor + 0.0005, cursor + 0.0195, speech: false).isEmpty)
        cursor += 0.0195
        #expect(feed(&s, cursor, cursor + 0.002, speech: false).first?.reason == .shortReply)
    }
}
