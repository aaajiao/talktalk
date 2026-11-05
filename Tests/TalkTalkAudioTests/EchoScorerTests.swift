import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkAudio

@Suite struct EchoScorerTests {
    private func pattern(_ i: Int) -> Float {
        // Deterministic nonperiodic envelope, not a pure tone's constant RMS.
        let x = UInt64(i + 1) &* 2_654_435_761
        return 0.02 + Float((x ^ (x >> 11)) % 1000) / 5000
    }
    private func points(delayMs: Int = 0, scale: Float = 1, offset: Float = 0, unrelated: Bool = false) -> [EnvelopePoint] {
        (0..<450).map { i in
            let value = unrelated ? pattern(i * 13 + 7) : pattern(i)
            return EnvelopePoint(seq: UInt64(i), at: UInt64(1000 + i * 10 + delayMs) * 1_000_000,
                rms: value * scale + offset, peak: value)
        }
    }
    @Test(arguments: [50, 370, 1500]) func findsPositiveDelayDespiteGainAndNoiseFloor(delayMs: Int) throws {
        let tap = points(delayMs: delayMs, scale: 0.3, offset: 0.01)
        let result = try #require(EchoScorer().estimate(feed: points(), tap: tap, through: tap.last!.at))
        #expect(result.lagMs == delayMs)
        #expect(result.score > 0.999)
        #expect(result.pairedPoints >= 250)
    }
    @Test func unrelatedSpeechDoesNotMatchAndObservedSilenceIsZero() throws {
        let tap = points(delayMs: 300, unrelated: true)
        let result = try #require(EchoScorer().estimate(feed: points(), tap: tap, through: tap.last!.at))
        #expect(result.score < 0.5)
        let flat = points().map { EnvelopePoint(seq: $0.seq, at: $0.at, rms: 0, peak: 0) }
        #expect(EchoScorer().estimate(feed: flat, tap: flat, through: flat.last!.at)?.score == 0)
        #expect(EchoScorer().estimate(feed: Array(flat.suffix(20)), tap: flat, through: flat.last!.at) == nil)
        #expect(EchoScorer().estimate(feed: points(), tap: Array(tap.prefix(10)), through: tap[9].at) == nil)
        #expect(EchoScorer().estimate(feed: points(), tap: tap, through: tap.last!.at + 100_000_000) == nil)
    }
}
