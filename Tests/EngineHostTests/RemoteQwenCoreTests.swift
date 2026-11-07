import Foundation
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore
@testable import TalkTalkEngineHost

/// RemoteQwenASR as `ClipASREngine` and RemoteQwenTTS as `TTSEngine` (§4.1) against the fake engine.
@Suite(.serialized, .temporaryFiles) struct RemoteQwenCoreTests {
    static func handle() -> VoiceHandle {
        VoiceHandle(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, conditioningKey: "k",
                    mode: .icl, model: EngineID(name: "tts-x", revision: EngineHostTests.ttsRev, placement: .engineGPU))
    }

    @Test func computeRTFExcludesHTTPAndHorizonWaiting() throws {
        let tail = try JSONDecoder().decode(EngineTTSTail.self, from: Data(#"{"audio_s":2,"frames":48000,"context_used":true,"timing":{"gpu_ms_all_attempts":1000}}"#.utf8))
        let summary = RemoteQwenTTS.summary(tail, timing: .init(received: 0, started: 0, firstOutput: 0, finished: 10_000_000_000))
        #expect(summary.computeRTF == 0.5)
        #expect(summary.contextUsed == true)
        let request = EngineTTSRequest(text: "Next sentence.", lang: "en", voiceKey: "real-voice-key",
                                       contextID: "turn-1", previousJob: "tts-4")
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(wire["context_id"] as? String == "turn-1")
        #expect(wire["previous_job"] as? String == "tts-4")
        #expect(wire["voice_key"] as? String == "real-voice-key")
    }

    @Test func ids() throws {
        let box = try EngineHostTests.Sandbox()
        let e = EngineProcess(config: try box.config())
        #expect(RemoteQwenTTS(engine: e).id == EngineID(name: "tts-x", revision: EngineHostTests.ttsRev, placement: .engineGPU))
        #expect(RemoteQwenASR(engine: e).id == EngineID(name: "asr-y", revision: EngineHostTests.asrRev, placement: .engineGPU))
        #expect(RemoteQwenTTS(engine: e).outputRate == 24_000)
    }

    @Test func clipASR() async throws {
        let box = try EngineHostTests.Sandbox()
        let e = EngineProcess(config: try box.config())
        let asr = RemoteQwenASR(engine: e)
        let clip = PCMClip16k(samples: [Float](repeating: 0, count: 1600), start: 1, end: 2)
        let r = try await asr.transcribe(clip, hint: .de, context: "vorher", job: 42, priority: .p2Listen,
                                         deadline: HostClock.now() + 5_000_000_000)
        #expect(r.text == "今天十点开会")
        #expect(r.language == .de)             // the fake echoes the hint
        #expect(r.timing.finished >= r.timing.started && r.timing.started >= r.timing.received)
        await #expect(throws: RemoteEngineError.deadlineExceeded) {
            try await asr.transcribe(clip, hint: .en, context: nil, job: 43, priority: .p2Listen, deadline: HostClock.now())
        }
        await asr.cancel(44)
        await e.stop()
        #expect(box.file("cancels.txt").contains("asr-44"))
    }

    @Test func languageNames() {
        #expect(RemoteQwenASR.lang("English") == .en)
        #expect(RemoteQwenASR.lang("German") == .de)
        #expect(RemoteQwenASR.lang("zh") == .zh)
        #expect(RemoteQwenASR.lang("Japanese") == nil)
        #expect(RemoteQwenASR.lang(nil) == nil)
    }

    @Test func clipDeadlineIncludesColdReadyWithoutStoppingWarmup() async throws {
        let box = try EngineHostTests.Sandbox()
        let e = EngineProcess(config: try box.config(extra: ["--ready-delay", "2"]))
        let warmup = Task { try await e.start() }
        try await EngineHostTests.waitFor(e) { if case .starting = $0 { true } else { false } }
        let asr = RemoteQwenASR(engine: e)
        let clip = PCMClip16k(samples: [Float](repeating: 0, count: 1600), start: 1, end: 2)
        let start = ContinuousClock.now
        await #expect(throws: RemoteEngineError.deadlineExceeded) {
            try await asr.transcribe(clip, hint: .zh, context: nil, job: 45, priority: .p1Speak,
                                     deadline: HostClock.now() + 100_000_000)
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        if case .starting = await e.status { } else { Issue.record("ASR timeout changed global warmup") }
        _ = try await warmup.value
        #expect(await e.launches == 1)
        let result = try await asr.transcribe(clip, hint: .zh, context: nil, job: 46, priority: .p1Speak,
                                               deadline: HostClock.now() + 5_000_000_000)
        #expect(result.text == "今天十点开会")
        await e.stop()
    }

    @Test func ttsChunksEndWithSummary() async throws {
        let box = try EngineHostTests.Sandbox()
        let e = EngineProcess(config: try box.config(extra: ["--tts-chunks", "3", "--tts-chunk-ms", "5", "--require-voice-key"]))
        let tts = RemoteQwenTTS(engine: e)
        let blob = try await tts.buildConditioning(
            VoiceReference(pcm24k: Data(repeating: 0, count: 4 * 2400), text: "参考", lang: .zh),
            model: Self.handle().model, mode: .icl)
        #expect(!blob.isEmpty)
        try await tts.load(Self.handle(), blob: blob)

        let req = TTSRequest(job: 7, clause: 1, text: "Good morning.", language: .en, voice: Self.handle(),
                             seed: 3, wholeClause: false)
        var chunks: [TTSChunk] = []
        for try await c in tts.speak(req) { chunks.append(c) }
        #expect(chunks.map(\.seq) == [0, 1, 2, 3])
        #expect(chunks.dropLast().allSatisfy { !$0.isLast && $0.samples24k.count == 1920 && $0.summary == nil })
        let last = try #require(chunks.last)
        #expect(last.isLast && last.samples24k.isEmpty)
        let s = try #require(last.summary)
        #expect(s.frames == 6 && abs(s.audioS - 0.24) < 1e-9 && !s.runaway && s.attempts == 1)
        #expect(s.timing.firstOutput != nil)
        #expect(chunks.allSatisfy { $0.job == 7 })

        let fail = TTSRequest(job: 8, clause: 2, text: "fail please", language: .de, voice: Self.handle(), seed: 1, wholeClause: false)
        await #expect(throws: RemoteEngineError.tts(code: "tts_failed", message: "RuntimeError")) {
            for try await _ in tts.speak(fail) {}
        }
        await tts.cancel(9)
        await tts.report(PlayoutReport(job: 7, bufferedMs: 320, underruns: 0, paused: false, tempo: 1, epoch: 1, at: 0))
        await e.stop()
        #expect(box.file("cancels.txt").contains("tts-9"))
    }

