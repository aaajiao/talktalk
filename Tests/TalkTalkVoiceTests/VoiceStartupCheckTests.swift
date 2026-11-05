import Darwin
import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkVoice

/// §7.5 item 4 (m1-engine).
@Suite struct VoiceStartupCheckTests {
    static let rev = "e7dd05856522aaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func saved() throws -> VoiceStore {
        let store = VoiceStore(root: try tempRoot())
        let staging = try store.makeStaging()
        let take = Synth.take(segments: [4.0, 4.5], pauses: [0.6])
        let report = EnrollmentChecks.evaluate(take: take, noise: Synth.noise(1.5, db: -68), sampleRate: Synth.rate, transcript: nil)
        let wav = WAVFile.encodePCM16([0, 0.1, -0.1], sampleRate: 24_000)
        let profile = VoiceProfile(script: .zhV1, wav: wav, report: report, micUID: "BuiltInMicrophoneDevice", durationSeconds: 9.1)
        try store.writeReference(wav, script: .zhV1, profile: profile, into: staging)
        try store.commit(staging)
        return store
    }

    func check(_ store: VoiceStore) -> VoiceStartupCheck {
        VoiceStartupCheck(store: store, runtime: "python-mlx", ttsKey: "tts-qwen3-1.7b-base-8bit", ttsRev: Self.rev)
    }

    @Test func noProfileIsANotice() async throws {
        let r = await check(VoiceStore(root: try tempRoot())).run()
        #expect(r.level == .notice)
    }

    @Test func savedProfileIsOkAndConditioningMissing() async throws {
        let r = await check(try saved()).run()
        #expect(r.level == .ok)
        #expect(r.details["conditioning"] == "missing")
        #expect(r.details["permissions_fixed"] == nil)
    }

    @Test func conditioningCurrentOrStale() async throws {
        let store = try saved()
        let key = "python-mlx-mlxaudio0.3.2-tts-qwen3-1.7b-base-8bit@e7dd05856522-icl-0123456789abcdef"
        try store.writeConditioning(Data([1]), key: "python-mlx-mlxaudio0.3.2-tts-qwen3-1.7b-base-8bit@ffffffffffff-icl-0123", into: store.voiceURL)
        #expect(await check(store).run().details["conditioning"] == "stale")
        try store.writeConditioning(Data([1]), key: key, into: store.voiceURL)
        #expect(await check(store).run().details["conditioning"] == "current")
        let noEngine = VoiceStartupCheck(store: store, record: nil)
        #expect(await noEngine.run().details["conditioning"] == "unknown")
    }

    @Test func permissionsAreRepaired() async throws {
        let store = try saved()
        let voice = store.voiceURL
        chmod(voice.path, 0o755)
        chmod(voice.appendingPathComponent("reference.wav").path, 0o644)
        let r = await check(store).run()
        #expect(r.level == .ok)
        #expect(r.details["permissions_fixed"] == "2")
        #expect(mode(voice) == 0o700)
        #expect(mode(voice.appendingPathComponent("reference.wav")) == 0o600)
    }

    @Test func missingFilesAndBadProfileNeedAction() async throws {
        let store = try saved()
        try FileManager.default.removeItem(at: store.voiceURL.appendingPathComponent("reference.wav"))
        let r = await check(store).run()
        #expect(r.level == .action)
        #expect(r.details["missing"] == "reference.wav")

        try Data("{".utf8).write(to: store.voiceURL.appendingPathComponent("profile.json"))
        #expect(await check(store).run().level == .action)
    }
}
