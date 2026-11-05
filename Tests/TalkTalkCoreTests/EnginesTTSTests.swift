import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct EnginesTTSTests {
    static let model = EngineID(name: "qwen3-tts-1.7b-base-8bit", revision: "abc123", placement: .engineGPU)
    static let voice = VoiceHandle(profileID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
                                   conditioningKey: "k8-1234", mode: .icl, model: model)
    static let timing = StageTiming(received: 10, started: 20, firstOutput: 30, finished: 40)

    func roundTrip<T: Codable & Equatable>(_ v: T) throws -> T {
        let back = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
        #expect(back == v)
        return back
    }

    @Test func requestRoundTrip() throws {
        let r = TTSRequest(job: 7, clause: 3, text: "Thanks, everyone.", language: .en, voice: Self.voice,
                           seed: TTSSeed.make(voice: Self.voice, text: "Thanks, everyone."), wholeClause: true)
        _ = try roundTrip(r)
        _ = try roundTrip(Self.voice)
        _ = try roundTrip(VoiceReference(pcm24k: Data([1, 2, 3]), text: "稿子", lang: .zh))
        for m in CloneMode.allCases { _ = try roundTrip(m) }
    }

    @Test func summaryUsesWireKeys() throws {
        let s = TTSSummary(audioS: 1.28, frames: 16, runaway: false, short: true, slow: false, echoAborts: 1,
                           attempts: 2, leadTrimMs: 40, timing: Self.timing)
        _ = try roundTrip(s)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        #expect(Set(obj.keys) == ["audio_s", "frames", "runaway", "short", "slow", "echo_aborts", "attempts",
                                  "lead_trim_ms", "timing"])
    }

    @Test func chunkAndReportRoundTrip() throws {
        let last = TTSChunk(job: 7, seq: 4, samples24k: [0, 0.25, -0.5], isLast: true, producedAt: 99,
                            summary: TTSSummary(audioS: 0.8, frames: 10, timing: Self.timing))
        _ = try roundTrip(last)
        _ = try roundTrip(TTSChunk(job: 7, seq: 0, samples24k: [], isLast: false, producedAt: 1))
        _ = try roundTrip(PlayoutReport(job: 7, bufferedMs: 640, underruns: 1, paused: true, tempo: 1.25, epoch: 2, at: 5))
        _ = try roundTrip(PlayoutReport(job: nil, bufferedMs: 0, underruns: 0, paused: false, tempo: 1, epoch: 0, at: 5))
        // The engine's /v1/playout handler reads `bufferedMs` (§4.4).
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PlayoutReport(job: 1, bufferedMs: 3, underruns: 0, paused: false, tempo: 1, epoch: 0, at: 0))) as! [String: Any]
        #expect(obj["bufferedMs"] as? Int == 3)
    }

    @Test func languageSeedsPreserveTheListeningComparison() {
        #expect(TTSSeed.make(voice: Self.voice, language: .en) == 2_583_116_680)
        #expect(TTSSeed.make(voice: Self.voice, language: .de) == 318_753_904)
        var other = Self.voice
        other.conditioningKey = "k8-9999"
        #expect(TTSSeed.make(voice: other, language: .en) != TTSSeed.make(voice: Self.voice, language: .en))
    }

    @Test func seedIsStableAndDependsOnVoiceAndText() {
        let a = TTSSeed.make(voice: Self.voice, text: "Hello there.")
        #expect(a == TTSSeed.make(voice: Self.voice, text: "Hello there."))
        #expect(a != TTSSeed.make(voice: Self.voice, text: "Hello there!"))
        var other = Self.voice
        other.conditioningKey = "k8-9999"
        #expect(a != TTSSeed.make(voice: other, text: "Hello there."))
        // Pinned value: FNV-1a is fixed, so a change here means the seed function changed.
        #expect(a == 517_039_729)   // computed independently with Python FNV-1a
        let retries = (1...3).map { TTSSeed.next(a, attempt: $0) }
        #expect(Set(retries + [a]).count == 4)
    }
}
