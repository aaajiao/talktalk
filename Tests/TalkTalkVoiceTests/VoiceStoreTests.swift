import Darwin
import Foundation
import Testing
import TalkTalkAudio
@testable import TalkTalkVoice

func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("talktalk-voice-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("TalkTalk", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func mode(_ url: URL) -> Int {
    var st = stat()
    return lstat(url.path, &st) == 0 ? Int(st.st_mode & 0o777) : -1
}

func excludedFromBackup(_ url: URL) -> Bool {
    let fresh = URL(fileURLWithPath: url.path)
    return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
}

private func sampleReport() -> EnrollmentReport {
    let take = Synth.take(segments: [4.0, 4.5], pauses: [0.6])
    return EnrollmentChecks.evaluate(take: take, noise: Synth.noise(1.5, db: -68), sampleRate: Synth.rate, transcript: nil)
}

private func fill(_ store: VoiceStore, _ staging: URL, profileID: String) throws {
    let report = sampleReport()
    let wav = WAVFile.encodePCM16([0, 0.1, -0.1], sampleRate: 24_000)
    let profile = VoiceProfile(id: profileID, script: .zhV1, wav: wav, report: report, micUID: "BuiltInMicrophoneDevice",
                               durationSeconds: 9.1)
    try store.writeReference(wav, script: .zhV1, profile: profile, into: staging)
}

@Suite struct VoiceStoreTests {
    @Test func stagingIsProtectedFromTheStart() throws {
        let store = VoiceStore(root: try tempRoot())
        let staging = try store.makeStaging()
        #expect(staging.lastPathComponent.hasPrefix(".voice-staging-"))
        #expect(staging.deletingLastPathComponent().path == store.root.path)   // sibling of voice/, never inside it
        #expect(mode(staging) == 0o700)
        #expect(excludedFromBackup(staging))
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent(".metadata_never_index").path))
    }

    @Test func firstSaveRenamesAndKeepsAttributes() throws {
        let store = VoiceStore(root: try tempRoot())
        #expect(!store.hasProfile)
        let staging = try store.makeStaging()
        try fill(store, staging, profileID: "A")
        try store.commit(staging)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        let voice = store.voiceURL
        #expect(mode(voice) == 0o700)
        #expect(excludedFromBackup(voice))
        #expect(FileManager.default.fileExists(atPath: voice.appendingPathComponent(".metadata_never_index").path))
        for name in ["reference.wav", "script.txt", "profile.json", ".metadata_never_index"] {
            #expect(mode(voice.appendingPathComponent(name)) == 0o600, "\(name)")
        }
        #expect(try String(contentsOf: voice.appendingPathComponent("script.txt"), encoding: .utf8) == EnrollmentScript.zhV1.text)
        #expect(try store.loadProfile().id == "A")
    }

    @Test func secondSaveSwapsAtomicallyAndRemovesTheOld() throws {
        let store = VoiceStore(root: try tempRoot())
        let first = try store.makeStaging()
        try fill(store, first, profileID: "A")
        try store.commit(first)
        let second = try store.makeStaging()
        try fill(store, second, profileID: "B")
        try store.writeConditioning(Data([1, 2, 3]), key: "mlx-mlxaudio0.6.1-Qwen/Base@abc-icl-0123", into: second)
        try store.commit(second)
        #expect(try store.loadProfile().id == "B")
        #expect(!FileManager.default.fileExists(atPath: second.path))   // swapped-out old profile deleted
        let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        #expect(!names.contains { $0.hasPrefix(".voice-staging-") })
        #expect(mode(store.voiceURL) == 0o700)
        #expect(excludedFromBackup(store.voiceURL))
        let cond = store.voiceURL.appendingPathComponent("conditioning")
        let blobs = try FileManager.default.contentsOfDirectory(atPath: cond.path)
        #expect(blobs == ["mlx-mlxaudio0.6.1-Qwen_Base@abc-icl-0123.safetensors"])
        #expect(mode(cond.appendingPathComponent(blobs[0])) == 0o600)
    }

    @Test func incompleteStagingNeverReplacesTheProfile() throws {
        let store = VoiceStore(root: try tempRoot())
        let first = try store.makeStaging()
        try fill(store, first, profileID: "A")
        try store.commit(first)
        let broken = try store.makeStaging()
        #expect(throws: VoiceStore.Failure.incomplete("reference.wav")) { try store.commit(broken) }
        #expect(try store.loadProfile().id == "A")
        store.discard(broken)
        #expect(!FileManager.default.fileExists(atPath: broken.path))
    }

    @Test func refusesPathsOutsideItsStaging() throws {
        let store = VoiceStore(root: try tempRoot())
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent(".voice-staging-x")
        #expect(throws: VoiceStore.Failure.notStaging) { try store.commit(elsewhere) }
        #expect(throws: VoiceStore.Failure.notStaging) { try store.commit(store.voiceURL) }
    }

    @Test func deleteRemovesOnlyOurFiles() throws {
        let store = VoiceStore(root: try tempRoot())
        let s = try store.makeStaging()
        try fill(store, s, profileID: "A")
        try store.commit(s)
        try Data("mine".utf8).write(to: store.voiceURL.appendingPathComponent("user-note.txt"))
        store.deleteProfile()
        #expect(!store.hasProfile)
        let left = try FileManager.default.contentsOfDirectory(atPath: store.voiceURL.path)
        #expect(left == ["user-note.txt"])
        try FileManager.default.removeItem(at: store.voiceURL.appendingPathComponent("user-note.txt"))
        store.deleteProfile()
        #expect(!FileManager.default.fileExists(atPath: store.voiceURL.path))
    }

    @Test func staleStagingIsCleanedAtStart() throws {
        let store = VoiceStore(root: try tempRoot())
        let s = try store.makeStaging()
        try fill(store, s, profileID: "A")
        store.removeStaleStaging()
        #expect(!FileManager.default.fileExists(atPath: s.path))
    }

    @Test func profileJSONHasTheDocumentedKeysAndNoText() throws {
        let report = sampleReport()
        let wav = WAVFile.encodePCM16([0.1], sampleRate: 24_000)
        let p = VoiceProfile(script: .zhV1, wav: wav, report: report, micUID: "BuiltInMicrophoneDevice", durationSeconds: 9.1)
        let json = try #require(try JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
        for key in ["version", "id", "created_at", "script_id", "script_sha256", "duration_s", "wav_sha256", "checks",
                    "mode", "references", "use_for", "mic_uid_hash", "speaking_rate_cps", "conditioning", "audition"] {
            #expect(json[key] != nil, "\(key)")
        }
        #expect(json["version"] as? Int == 1)
        #expect(json["script_id"] as? String == "zh-v1")
        #expect((json["mode"] as? [String: String]) == ["en": "icl", "de": "icl"])
        #expect((json["use_for"] as? [String: String]) == ["en": "zh", "de": "zh"])
        #expect((json["references"] as? [String: String]) == ["zh": "reference.wav"])
        #expect((json["mic_uid_hash"] as? String)?.count == 16)
        #expect(json["conditioning"] as? String == "pending_engine")
        let text = String(decoding: try p.encoded(), as: UTF8.self)
        #expect(!text.contains("大家好"))
        #expect(!text.contains("BuiltInMicrophoneDevice"))
        #expect(try VoiceProfile.decode(p.encoded()) == p)
    }
}

