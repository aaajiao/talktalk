import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkApple

// SystemVoiceTTS (C8): voice choice is pure; one real render checks the chunk contract
// (24 kHz f32 mono, 0.16 s chunks, summary on the last) and cancel. Skips without an en-US voice.

@Suite struct SystemVoiceTTSTests {
    typealias V = SystemVoiceTTS.VoiceInfo

    @Test func picksHighestQualityThenPreferredNameNeverPersonal() {
        let voices = [
            V(identifier: "a", name: "Samantha", language: "en-US", quality: 2),
            V(identifier: "b", name: "Ava (Premium)", language: "en-US", quality: 3),
            V(identifier: "c", name: "Zoe (Premium)", language: "en-US", quality: 3),
            V(identifier: "d", name: "Me", language: "en-US", quality: 3, isPersonal: true),
            V(identifier: "e", name: "Bubbles", language: "en-US", quality: 3, isNovelty: true),
            V(identifier: "f", name: "Anna", language: "de-DE", quality: 1),
            V(identifier: "g", name: "Helena", language: "de-DE", quality: 1),
            V(identifier: "h", name: "Tingting", language: "zh-CN", quality: 3),
        ]
        #expect(SystemVoiceTTS.pickVoice(for: .en, among: voices)?.identifier == "b")
        #expect(SystemVoiceTTS.pickVoice(for: .de, among: voices)?.identifier == "f")
        #expect(SystemVoiceTTS.pickVoice(for: .zh, among: voices)?.identifier == "h")
        #expect(SystemVoiceTTS.pickVoice(for: .en, among: [voices[3], voices[4]]) == nil)
    }

    func request(_ lang: Lang, _ text: String, job: JobID = 1) -> TTSRequest {
        let voice = VoiceHandle(profileID: UUID(), conditioningKey: "system", mode: .system, model: SystemVoiceTTS().id)
        return TTSRequest(job: job, clause: 1, text: text, language: lang, voice: voice,
                          seed: TTSSeed.make(voice: voice, text: text), wholeClause: true)
    }

    @Test(.enabled(if: SystemVoiceTTS.pickVoice(for: .zh, among: SystemVoiceTTS.installedVoices()) != nil))
    func rendersChineseThroughTheSameChunkContract() async throws {
        let tts = SystemVoiceTTS()
        var chunks: [TTSChunk] = []
        for try await chunk in tts.speak(request(.zh, "我们下周三再讨论项目预算。")) { chunks.append(chunk) }
        let last = try #require(chunks.last)
        #expect(last.isLast)
        #expect(chunks.count > 2)
        #expect(chunks.dropLast().allSatisfy { $0.samples24k.count == SystemVoiceTTS.chunkSamples && !$0.isLast })
        #expect(last.summary?.frames == chunks.reduce(0) { $0 + $1.samples24k.count })
        #expect(chunks.flatMap(\.samples24k).contains { abs($0) > 0.01 })
    }

    @Test func noConditioning() async {
        let tts = SystemVoiceTTS()
        let ref = VoiceReference(pcm24k: Data(), text: "", lang: .zh)
        await #expect(throws: SystemVoiceTTS.Failure.noConditioning) {
            _ = try await tts.buildConditioning(ref, model: tts.id, mode: .icl)
        }
    }

    @Test(.enabled(if: SystemVoiceTTS.pickVoice(for: .en, among: SystemVoiceTTS.installedVoices()) != nil))
    func rendersChunksAndSummary() async throws {
        let tts = SystemVoiceTTS()
        #expect(tts.outputRate == 24_000)
        var chunks: [TTSChunk] = []
        for try await c in tts.speak(request(.en, "We will fix it by next Wednesday.")) { chunks.append(c) }
        #expect(chunks.count >= 2)
        #expect(chunks.dropLast().allSatisfy { $0.samples24k.count == SystemVoiceTTS.chunkSamples && !$0.isLast })
        #expect(chunks.map(\.seq) == Array(0..<chunks.count))
        let last = try #require(chunks.last)
        #expect(last.isLast)
        let s = try #require(last.summary)
        #expect(s.frames == chunks.reduce(0) { $0 + $1.samples24k.count })
        #expect(s.audioS > 0.8 && s.audioS < 6)
        #expect(chunks.flatMap(\.samples24k).contains { abs($0) > 0.01 })   // not silence
    }

    @Test(.enabled(if: SystemVoiceTTS.pickVoice(for: .en, among: SystemVoiceTTS.installedVoices()) != nil))
    func cancelEndsTheStream() async {
        let tts = SystemVoiceTTS()
        let text = String(repeating: "This sentence is long enough to be cancelled while it renders. ", count: 6)
        let stream = tts.speak(request(.en, text, job: 9))
        let t0 = ContinuousClock.now
        var n = 0
        do {
            for try await _ in stream {
                n += 1
                if n == 1 { await tts.cancel(9) }
            }
        } catch {}
        #expect(ContinuousClock.now - t0 < .seconds(8))
    }
}