    @Test func referenceBytes() {
        let f: [Float] = [0, 0.5, -0.25]
        let raw = f.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(RemoteQwenTTS.samples(raw) == f)
        #expect(RemoteQwenTTS.samples(Data([1, 2, 3])) == nil)

        // PCM16 mono 24 kHz WAV with an extra chunk before "data".
        var w = Data("RIFF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { w.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { w.append(contentsOf: $0) } }
        u32(0); w.append(contentsOf: Array("WAVE".utf8))
        w.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        w.append(contentsOf: Array("LIST".utf8)); u32(3); w.append(contentsOf: [0, 0, 0, 0])   // odd size + pad byte
        w.append(contentsOf: Array("data".utf8)); u32(4); u16(UInt16(bitPattern: 16384)); u16(UInt16(bitPattern: -32768))
        #expect(RemoteQwenTTS.samples(w) == [0.5, -1])

        var w16k = w
        w16k.replaceSubrange(24..<28, with: [0x80, 0x3E, 0, 0])   // 16000 Hz is refused
        #expect(RemoteQwenTTS.samples(w16k) == nil)
    }

    @Test func readyForAnotherVoiceDoesNotCompleteLoad() async throws {
        let box = try EngineHostTests.Sandbox()
        let e = EngineProcess(config: try box.config("voice-key-mismatch"))
        await #expect(throws: RemoteEngineError.tts(code: "voice_key_mismatch", message: "loaded voice does not match the requested voice")) {
            try await RemoteQwenTTS(engine: e).load(Self.handle(), blob: Data([1]))
        }
        await e.stop()
    }
}