/// Fake engine for the save path (§9.2 step 6): the real EngineVoiceServices over a fake backend.
func FakeEngine() -> EngineVoiceServices { services(FakeBackend()) }

@Suite struct SaveTakeTests {
    @Test func endToEndSaveFromASyntheticTake() async throws {
        let store = VoiceStore(root: try tempRoot())
        let take = Synth.take(segments: [4.0, 4.5], pauses: [0.6])
        let noise = Synth.noise(1.5, db: -68)
        let report = EnrollmentChecks.evaluate(take: take, noise: noise, sampleRate: Synth.rate, transcript: nil)
        #expect(report.canSave)
        let profile = try await EnrollmentController.saveTake(
            take: take, noise: noise, sampleRate: Synth.rate, report: report, micUID: "BuiltInMicrophoneDevice",
            script: .zhV1, store: store, engine: nil)
        let wavData = try Data(contentsOf: store.voiceURL.appendingPathComponent("reference.wav"))
        let wav = try #require(WAVFile.decodePCM16(wavData))
        #expect(wav.sampleRate == 24_000)
        #expect(abs(Double(wav.samples.count) / 24_000 - profile.durationSeconds) < 0.01)
        #expect(profile.wavSHA256 == sha256Hex(wavData))
        #expect(profile.conditioning == "pending_engine")
        #expect(profile.checks.status["transcript"] == .pending)
        #expect(abs(profile.speakingRateCharsPerSecond - 42 / 8.9) < 0.1)
        #expect(try store.loadProfile() == profile)
    }

    @Test func engineBlobsLandInConditioning() async throws {
        let store = VoiceStore(root: try tempRoot())
        let take = Synth.take(segments: [4.0, 4.5], pauses: [0.6])
        let noise = Synth.noise(1.5, db: -68)
        let report = EnrollmentChecks.evaluate(take: take, noise: noise, sampleRate: Synth.rate, transcript: nil)
        let profile = try await EnrollmentController.saveTake(
            take: take, noise: noise, sampleRate: Synth.rate, report: report, micUID: "x",
            script: .zhV1, store: store, engine: FakeEngine())
        #expect(profile.conditioning == "built")
        let key = try #require(profile.conditioningEntries?.first?.key)
        let blob = store.voiceURL.appendingPathComponent("conditioning/\(VoiceStore.safeKey(key)).safetensors")
        #expect(mode(blob) == 0o600)
    }

    @Test func failedSaveLeavesNoStagingAndKeepsTheOldProfile() async throws {
        let store = VoiceStore(root: try tempRoot())
        let s = try store.makeStaging()
        try fill(store, s, profileID: "OLD")
        try store.commit(s)
        let silence = Synth.noise(10, db: -70)   // no speech → ReferenceAudio throws
        let report = sampleReport()
        await #expect(throws: ReferenceAudio.Failure.noSpeech) {
            _ = try await EnrollmentController.saveTake(take: silence, noise: Synth.noise(1.5, db: -70), sampleRate: Synth.rate,
                                                        report: report, micUID: "x", script: .zhV1, store: store, engine: nil)
        }
        #expect(try store.loadProfile().id == "OLD")
        let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        #expect(!names.contains { $0.hasPrefix(".voice-staging-") })
    }
}

@Suite struct RecordingDevicePolicyTests {
    private func dev(_ transport: String, rate: Double = 48_000, uid: String = "u", name: String = "Mic",
                     alive: Bool = true, aggregate: Bool = false) -> InputDeviceInfo {
        InputDeviceInfo(objectID: 1, uid: uid, name: name, transport: transport, nominalSampleRate: rate,
                        inputChannels: 1, isAlive: alive, isAggregate: aggregate)
    }

    @Test func acceptsBuiltInAndUSBAtHighRates() {
        #expect(RecordingDevicePolicy.evaluate(dev("bltn", rate: 44_100)) == .accepted)
        #expect(RecordingDevicePolicy.evaluate(dev("usb ", rate: 96_000)) == .accepted)
    }

    @Test func rejectsEverythingElse() {
        #expect(!RecordingDevicePolicy.evaluate(dev("blue", rate: 24_000)).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("blue", rate: 48_000)).isAccepted)   // even at A2DP-like rates
        #expect(!RecordingDevicePolicy.evaluate(dev("blea")).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("virt")).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("grup")).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("usb ", aggregate: true)).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("ccwl")).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("thun")).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("usb ", rate: 24_000)).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("usb ", rate: 32_000)).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("bltn", alive: false)).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("bltn", uid: "com.aaajiao.talktalk.mic")).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("usb ", name: "Microsoft Teams Audio")).isAccepted)
    }

    @Test func prefersBuiltIn() {
        let list = [dev("blue", uid: "bt"), dev("usb ", uid: "usb"), dev("bltn", uid: "mbp")]
        #expect(RecordingDevicePolicy.preferred(list)?.uid == "mbp")
        #expect(RecordingDevicePolicy.preferred([dev("blue", uid: "bt"), dev("usb ", uid: "usb")])?.uid == "usb")
        #expect(RecordingDevicePolicy.preferred([dev("blue")]) == nil)
    }
}

private func step(_ m: inout VoiceEnrollment, _ e: VoiceEnrollment.Event) -> Bool { m.send(e) }

@Suite struct VoiceEnrollmentMachineTests {
    @Test func happyPath() {
        var m = VoiceEnrollment()
        #expect(step(&m, .start))
        #expect(m.phase == .measuringNoise)
        #expect(step(&m, .noiseMeasured))
        #expect(m.phase == .countdown(3))
        m.send(.tick); m.send(.tick)
        #expect(m.phase == .countdown(1))
        m.send(.tick)
        #expect(m.phase == .recording)
        #expect(m.takes == 1)
        #expect(step(&m, .stopped))
        let report = sampleReport()
        #expect(step(&m, .analyzed(report)))
        #expect(step(&m, .save))
        #expect(m.phase == .saving)
        #expect(step(&m, .saved))
        #expect(m.phase == .saved)
    }

    @Test func rejectedTakeCannotBeSavedButCanBeRetaken() {
        var m = VoiceEnrollment()
        m.send(.start); m.send(.noiseMeasured); m.send(.tick); m.send(.tick); m.send(.tick); m.send(.stopped)
        var bad = sampleReport()
        bad.results.append(CheckResult(id: .clipping, status: .reject, value: 0.01, message: "声音过大，请离远一点"))
        m.send(.analyzed(bad))
        #expect(!step(&m, .save))
        #expect(step(&m, .retake))
        #expect(m.phase == .measuringNoise)
        m.send(.noiseMeasured); m.send(.tick); m.send(.tick); m.send(.tick)
        #expect(m.takes == 2)
    }

    @Test func illegalEventsAreIgnored() {
        var m = VoiceEnrollment()
        #expect(!step(&m, .stopped))
        #expect(!step(&m, .save))
        #expect(!step(&m, .tick))
        #expect(m.phase == .idle)
    }

    @Test func failureAndCancel() {
        var m = VoiceEnrollment()
        m.send(.start); m.send(.noiseMeasured)
        #expect(step(&m, .failed("麦克风断开了")))
        #expect(m.phase == .failed("麦克风断开了"))
        #expect(step(&m, .start))
        #expect(step(&m, .cancel))
        #expect(m.phase == .idle)
        #expect(!m.phase.capturing)
    }
}
