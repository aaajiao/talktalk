import Darwin
import Foundation
import Testing
import TalkTalkAudio
import TalkTalkCore
import TalkTalkEngineHost
import TalkTalkTestSupport
@testable import TalkTalkVoice

// voice-m2: engine half of enrollment (build per model × mode, audition checks with one
// regeneration, read-back WER), gains, deletion (§9.4), transcript re-check, lifecycle.

func sine(_ seconds: Double, amplitude: Float = 0.1, hz: Double = 1000, rate: Double = 24_000) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

/// Scripted engine. `takes[lang]` is consumed one synthesis at a time (the last one repeats).
/// `events` logs build / load / unload in order; `holdLoads` parks loads until `releaseLoads()`.
actor FakeBackend: VoiceEngineBackend {
    struct Take: Sendable {
        var seconds: Double
        var readback: String?
        var runaway = false
        var short = false
        var expected: Double? = 4
        /// Peak of the synthesized sine (loudness → playout gain).
        var amplitude: Float = 0.1
    }

    var models = ["qwen3-tts-1.7b-base-8bit"]
    var runtime = "rt"
    var mlxAudio: String? = "0.6.4"
    var rev = "abcdef1234567890"
    var takes: [Lang: [Take]] = [:]
    var buildError: (any Error)?
    var loadError: (any Error)?
    var synthError: (any Error)?
    var readbackError: (any Error)?
    var ready = EngineReadiness(running: true, asr: .ready)
    /// Readiness answers to hand out first (then `ready`).
    var readinessScript: [EngineReadiness] = []
    private(set) var builds: [(model: String, mode: CloneMode)] = []
    private(set) var loads: [String] = []
    private(set) var unloads = 0
    private(set) var events: [String] = []
    private(set) var seeds: [Lang: [Int]] = [:]
    private(set) var zhTranscripts = 0
    private(set) var finished = 0
    var zhText: String? = EnrollmentScript.zhV1.text
    var similarity: Double? = 0.97
    private var holdLoads = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private(set) var parkedCount = 0

    init(takes: [Lang: [Take]] = [:]) {
        self.takes = takes
    }

    func set(takes: [Lang: [Take]]) { self.takes = takes }
    func set(buildError: (any Error)?) { self.buildError = buildError }
    func set(loadError: (any Error)?) { self.loadError = loadError }
    func set(synthError: (any Error)?) { self.synthError = synthError }
    func set(readbackError: (any Error)?) { self.readbackError = readbackError }
    func set(models: [String]) { self.models = models }
    func set(rev: String) { self.rev = rev }
    func set(ready: EngineReadiness, script: [EngineReadiness] = []) { self.ready = ready; readinessScript = script }
    func hold() { holdLoads = true }
    func releaseLoads() {
        holdLoads = false
        parked.forEach { $0.resume() }
        parked = []
    }

    func identity() async throws -> ConditioningIdentity {
        ConditioningIdentity(runtime: runtime, mlxAudio: mlxAudio, models: models.map { ($0, rev) })
    }

    func readiness() async -> EngineReadiness {
        readinessScript.isEmpty ? ready : readinessScript.removeFirst()
    }

    func enrollmentFinished() async { finished += 1; events.append("finished") }
    func enrollmentStarted() async { events.append("started") }

    func build(reference24k: [Float], refText: String, model: String, mode: CloneMode) async throws -> (key: String, blob: Data) {
        if let buildError { throw buildError }
        builds.append((model, mode))
        events.append("build")
        return ("\(runtime)-mlxaudio\(mlxAudio ?? "x")-\(model)@\(rev.prefix(12))-\(mode.rawValue)-0123456789abcdef",
                Data([UInt8](model.utf8)))
    }

    func load(blob: Data, model: String, key: String, mode: CloneMode, profileID: UUID) async throws {
        if holdLoads {
            parkedCount += 1
            await withCheckedContinuation { parked.append($0) }
        }
        if let loadError { throw loadError }
        loads.append(key)
        events.append("load")
    }

    func unload() async throws -> Bool {
        unloads += 1
        events.append("unload")
        return true
    }

    private var current: [Lang: String] = [:]

    func synthesize(text: String, lang: Lang, seed: Int) async throws -> VoiceSynthesis {
        if let synthError { throw synthError }
        seeds[lang, default: []].append(seed)
        let list = takes[lang] ?? [Take(seconds: 4, readback: text)]
        let i = min((seeds[lang]?.count ?? 1) - 1, list.count - 1)
        let t = list[i]
        current[lang] = t.readback
        return VoiceSynthesis(samples: sine(t.seconds, amplitude: t.amplitude, hz: lang == .en ? 1000 : 1001), runaway: t.runaway,
                              short: t.short, expectedSeconds: t.expected)
    }

    func transcribe(samples16k: [Float], hint: Lang) async throws -> String {
        if hint == .zh {
            zhTranscripts += 1
            guard let zhText else { throw CancellationError() }
            return zhText
        }
        if let readbackError { throw readbackError }
        // en/de read-back: the readback of the latest synthesis in that language (1000/1001 Hz).
        return current[hint] ?? ""
    }

    func speakerSimilarity(reference24k: [Float], sample24k: [Float]) async throws -> Double? { similarity }
}

struct FakeEngineError: Error {}

func services(_ b: FakeBackend) -> EngineVoiceServices {
    EngineVoiceServices(backend: b, to16k: { x, _ in x }, asrWait: .milliseconds(200), asrPoll: .milliseconds(10))
}

let referenceWAV = WAVFile.encodePCM16(sine(9, amplitude: 0.05, hz: 180), sampleRate: 24_000)
let enText = AuditionCheck.sentences[.en]!
let deText = AuditionCheck.sentences[.de]!

@Suite struct WordErrorRateTests {
    @Test func normalizesCaseAndPunctuation() {
        #expect(WordErrorRate.compute(hypothesis: "thanks everyone let me quickly walk you through where the project stands today",
                                      reference: enText) == 0)
        #expect(WordErrorRate.compute(hypothesis: "Danke Ihnen allen ich gebe Ihnen kurz einen überblick über den aktuellen Stand des Projekts",
                                      reference: deText) == 0)
    }

    @Test func countsSubstitutionsInsertionsDeletions() {
        // 13 reference words; 1 substitution + 1 deletion = 2/13.
        #expect(WordErrorRate.words(enText).count == 13)
        let w = WordErrorRate.compute(hypothesis: "Thanks everyone. Let me quickly walk you through where the project stand", reference: enText)
        #expect(abs(w - 2.0 / 13) < 1e-9)
        #expect(WordErrorRate.compute(hypothesis: "", reference: "a b") == 1)
        #expect(WordErrorRate.compute(hypothesis: "a b c", reference: "a b") == 0.5)
    }
}

@Suite struct AuditionCheckTests {
    @Test func rules() {
        let ok = AuditionCheck.Take(audioSeconds: 4, expectedSeconds: 4, readback: enText)
        #expect(AuditionCheck.evaluate(ok, text: enText).failure == nil)
        #expect(AuditionCheck.evaluate(ok, text: enText).wer == 0)
        // runaway: engine flag, or longer than 3 × expected + 2 s
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 4, expectedSeconds: 4, engineRunaway: true, readback: enText), text: enText).failure == .runaway)
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 14.1, expectedSeconds: 4, readback: enText), text: enText).failure == .runaway)
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 13.9, expectedSeconds: 4, readback: enText), text: enText).failure == nil)
        // short: engine flag, or below 0.4 × expected
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 1.5, expectedSeconds: 4, readback: enText), text: enText).failure == .short)
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 4, expectedSeconds: 4, engineShort: true, readback: enText), text: enText).failure == .short)
        // WER ≤ 15 % over 13 words: 1/13 = 7.7 % passes, 2/13 = 15.4 % fails
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 4, expectedSeconds: 4,
                                             readback: "Thanks everyone. Let me quickly walk you through where the project stands"), text: enText).failure == nil)
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 4, expectedSeconds: 4,
                                             readback: "Thanks everyone. Let me quickly walk you through where the project stand"), text: enText).failure == .wer)
        // No read-back (no ASR role): not measured, never a rejection.
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 4, expectedSeconds: 4, readback: nil), text: enText) == (nil, nil))
        #expect(AuditionCheck.evaluate(.init(audioSeconds: 0, expectedSeconds: 4, readback: enText), text: enText).failure == .empty)
    }
}

@Suite struct EngineVoiceServicesTests {
    @Test func buildsOncePerModelAndMode() async throws {
        let b = FakeBackend()
        await b.set(models: ["m-1.7b", "m-0.6b"])
        let blobs = try await services(b).buildConditioning(referenceWAV: referenceWAV, scriptText: "稿子", modes: [.icl, .icl])
        #expect(blobs.map(\.model) == ["m-1.7b", "m-0.6b"])
        #expect(blobs.allSatisfy { $0.mode == .icl && $0.key.contains("-icl-") })
        #expect(await b.builds.count == 2)
    }

    @Test func rejectsAReferenceThatIsNot24kPCM16() async {
        await #expect(throws: VoiceEngineError.badReference) {
            _ = try await services(FakeBackend()).buildConditioning(
                referenceWAV: WAVFile.encodePCM16([0, 0.1], sampleRate: 48_000), scriptText: "x", modes: [.icl])
        }
    }

    private func blobs(_ b: FakeBackend) async throws -> [ConditioningBlob] {
        try await services(b).buildConditioning(referenceWAV: referenceWAV, scriptText: "x", modes: [.icl])
    }

    @Test func passesFirstTimeAndCalibratesThePlayoutGain() async throws {
        let b = FakeBackend()
        let conditioning = try await blobs(b), id = UUID()
        let a = try await services(b).audition(conditioning: conditioning, modes: [.en: .icl, .de: .icl],
                                               profileID: id.uuidString, referenceWAV: referenceWAV)
        let blob = try #require(conditioning.first)
        let handle = VoiceHandle(profileID: id, conditioningKey: blob.key, mode: .icl,
                                 model: .init(name: blob.model, revision: "", placement: .engineGPU))
        for language in [Lang.en, .de] {
            #expect(await b.seeds[language]?.first == Int(TTSSeed.make(voice: handle, language: language)))
        }
        #expect(a.passed)
        #expect(a.clips.map(\.lang) == [.en, .de])
        #expect(a.clips.allSatisfy { $0.attempts == 1 && $0.wer == 0 && $0.similarity == 0.97 })
        // 1 kHz sine at 0.1 peak ≈ −23 LUFS → +3 dB to reach −20 LUFS.
        let g = try #require(a.playoutGainDb)
        #expect(abs(g - 3.0) <= 0.3)
        #expect(await b.loads.count == 1)   // same ICL blob for en and de: loaded once
    }

    @Test func runawayIsRegeneratedOnceWithTheNextSeed() async throws {
        let b = FakeBackend(takes: [.en: [.init(seconds: 15, readback: enText), .init(seconds: 4, readback: enText)]])
        let a = try await services(b).audition(conditioning: try await blobs(b), modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        #expect(a.passed)
        #expect(a.clip(.en)?.attempts == 2)
        #expect(a.clip(.de)?.attempts == 1)
        let seeds = try #require(await b.seeds[.en])
        #expect(seeds.count == 2 && seeds[0] != seeds[1])
        #expect(seeds[1] == Int(TTSSeed.next(UInt32(seeds[0]), attempt: 1)))
    }

    @Test func shortTwiceFailsAndSuggestsReRecording() async throws {
        let b = FakeBackend(takes: [.de: [.init(seconds: 1, readback: deText)]])
        let a = try await services(b).audition(conditioning: try await blobs(b), modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        #expect(!a.passed)
        #expect(a.clip(.de)?.failure == .short)
        #expect(a.clip(.de)?.attempts == AuditionCheck.maxAttempts)
        #expect(await b.seeds[.de]?.count == 2)          // exactly one regeneration
        let failureText = try #require(a.summary.failureText)
        // The behavior is the failing language and reason, in either supported UI language.
        #expect(failureText.contains(Lang.de.title))
        #expect(failureText.contains(AuditionCheck.Failure.short.text))
    }

    @Test func badReadBackIsRegenerated() async throws {
        let b = FakeBackend(takes: [.en: [.init(seconds: 4, readback: "thanks every one lead me walk"), .init(seconds: 4, readback: enText)]])
        let a = try await services(b).audition(conditioning: try await blobs(b), modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        #expect(a.passed)
        #expect(a.clip(.en)?.attempts == 2)
        #expect(a.clip(.en)?.wer == 0)
    }

    @Test func werAboveFifteenPercentTwiceFails() async throws {
        // The failing en clip is much louder (0.5 peak ≈ −9 LUFS): if it counted, the gain would
        // be about −8 dB. Measured on the passing de clip only (0.1 peak ≈ −23 LUFS → +3 dB).
        let b = FakeBackend(takes: [.en: [.init(seconds: 4, readback: "thanks everyone", amplitude: 0.5)]])
        let a = try await services(b).audition(conditioning: try await blobs(b), modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        #expect(a.clip(.en)?.failure == .wer)
        #expect((a.clip(.en)?.wer ?? 0) > AuditionCheck.maxWER)
        let g = try #require(a.playoutGainDb)
        #expect(abs(g - 3.0) <= 0.3)
    }

    @Test func noPassingClipMeansNoPlayoutGain() async throws {
        let b = FakeBackend(takes: [.en: [.init(seconds: 4, readback: "thanks everyone", amplitude: 0.5)],
                                    .de: [.init(seconds: 1, readback: deText, amplitude: 0.3)]])
        let a = try await services(b).audition(conditioning: try await blobs(b), modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        #expect(!a.passed)
        #expect(a.playoutGainDb == nil)
    }

    // Review fix "engine errors vs check results".
    @Test func withoutAnASRRoleWERIsPendingNotARejection() async throws {
        let b = FakeBackend(takes: [.en: [.init(seconds: 4, readback: "nonsense")]])
        await b.set(ready: EngineReadiness(running: true, asr: .absent))
        let a = try await services(b).audition(conditioning: try await blobs(b), modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        #expect(a.passed)
        #expect(a.clips.allSatisfy { $0.wer == nil && $0.werPending && $0.attempts == 1 })
        #expect(a.summary.clips.allSatisfy { $0.werPending == true })
    }

    @Test func aLoadingASRIsWaitedFor() async throws {
        let b = FakeBackend()
        let loading = EngineReadiness(running: true, asr: .loading)
        await b.set(ready: EngineReadiness(running: true, asr: .ready), script: [loading, loading, loading])
        let svc = EngineVoiceServices(backend: b, to16k: { x, _ in x }, asrWait: .seconds(10), asrPoll: .milliseconds(1))
        let a = try await svc.audition(conditioning: try await blobs(b), modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        #expect(a.passed && a.clips.allSatisfy { $0.wer == 0 && !$0.werPending })
    }

    @Test func anASRThatStaysLoadingIsAnEngineError() async throws {
        let b = FakeBackend()
        await b.set(ready: EngineReadiness(running: true, asr: .loading))
        let bl = try await blobs(b)
        await #expect(throws: VoiceEngineError.asrNotReady) {
            _ = try await services(b).audition(conditioning: bl, modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        }
    }

    @Test func aReadBackErrorIsAnEngineErrorNotAFailedCheck() async throws {
        let b = FakeBackend()
        await b.set(readbackError: FakeEngineError())
        let bl = try await blobs(b)
        await #expect(throws: FakeEngineError.self) {
            _ = try await services(b).audition(conditioning: bl, modes: [.en: .icl, .de: .icl],
                                               profileID: UUID().uuidString, referenceWAV: referenceWAV)
        }
    }

    @Test func summaryCarriesNoSamplesOrText() throws {
        let a = AuditionResult(clips: [AuditionClip(lang: .en, text: enText, samples: [0.5, 0.25], attempts: 1)], playoutGainDb: 1)
        let json = String(decoding: try JSONEncoder().encode(a.summary), as: UTF8.self)
        #expect(!json.contains("Thanks"))
        #expect(!json.contains("0.25"))
    }
}

@Suite struct GainTests {
    @Test func bs1770OnASine() throws {
        // 0 dBFS 1 kHz sine reads −3.01 LUFS; −20 dB → −23.01.
        let l48 = try #require(Loudness.integrated([sine(3, amplitude: 0.1, rate: 48_000)], sampleRate: 48_000))
        #expect(abs(l48 - -23.01) < 0.1)
        let l24 = try #require(Loudness.integrated([sine(3, amplitude: 0.1)], sampleRate: 24_000))
        #expect(abs(l24 - -23.01) < 0.2)
        #expect(Loudness.integrated([[Float](repeating: 0, count: 48_000)], sampleRate: 24_000) == nil)
        #expect(Loudness.integrated([sine(0.2)], sampleRate: 24_000) == nil)   // shorter than one block
    }

    @Test func playoutGainIsBounded() throws {
        #expect(VoiceGains.playoutGainDb(auditionClips: [sine(3, amplitude: 0.001)]) == 12)
        #expect(VoiceGains.playoutGainDb(auditionClips: [sine(3, amplitude: 0.9)]) == -12)   // ≈ −3.9 LUFS → −16 dB, bounded at −12
    }

    @Test func passthroughGainFollowsSection38() {
        #expect(VoiceGains.passthroughGainDb(rawSpeechRmsDbfs: -30) == 10)
        #expect(VoiceGains.passthroughGainDb(rawSpeechRmsDbfs: -50) == 18)
        #expect(VoiceGains.passthroughGainDb(rawSpeechRmsDbfs: -5) == -6)
        #expect(VoiceGains.passthroughGainDb(rawSpeechRmsDbfs: -22.04) == 2)
    }

    @Test func inMemoryStore() {
        let s = InMemoryPassthroughGainStore()
        s.setGainDb(4, micUIDHash: "a")
        s.setGainDb(-2, micUIDHash: "b")
        #expect(s.gainDb(micUIDHash: "a") == 4)
        s.removeAll()
        #expect(s.gainDb(micUIDHash: "a") == nil && s.all.isEmpty)
    }
}

/// A TTSEngine that only has an id (routing tests never synthesize).
struct NamedTTS: TTSEngine {
    let id: EngineID
    init(_ name: String) { id = EngineID(name: name, revision: "", placement: .engineGPU) }
    var outputRate: Double { 24_000 }
    func buildConditioning(_ ref: VoiceReference, model: EngineID, mode: CloneMode) async throws -> Data { Data() }
    func load(_ voice: VoiceHandle, blob: Data) async throws {}
    func speak(_ r: TTSRequest) -> AsyncThrowingStream<TTSChunk, any Error> { AsyncThrowingStream { $0.finish() } }
    func report(_ p: PlayoutReport) async {}
    func cancel(_ job: JobID) async {}
}

private func savedReport() -> EnrollmentReport {
    EnrollmentChecks.evaluate(take: Synth.take(segments: [6.0, 6.5], pauses: [0.6]), noise: Synth.noise(1.5, db: -68),
                              sampleRate: Synth.rate, transcript: nil)
}

/// Saves a profile through the real controller statics (no engine: reference + script + profile).
private func saveProfile(_ store: VoiceStore, engine: (any VoiceEngineServices)? = nil) async throws -> VoiceProfile {
    try await EnrollmentController.saveTake(take: Synth.take(segments: [6.0, 6.5], pauses: [0.6]), noise: Synth.noise(1.5, db: -68),
                                            sampleRate: Synth.rate, report: savedReport(), micUID: "BuiltInMicrophoneDevice",
                                            script: .zhV1, store: store, engine: engine)
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [SpeakVoiceRouting.Source] = []
    func add(_ s: SpeakVoiceRouting.Source) { lock.withLock { v.append(s) } }
    var values: [SpeakVoiceRouting.Source] { lock.withLock { v } }
}

@Suite(.temporaryFiles) struct DeletionTests {
    @Test func deleteSwitchesSpeakToTheSystemVoiceInTheSameSessionAndClearsGains() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let engine = services(b)
        let p = try await saveProfile(store, engine: engine)
        #expect(p.conditioning == "built")
        // Someone else's file in voice/ must survive (only our names are deleted).
        try Data("x".utf8).write(to: store.voiceURL.appendingPathComponent("not-ours.txt"))

        let clone = NamedTTS("qwen"), system = NamedTTS("system-voice")
        let routing = SpeakVoiceRouting(clone: clone, system: system)
        let gains = InMemoryPassthroughGainStore([p.micUIDHash: 2, "other-mic": 5])
        let lifecycle = await VoiceLifecycle(store: store, engine: engine, monitor: RecordingAuditionMonitor(),
                                             routing: routing, passthroughGains: gains)
        await lifecycle.voiceReady()
        #expect(routing.engine.id == clone.id)
        #expect(routing.hudLabel == "我的声音")
        let seen = Flag()
        routing.observe { seen.add($0) }

        let unloadsBefore = await b.unloads
        let out = await lifecycle.delete()
        #expect(out.filesRemoved && out.engineUnloaded)
        #expect(await b.unloads == unloadsBefore + 1)
        #expect(await b.events.last == "unload")
        // The very next clause of the running session goes to the system voice.
        #expect(routing.engine.id == system.id)
        #expect(routing.voice == nil)
        #expect(routing.hudLabel == "系统声音")
        #expect(routing.playoutGainDb == 0)
        #expect(seen.values == [.systemVoice])
        #expect(gains.all.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: store.voiceURL.path)
        #expect(left == ["not-ours.txt"])
        #expect(!store.hasProfile)
    }

    @Test func deleteWithoutAnEngineStillRemovesAndReroutes() async throws {
        let store = VoiceStore(root: try tempRoot())
        _ = try await saveProfile(store)
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"),
                                        source: .myVoice(VoiceHandle(profileID: UUID(), conditioningKey: "k", mode: .icl,
                                                                     model: NamedTTS("q").id), playoutGainDb: 1.5))
        let gains = InMemoryPassthroughGainStore(["m": 3])
        let out = await VoiceDeletion(store: store, engine: nil, routing: routing, passthroughGains: gains).run()
        #expect(out == .init(filesRemoved: true, engineUnloaded: false))
        #expect(routing.source == .systemVoice && gains.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.voiceURL.path))
    }
}

@Suite(.temporaryFiles) struct CandidateTests {
    @Test func buildAuditionCommitSwapsOverTheOldProfileWithAttributes() async throws {
        let store = VoiceStore(root: try tempRoot())
        let old = try await saveProfile(store)
        let b = FakeBackend()
        var c = try EnrollmentController.prepareCandidate(take: Synth.take(segments: [6.0, 6.5], pauses: [0.6]), sampleRate: Synth.rate,
                                                          report: savedReport(), micUID: "USB-MIC-1", script: .zhV1, store: store)
        // Staging is protected from the moment it exists.
        #expect(mode(c.staging) == 0o700 && excludedFromBackup(c.staging))
        c = try await EnrollmentController.buildAndAudition(c, engine: services(b), script: .zhV1, store: store)
        #expect(try store.loadProfile().id == old.id)   // still the old one until commit
        try EnrollmentController.commitCandidate(c, script: .zhV1, store: store)

        let p = try store.loadProfile()
        #expect(p.id == c.profile.id && p.id != old.id)
        #expect(p.conditioning == "built" && p.audition == "passed")
        #expect(p.conditioningEntries?.count == 1)
        #expect(p.checks.status["audition"] == .pass)
        #expect(abs((p.playoutGainDb ?? 0) - 3) <= 0.3)
        // Passthrough gain from the raw speech RMS (Synth speech is −22 dBFS → +2 dB).
        #expect(abs(c.passthroughGainDb - 2) <= 0.5)
        #expect(mode(store.voiceURL) == 0o700 && excludedFromBackup(store.voiceURL))
        for f in ["reference.wav", "script.txt", "profile.json"] { #expect(mode(store.voiceURL.appendingPathComponent(f)) == 0o600) }
        let blob = try #require(try FileManager.default.contentsOfDirectory(atPath: store.voiceURL.appendingPathComponent("conditioning").path).first)
        #expect(mode(store.voiceURL.appendingPathComponent("conditioning/\(blob)")) == 0o600)
        #expect(FileManager.default.fileExists(atPath: store.voiceURL.appendingPathComponent(".metadata_never_index").path))
        // RENAME_SWAP left no staging and no old profile behind.
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: store.root.path)).contains { $0.hasPrefix(".voice-staging-") })
        // The saved blobs read back for /v1/voice/load.
        #expect(store.loadConditioning(p).map(\.key) == p.conditioningEntries?.map(\.key))
    }

    @Test func engineErrorStillSavesWithPendingEngine() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        await b.set(buildError: CancellationError())
        let p = try await saveProfile(store, engine: services(b))
        #expect(p.conditioning == "pending_engine" && p.audition == "pending_engine")
        #expect(store.hasProfile)
    }

    @Test func discardedCandidateGivesTheEngineTheSavedVoiceBack() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let p = try await saveProfile(store, engine: services(b))
        let loadsBefore = await b.loads.count
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        await VoiceSync.restore(store: store, engine: services(b), routing: routing)
        #expect(await b.loads.count == loadsBefore + 1)
        #expect(await b.loads.last == p.conditioningEntries?.first?.key)
        #expect(routing.hudLabel == "我的声音")
        store.deleteProfile()
        let unloadsBefore = await b.unloads
        await VoiceSync.restore(store: store, engine: services(b), routing: routing)
        #expect(await b.unloads == unloadsBefore + 1)
        #expect(routing.source == .systemVoice)
    }

    // Review fix "build succeeded but the audition threw": keep the blobs, built + pending_engine.
    @Test func anAuditionEngineErrorKeepsTheBuiltConditioning() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        await b.set(synthError: FakeEngineError())
        var c = try EnrollmentController.prepareCandidate(take: Synth.take(segments: [6.0, 6.5], pauses: [0.6]), sampleRate: Synth.rate,
                                                          report: savedReport(), micUID: "m", script: .zhV1, store: store)
        c = try await EnrollmentController.buildAndAudition(c, engine: services(b), script: .zhV1, store: store)
        #expect(c.audition == nil && !c.blobs.isEmpty)
        #expect(c.profile.conditioning == "built" && c.profile.audition == "pending_engine")
        let p = try await EnrollmentController.commitAndAlign(c, script: .zhV1, store: store, engine: nil, routing: nil,
                                                              gains: nil, queue: VoiceSlotQueue())
        #expect(p.conditioning == "built" && store.loadConditioning(p).count == 1)
    }
}

@Suite(.temporaryFiles) struct TranscriptRecheckTests {
    struct FixedTranscriber: EnrollmentTranscriber {
        let text: String?
        let name = "qwen3-asr"
        func transcribe(_ samples: [Float], sampleRate: Double) async -> String? { text }
    }

    @Test func pendingRowIsCheckedOnceTheEngineIsReady() async throws {
        let store = VoiceStore(root: try tempRoot())
        let saved = try await saveProfile(store)
        #expect(saved.checks.status["transcript"] == .pending)
        #expect(await TranscriptRecheck.run(store: store, transcriber: FixedTranscriber(text: nil)) == .unavailable)
        let out = await TranscriptRecheck.run(store: store, transcriber: FixedTranscriber(text: EnrollmentScript.zhV1.text))
        #expect(out == .checked(.pass, cer: 0))
        let p = try store.loadProfile()
        #expect(p.checks.status["transcript"] == .pass && p.transcriptChecker == "qwen3-asr")
        #expect(mode(store.voiceURL.appendingPathComponent("profile.json")) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: store.voiceURL.appendingPathComponent("profile.json.tmp").path))
        #expect(await TranscriptRecheck.run(store: store, transcriber: FixedTranscriber(text: "")) == .notNeeded)
    }

    @Test func misreadIsRecordedAsRejectButKeepsTheProfile() async throws {
        let store = VoiceStore(root: try tempRoot())
        _ = try await saveProfile(store)
        let out = await TranscriptRecheck.run(store: store, transcriber: FixedTranscriber(text: "大家好"))
        guard case .checked(.reject, _) = out else { Issue.record("\(out)"); return }
        #expect(store.hasProfile)
    }

    @Test func savedExcerptUsesItsOwnHashedScript() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceStore(root: root)
        var profile = try await saveProfile(store)
        let excerpt = EnrollmentScript(id: "zh-v2-first-clause-v1", text: "大家好，今天我们一起看看项目的最新进展。")
        profile.scriptID = excerpt.id
        profile.scriptSHA256 = excerpt.sha256
        try Data(excerpt.text.utf8).write(to: store.voiceURL.appendingPathComponent(VoiceStore.scriptName))
        try store.replaceProfile(profile)
        #expect(await TranscriptRecheck.run(store: store, transcriber: FixedTranscriber(text: excerpt.text)) == .checked(.pass, cer: 0))
        profile = try store.loadProfile()
        profile.checks.status["transcript"] = .pending
        try store.replaceProfile(profile)
        try Data(EnrollmentScript.zhV2.text.utf8).write(to: store.voiceURL.appendingPathComponent(VoiceStore.scriptName))
        #expect(await TranscriptRecheck.run(store: store, transcriber: FixedTranscriber(text: EnrollmentScript.zhV2.text)) == .unavailable)
        #expect(try store.loadProfile().checks.status["transcript"] == .pending)
    }
}

@Suite(.temporaryFiles) struct VoiceLifecycleTests {
    @Test func savedSamplingIdentitySurvivesRebuildAndAudition() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceStore(root: root), backend = FakeBackend()
        var profile = try await saveProfile(store)
        let oldJSON = try #require(try JSONSerialization.jsonObject(with: profile.encoded()) as? [String: Any])
        #expect(oldJSON["sampling_key"] == nil)
        #expect(try VoiceProfile.decode(profile.encoded()).samplingKey == nil)
        profile.samplingKey = "original-full-reference-key"
        try store.replaceProfile(profile)
        let json = try #require(try JSONSerialization.jsonObject(with: store.loadProfile().encoded()) as? [String: Any])
        #expect(json["sampling_key"] as? String == profile.samplingKey)
        let routing = SpeakVoiceRouting(clone: NamedTTS("qwen"), system: NamedTTS("system"))
        let outcome = await VoiceSync.align(store: store, engine: services(backend), routing: routing)
        #expect(outcome.conditioningBuilt && outcome.auditionChecked)
        let saved = try store.loadProfile()
        let blob = try #require(store.loadConditioning(saved).first)
        let handle = try #require(routing.voice)
        #expect(blob.samplingKey == profile.samplingKey && handle.samplingKey == profile.samplingKey)
        #expect(handle.conditioningKey == blob.key && blob.key != profile.samplingKey)
        var original = handle
        original.conditioningKey = try #require(profile.samplingKey)
        original.samplingKey = nil
        for language in [Lang.en, .de] {
            #expect(await backend.seeds[language]?.first == Int(TTSSeed.make(voice: original, language: language)))
        }
        #expect(VoiceSync.alreadyRestored(store: store, routing: routing))
        var stale = handle
        stale.samplingKey = nil
        routing.useMyVoice(stale, playoutGainDb: 0)
        #expect(!VoiceSync.alreadyRestored(store: store, routing: routing))
        await VoiceSync.restore(store: store, engine: services(backend), routing: routing)
        #expect(VoiceSync.alreadyRestored(store: store, routing: routing))
    }

    @Test func unreadableExistingProfileStaysPendingAndRestoreUnloadsTheTemporaryVoice() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceStore(root: root)
        try FileManager.default.createDirectory(at: store.voiceURL, withIntermediateDirectories: true)
        try Data("not valid profile JSON".utf8).write(to: store.voiceURL.appendingPathComponent(VoiceStore.profileName))
        #expect(store.hasProfile)
        let backend = FakeBackend()
        let engine = services(backend)
        let handle = VoiceHandle(profileID: UUID(), conditioningKey: "temporary", mode: .icl,
                                 model: EngineID(name: "qwen", revision: "", placement: .engineGPU))
        let routing = SpeakVoiceRouting(clone: NamedTTS("qwen"), system: NamedTTS("system"),
                                        source: .myVoice(handle, playoutGainDb: 0))

        let result = await VoiceSync.align(store: store, engine: engine, routing: routing)
        #expect(result.routed == .myVoicePending && routing.source == .myVoicePending)
        #expect(await backend.events.isEmpty)

        try await backend.load(blob: Data([1]), model: "qwen", key: "temporary", mode: .icl, profileID: handle.profileID)
        routing.useMyVoice(handle, playoutGainDb: 0)
        await VoiceSync.restore(store: store, engine: engine, routing: routing)
        #expect(routing.source == .myVoicePending)
        #expect(await backend.events == ["load", "unload"])
        #expect(store.hasProfile) // Preserve the failed profile for repair instead of deleting it.
    }

    @MainActor private func lifecycle(_ store: VoiceStore, _ b: FakeBackend, routing: SpeakVoiceRouting? = nil,
                                      monitor: RecordingAuditionMonitor = RecordingAuditionMonitor()) -> (VoiceLifecycle, SpeakVoiceRouting) {
        let r = routing ?? SpeakVoiceRouting(clone: NamedTTS("qwen"), system: NamedTTS("system"))
        return (VoiceLifecycle(store: store, engine: services(b), monitor: monitor, routing: r,
                               passthroughGains: InMemoryPassthroughGainStore()), r)
    }

    @Test @MainActor func voiceReadyBuildsAuditionsAndRoutesAProfileSavedBeforeTheEngine() async throws {
        let store = VoiceStore(root: try tempRoot())
        _ = try await saveProfile(store)   // pending_engine, like the user's M1 recording
        let b = FakeBackend()
        let monitor = RecordingAuditionMonitor()
        let (life, routing) = lifecycle(store, b, monitor: monitor)
        let out = await life.voiceReady()
        #expect(out.conditioningBuilt && out.auditionChecked)
        let p = try store.loadProfile()
        #expect(p.conditioning == "built" && p.audition == "passed" && p.playoutGainDb != nil)
        let cond = store.voiceURL.appendingPathComponent("conditioning")
        #expect(mode(cond) == 0o700)
        for f in try FileManager.default.contentsOfDirectory(atPath: cond.path) { #expect(mode(cond.appendingPathComponent(f)) == 0o600) }
        #expect(routing.hudLabel == "我的声音")
        #expect(routing.playoutGainDb == p.playoutGainDb)
        // 试听 plays through the monitor output only.
        try await life.play(.en)
        #expect(await monitor.played.count == 1)
        // A second READY changes nothing on disk.
        let again = await life.voiceReady()
        #expect(!again.conditioningBuilt && !again.auditionChecked)
    }

    // Review fix [高]: stale conditioning is rebuilt, never loaded.
    @Test @MainActor func conditioningFromAnotherRevisionIsRebuiltAndReAuditioned() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let old = try await saveProfile(store, engine: services(b))
        let oldKey = try #require(old.conditioningEntries?.first?.key)
        #expect(old.audition == "passed")
        await b.set(rev: "0123456789ab0000")   // model updated
        let (life, routing) = lifecycle(store, b)
        #expect(routing.source == .myVoicePending)   // until the (re)built voice is loaded
        let seen = Flag()
        routing.observe { seen.add($0) }
        let loadsBefore = await b.loads
        let out = await life.voiceReady()
        #expect(out.conditioningBuilt && out.auditionChecked)
        let p = try store.loadProfile()
        let newKey = try #require(p.conditioningEntries?.first?.key)
        #expect(newKey.contains("@0123456789ab-") && newKey != oldKey)
        #expect(p.conditioningEntries?.count == 1 && p.audition == "passed")
        // The old blob file is gone; only the new one is left.
        let files = try FileManager.default.contentsOfDirectory(atPath: store.voiceURL.appendingPathComponent("conditioning").path)
        #expect(files == [VoiceStore.safeKey(newKey) + ".safetensors"])
        // The stale key was never sent to the engine; SPEAK waited ("pending") until the load.
        #expect(!(await b.loads).dropFirst(loadsBefore.count).contains(oldKey))
        // SPEAK never pointed at the stale key, only at the new one once it was loaded.
        #expect(seen.values.count == 1)
        if case let .myVoice(h, _)? = seen.values.first { #expect(h.conditioningKey == newKey) } else { Issue.record("\(seen.values)") }
        #expect(routing.voice?.conditioningKey == newKey)
    }

    @Test @MainActor func aModelThatIsNotInTheTierAnyMoreCountsAsMissing() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        _ = try await saveProfile(store, engine: services(b))
        await b.set(models: ["qwen3-tts-0.6b-base-8bit"])
        let (life, _) = lifecycle(store, b)
        #expect(await life.voiceReady().conditioningBuilt)
        #expect(try store.loadProfile().conditioningEntries?.map(\.model) == ["qwen3-tts-0.6b-base-8bit"])
    }

    @Test @MainActor func switchingTTSKeepsTheOtherModelsVoiceAndCalibration() async throws {
        let store = VoiceStore(root: try tempRoot()), backend = FakeBackend()
        let original = try await saveProfile(store, engine: services(backend))
        let qwen = try #require(original.speakEntry)
        let originalWAV = try Data(contentsOf: store.voiceURL.appendingPathComponent(VoiceStore.referenceName))
        let originalScript = try Data(contentsOf: store.voiceURL.appendingPathComponent(VoiceStore.scriptName))
        await backend.set(models: ["tts-ming3-0.5b-bf16"])
        await backend.set(takes: [.en: [.init(seconds: 4, readback: enText, amplitude: 0.3)],
                                  .de: [.init(seconds: 4, readback: deText, amplitude: 0.3)]])
        let (life, routing) = lifecycle(store, backend)
        let switched = await life.voiceReady()
        #expect(switched.conditioningBuilt && switched.auditionChecked)
        let ming = try store.loadProfile()
        #expect(ming.speakEntry?.model == "tts-ming3-0.5b-bf16")
        #expect(ming.archivedConditioningEntries == [qwen])
        #expect(ming.playoutGainDb != original.playoutGainDb)
        #expect(store.loadConditioning(ming).contains { $0.key == qwen.key })

        await backend.set(models: [qwen.model])
        let returned = await life.voiceReady()
        #expect(!returned.conditioningBuilt && !returned.auditionChecked)
        let restored = try store.loadProfile()
        #expect(restored.speakEntry == qwen)
        #expect(restored.playoutGainDb == original.playoutGainDb)
        #expect(restored.auditionResult == original.auditionResult)
        #expect(routing.voice?.conditioningKey == qwen.key)
        #expect(routing.playoutGainDb == original.playoutGainDb)
        #expect(restored.archivedConditioningEntries?.first?.model == "tts-ming3-0.5b-bf16")
        #expect(try Data(contentsOf: store.voiceURL.appendingPathComponent(VoiceStore.referenceName)) == originalWAV)
        #expect(try Data(contentsOf: store.voiceURL.appendingPathComponent(VoiceStore.scriptName)) == originalScript)
    }

    @Test @MainActor func missingActiveCacheIsRebuiltAndRecheckedEvenWhenItsKeyIsUnchanged() async throws {
        let store = VoiceStore(root: try tempRoot()), backend = FakeBackend()
        let original = try await saveProfile(store, engine: services(backend))
        let key = try #require(original.speakEntry?.key)
        try FileManager.default.removeItem(at: store.voiceURL.appendingPathComponent("conditioning/\(VoiceStore.safeKey(key)).safetensors"))
        let (life, _) = lifecycle(store, backend)
        let out = await life.voiceReady()
        #expect(out.conditioningBuilt && out.auditionChecked)
        #expect(try store.loadProfile().speakEntry?.key == key)
    }

    @Test @MainActor func restoreBeforeReadyAlignmentUsesTheRestoredModelsCalibration() async throws {
        let store = VoiceStore(root: try tempRoot()), backend = FakeBackend()
        let original = try await saveProfile(store, engine: services(backend))
        let qwen = try #require(original.speakEntry)
        await backend.set(models: ["tts-ming3-0.5b-bf16"])
        await backend.set(takes: [.en: [.init(seconds: 4, readback: enText, amplitude: 0.3)],
                                  .de: [.init(seconds: 4, readback: deText, amplitude: 0.3)]])
        let (life, routing) = lifecycle(store, backend)
        _ = await life.voiceReady()
        #expect(try store.loadProfile().playoutGainDb != original.playoutGainDb)
        await backend.set(models: [qwen.model])
        await VoiceSync.restore(store: store, engine: services(backend), routing: routing)
        let restored = try store.loadProfile()
        #expect(restored.speakEntry == qwen)
        #expect(restored.playoutGainDb == original.playoutGainDb)
        #expect(routing.playoutGainDb == original.playoutGainDb)
        #expect(VoiceSync.alreadyRestored(store: store, routing: routing))
    }

    @Test @MainActor func routeUsesTheCurrentBlobLoadedInsteadOfTheFirstProfileEntry() async throws {
        let store = VoiceStore(root: try tempRoot()), b = FakeBackend()
        let engine = services(b)
        var p = try await saveProfile(store, engine: engine)
        let current = try #require(p.conditioningEntries?.first)
        p.conditioningEntries?.insert(.init(key: "stale-key", model: "retired-model", mode: current.mode), at: 0)
        try store.replaceProfile(p, expecting: p.identity)
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))

        _ = await VoiceSync.align(store: store, engine: engine, routing: routing)
        #expect(await b.loads.last == current.key)
        #expect(routing.voice?.conditioningKey == current.key)
        #expect(routing.voice?.model.name == current.model)
        routing.useMyVoicePending()
        await VoiceSync.restore(store: store, engine: engine, routing: routing)
        #expect(await b.loads.last == current.key)
        #expect(routing.voice?.conditioningKey == current.key)
    }

    @Test @MainActor func aFailedLoadLeavesSpeakPendingNotOnMyVoice() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        _ = try await saveProfile(store, engine: services(b))
        await b.set(loadError: FakeEngineError())
        let (life, routing) = lifecycle(store, b)
        await life.voiceReady()
        #expect(routing.source == .myVoicePending)
        #expect(routing.cloneAvailability == .down)
        #expect(routing.hudLabel == SpeakVoiceRouting.pendingLabel)
    }

    // Review fix "route by the saved profile at launch".
    @Test @MainActor func launchRoutesByTheSavedProfile() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let (none, r0) = lifecycle(store, b)
        _ = none
        #expect(r0.source == .systemVoice && r0.cloneAvailability == .noProfile)
        _ = try await saveProfile(store)
        let (some, r1) = lifecycle(store, b)
        _ = some
        #expect(r1.source == .myVoicePending && r1.cloneAvailability == .down)
        // No engine installed: the clone can never load, so the system voice.
        let r2 = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        _ = VoiceLifecycle(store: store, engine: nil, monitor: RecordingAuditionMonitor(), routing: r2,
                           passthroughGains: InMemoryPassthroughGainStore())
        #expect(r2.source == .systemVoice)
    }

    // Review fix [低]: transcript re-check is its own call, on ASR ready.
    @Test @MainActor func transcriptRecheckRunsOnlyWithASRReady() async throws {
        let store = VoiceStore(root: try tempRoot())
        _ = try await saveProfile(store)
        let b = FakeBackend()
        let (life, _) = lifecycle(store, b)
        await life.voiceReady()
        #expect(try store.loadProfile().checks.status["transcript"] == .pending)   // voiceReady leaves it
        await b.set(ready: EngineReadiness(running: true, asr: .absent))
        #expect(await life.transcriptRecheck() == .unavailable)
        await b.set(ready: EngineReadiness(running: true, asr: .loading))
        #expect(await life.transcriptRecheck() == .unavailable)
        #expect(await b.zhTranscripts == 0)
        await b.set(ready: EngineReadiness(running: true, asr: .ready))
        #expect(await life.transcriptRecheck() == .checked(.pass, cer: 0))
        #expect(try store.loadProfile().transcriptChecker == "qwen3-asr")
    }

    // Review fix [中] interleaving: deletion waits for the in-flight load and unloads last.
    @Test @MainActor func deleteDuringALoadUnloadsLastAndLeavesNoProfile() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        _ = try await saveProfile(store, engine: services(b))
        let (life, routing) = lifecycle(store, b)
        await b.hold()
        let ready = Task { await life.voiceReady() }
        while await b.parkedCount == 0 { await Task.yield() }
        let del = Task { await life.delete() }
        await Task.yield()
        #expect(routing.source == .systemVoice)       // SPEAK switched at once
        await b.releaseLoads()
        _ = await ready.value
        let out = await del.value
        #expect(out.filesRemoved && out.engineUnloaded)
        #expect(await b.events.last == "unload")
        #expect(routing.source == .systemVoice)       // the cancelled load did not route back
        #expect(!store.hasProfile)
    }

    // Review fix [中] interleaving: a result for a profile that was re-recorded meanwhile is dropped.
    @Test func aRecheckForAReplacedProfileWritesNothing() async throws {
        let store = VoiceStore(root: try tempRoot())
        _ = try await saveProfile(store)
        struct Swapper: EnrollmentTranscriber {
            let store: VoiceStore
            let name = "qwen3-asr"
            func transcribe(_ samples: [Float], sampleRate: Double) async -> String? {
                // The user re-records while the ASR runs.
                _ = try? await EnrollmentController.saveTake(take: Synth.take(segments: [6.2, 6.4], pauses: [0.5]),
                                                             noise: Synth.noise(1.5, db: -68), sampleRate: Synth.rate,
                                                             report: savedReport(), micUID: "other", script: .zhV1,
                                                             store: store, engine: nil)
                return EnrollmentScript.zhV1.text
            }
        }
        let out = await TranscriptRecheck.run(store: store, transcriber: Swapper(store: store))
        #expect(out == .unavailable)
        #expect(try store.loadProfile().checks.status["transcript"] == .pending)   // the new one is untouched
    }

    @Test func unavailableMonitorNeverPlays() async {
        await #expect(throws: AuditionMonitorError.unavailable(UnavailableAuditionMonitor.reason)) { try await UnavailableAuditionMonitor().play([0.1]) }
    }
}

@Suite struct AuditionMachineTests {
    private func review() -> (VoiceEnrollment, EnrollmentReport) {
        var m = VoiceEnrollment()
        let r = savedReport()
        for e: VoiceEnrollment.Event in [.start, .noiseMeasured, .tick, .tick, .tick, .stopped, .analyzed(r)] { m.send(e) }
        return (m, r)
    }

    private let passed = AuditionResult.Summary(passed: true, playoutGainDb: 1, clips: [])
    private let failed = AuditionResult.Summary(passed: false, playoutGainDb: nil,
                                                clips: [.init(lang: .de, attempts: 2, failure: .short, wer: nil, similarity: nil, seconds: 1)])

    @Test func auditionThenSave() {
        var (m, _) = review()
        var ok = m.send(.audition)
        #expect(ok && m.phase == .auditioning)
        ok = m.send(.save)
        #expect(!ok)
        ok = m.send(.auditioned(passed))
        #expect(ok && m.phase == .auditionReview(passed))
        ok = m.send(.save)
        #expect(ok && m.phase == .saving)
        ok = m.send(.saved)
        #expect(ok && m.phase == .saved)
    }

    @Test func failedAuditionBlocksSaveButAllowsRetake() {
        var (m, _) = review()
        m.send(.audition)
        m.send(.auditioned(failed))
        var ok = m.send(.save)
        #expect(!ok)
        ok = m.send(.retake)
        #expect(ok && m.phase == .measuringNoise)
        #expect(m.takes == 1)
    }

    @Test func engineTroubleSkipsToSaving() {
        var (m, _) = review()
        m.send(.audition)
        var ok = m.send(.auditionSkipped)
        #expect(ok && m.phase == .saving)
        var (m2, _) = review()
        m2.send(.audition)
        ok = m2.send(.failed("x"))
        #expect(ok && m2.phase == .failed("x"))
    }
}

@Suite struct RecordingPolicyDelegationTests {
    private func dev(_ transport: String, name: String = "Mic", uid: String = "u") -> InputDeviceInfo {
        InputDeviceInfo(objectID: 1, uid: uid, name: name, transport: transport, nominalSampleRate: 48_000,
                        inputChannels: 1, isAlive: true, isAggregate: false)
    }

    @Test func sharedRulesComeFromMicPolicy() {
        for d in [dev("bltn", uid: "com.aaajiao.talktalk.feed"), dev("usb ", name: "Tuwa Mic"), dev("virt"), dev("grup")] {
            let e = MicPolicy.exclusion(MicPolicy.Device(d))
            #expect(e != nil)
            #expect(RecordingDevicePolicy.evaluate(d) == .rejected(e!.text))
        }
        // Recording-only narrowing on top of MicPolicy: Thunderbolt passes MicPolicy rule 1, not recording.
        #expect(MicPolicy.exclusion(MicPolicy.Device(dev("thun"))) == nil)
        #expect(!RecordingDevicePolicy.evaluate(dev("thun")).isAccepted)
        #expect(!RecordingDevicePolicy.evaluate(dev("usb ", name: "BlackHole 2ch")).isAccepted)
    }
}

/// voice-m2 review fixes on the 保存 path (`EnrollmentController` statics; the instance methods
/// only add the machine and the generation counter around them).
@Suite(.temporaryFiles) struct SaveAttemptTests {
    private func candidate(_ store: VoiceStore) throws -> EnrollmentController.Candidate {
        try EnrollmentController.prepareCandidate(take: Synth.take(segments: [6.1, 6.6], pauses: [0.6]), sampleRate: Synth.rate,
                                                  report: savedReport(), micUID: "USB-MIC-2", script: .zhV1, store: store)
    }

    private func stagings(_ store: VoiceStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".voice-staging-") }
    }

    // Review fix [中]: cancelled while the candidate's load is in flight → staging gone and the
    // saved voice is loaded back after it.
    @Test func cancellingDuringTheAuditionRestoresTheSavedVoice() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let saved = try await saveProfile(store, engine: services(b))
        let savedKey = try #require(saved.conditioningEntries?.first?.key)
        let c = try candidate(store)
        let queue = VoiceSlotQueue()
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        await b.hold()
        let attempt = Task {
            await EnrollmentController.auditionAttempt(c, engine: services(b), script: .zhV1, store: store, routing: routing,
                                                       queue: queue) { true }
        }
        while await b.parkedCount == 0 { await Task.yield() }
        attempt.cancel()                       // 放弃 / 重录
        await b.releaseLoads()
        guard case .dropped = await attempt.value else { Issue.record("not dropped"); return }
        #expect(try stagings(store).isEmpty)
        #expect(await b.loads.last == savedKey)
        #expect(routing.voice?.conditioningKey == savedKey)
    }

    // Review fix [中]: a stale generation drops the result even though the phase never moved.
    @Test func aStaleGenerationDropsTheResult() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let saved = try await saveProfile(store, engine: services(b))
        let out = await EnrollmentController.auditionAttempt(try candidate(store), engine: services(b), script: .zhV1, store: store,
                                                             routing: nil, queue: VoiceSlotQueue()) { false }
        guard case .dropped = out else { Issue.record("not dropped"); return }
        #expect(try stagings(store).isEmpty)
        #expect(await b.loads.last == saved.conditioningEntries?.first?.key)
    }

    @Test func aBuildErrorSavesWithoutAudition() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        await b.set(buildError: FakeEngineError())
        let out = await EnrollmentController.auditionAttempt(try candidate(store), engine: services(b), script: .zhV1, store: store,
                                                             routing: nil, queue: VoiceSlotQueue()) { true }
        guard case let .saveWithoutAudition(c) = out else { Issue.record("\(out)"); return }
        #expect(c.profile.conditioning == "pending_engine" && c.blobs.isEmpty)
    }

    // Review fix [中]: after a save, engine and SPEAK follow the new profile on disk.
    @Test func aPendingSaveIsBuiltRightAwayWhenTheEngineRuns() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        var c = try candidate(store)
        c.profile.conditioning = "pending_engine"
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let gains = InMemoryPassthroughGainStore()
        let p = try await EnrollmentController.commitAndAlign(c, script: .zhV1, store: store, engine: services(b), routing: routing,
                                                              gains: gains, queue: VoiceSlotQueue())
        #expect(p.conditioning == "built" && p.audition == "passed")
        #expect(routing.voice?.conditioningKey == p.conditioningEntries?.first?.key)
        #expect(gains.gainDb(micUIDHash: p.micUIDHash) != nil)
    }

    @Test func aPendingSaveWaitsForReadyWhenTheEngineIsStopped() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        await b.set(ready: .stopped)
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let p = try await EnrollmentController.commitAndAlign(try candidate(store), script: .zhV1, store: store, engine: services(b),
                                                              routing: routing, gains: nil, queue: VoiceSlotQueue())
        #expect(p.conditioning == "pending_engine")
        #expect(await b.builds.isEmpty)
        #expect(routing.source == .myVoicePending)
    }

    @Test func anAuditionedSaveLoadsThenRoutes() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let c = try await EnrollmentController.buildAndAudition(try candidate(store), engine: services(b), script: .zhV1, store: store)
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let before = await b.loads.count
        let p = try await EnrollmentController.commitAndAlign(c, script: .zhV1, store: store, engine: services(b), routing: routing,
                                                              gains: nil, queue: VoiceSlotQueue())
        #expect(await b.loads.count == before + 1)
        #expect(await b.builds.count == 1)   // no rebuild
        #expect(routing.source == .myVoice(try #require(VoiceSync.handle(p)), playoutGainDb: p.playoutGainDb ?? 0))
    }
}

// Review fix [中]: Qwen3-ASR for the transcript row only when READY with ASR ready.
@Suite struct TranscriberGateTests {
    struct Apple: EnrollmentTranscriber {
        let name = "apple-zh-CN"
        func transcribe(_ samples: [Float], sampleRate: Double) async -> String? { "苹果" }
    }

    @Test func qwenOnlyWhenTheEngineIsReadyWithASR() async throws {
        let b = FakeBackend()
        let qwen = try #require(services(b).transcriber)
        for r in [EngineReadiness.stopped, .init(running: true, asr: .loading), .init(running: true, asr: .absent)] {
            await b.set(ready: r)
            #expect(await qwen.transcribe(sine(1), sampleRate: 24_000) == nil)
        }
        #expect(await b.zhTranscripts == 0)
        let f = FallbackTranscriber(primary: qwen, fallback: Apple())
        #expect(await f.transcribe(sine(1), sampleRate: 24_000) == "苹果")
        #expect(f.name == "apple-zh-CN")   // transcript_checker records who answered
        await b.set(ready: .init(running: true, asr: .ready))
        #expect(await f.transcribe(sine(1), sampleRate: 24_000) == EnrollmentScript.zhV1.text)
        #expect(f.name == "qwen3-asr")
    }

    @Test func enrollmentFinishedReachesTheEngine() async {
        let b = FakeBackend()
        await services(b).enrollmentFinished()
        #expect(await b.finished == 1)
    }
}

@Suite struct ConditioningIdentityTests {
    @Test func matchesRuntimeVersionModelAndRevision() {
        let id = ConditioningIdentity(runtime: "mlx0.26", mlxAudio: "0.2.3", models: [("tts-1.7b", "0123456789abcdef")])
        let ok = "mlx0.26-mlxaudio0.2.3-tts-1.7b@0123456789ab-icl-00ff00ff00ff00ff"
        #expect(id.isCurrent(key: ok, model: "tts-1.7b"))
        #expect(!id.isCurrent(key: ok, model: "tts-0.6b"))
        #expect(!id.isCurrent(key: ok.replacingOccurrences(of: "mlx0.26-", with: "mlx0.27-"), model: "tts-1.7b"))
        #expect(!id.isCurrent(key: ok.replacingOccurrences(of: "0.2.3", with: "0.2.4"), model: "tts-1.7b"))
        #expect(!id.isCurrent(key: ok.replacingOccurrences(of: "@0123456789ab", with: "@fffffffffff0"), model: "tts-1.7b"))
        // mlx-audio version unknown: runtime, model and revision still decide.
        let noVer = ConditioningIdentity(runtime: "mlx0.26", mlxAudio: nil, models: [("tts-1.7b", "0123456789abcdef")])
        #expect(noVer.isCurrent(key: ok, model: "tts-1.7b"))
    }
}

@Suite struct VoiceSlotQueueTests {
    actor Log { var v: [String] = []; func add(_ s: String) { v.append(s) } }

    @Test func operationsDoNotInterleave() async throws {
        let q = VoiceSlotQueue(), log = Log()
        async let a: Void = q.run { await log.add("a1"); try await Task.sleep(for: .milliseconds(30)); await log.add("a2") }
        try await Task.sleep(for: .milliseconds(5))
        async let b: Void = q.run { await log.add("b1"); await log.add("b2") }
        _ = try await (a, b)
        #expect(await log.v == ["a1", "a2", "b1", "b2"])
    }

    @Test func cancelAllSkipsQueuedButRunAlwaysRuns() async throws {
        let q = VoiceSlotQueue(), log = Log()
        let a = Task { try await q.run { try await Task.sleep(for: .seconds(5)); await log.add("a") } }
        try await Task.sleep(for: .milliseconds(5))
        let b = Task { try await q.run { await log.add("b") } }
        try await Task.sleep(for: .milliseconds(5))
        let del = q.cancelAllThenRun { await log.add("delete") }
        // Submitted after the deletion: runs after it, not before.
        let c = Task { try await q.run { await log.add("after") } }
        await del.value
        _ = await a.result
        // Cancelled by the queue: its own error, not a bare CancellationError.
        let br = await b.result
        #expect(throws: VoiceSlotQueue.Cancelled.self) { try br.get() }
        _ = try await c.value
        #expect(await log.v == ["delete", "after"])
    }

    @Test func aCallerCancelIsACancellationErrorNotQueueCancelled() async throws {
        let q = VoiceSlotQueue()
        let t = Task { try await q.run { try await Task.sleep(for: .seconds(5)) } }
        try await Task.sleep(for: .milliseconds(5))
        t.cancel()
        let tr = await t.result
        #expect(throws: CancellationError.self) { try tr.get() }
    }
}

@Suite struct SpeakerSimilarityWiringTests {
    @Test func tooShortIsNilOtherErrorsAreThrown() async throws {
        #expect(try await RemoteQwenVoiceBackend.similarityOrNil { 0.981 } == 0.981)
        #expect(try await RemoteQwenVoiceBackend.similarityOrNil {
            throw EngineAPIError.http(status: 400, code: "audio_too_short", message: "")
        } == nil)
        await #expect(throws: EngineAPIError.http(status: 503, code: "tts_not_loaded", message: "")) {
            _ = try await RemoteQwenVoiceBackend.similarityOrNil {
                throw EngineAPIError.http(status: 503, code: "tts_not_loaded", message: "")
            }
        }
    }
}

/// Second review of voice-m2 (items 1, 2, 3, 6, 7), one test each.
@Suite(.temporaryFiles) struct SecondReviewTests {
    private func candidate(_ store: VoiceStore) throws -> EnrollmentController.Candidate {
        try EnrollmentController.prepareCandidate(take: Synth.take(segments: [6.3, 6.2], pauses: [0.6]), sampleRate: Synth.rate,
                                                  report: savedReport(), micUID: "USB-MIC-3", script: .zhV1, store: store)
    }

    private func until(_ cond: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<2000 where !(await cond()) { try? await Task.sleep(for: .milliseconds(1)) }
    }

    // 1: an engine that stops or restarts sends SPEAK to "pending" at once, and READY keeps it
    // there until the load has returned.
    @Test @MainActor func engineRestartIsPendingUntilTheVoiceIsLoadedAgain() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        _ = try await saveProfile(store, engine: services(b))
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let life = VoiceLifecycle(store: store, engine: services(b), monitor: RecordingAuditionMonitor(), routing: routing,
                                  passthroughGains: InMemoryPassthroughGainStore())
        let (updates, cont) = AsyncStream<Bool>.makeStream()
        let follower = life.follow(engineReady: updates)
        cont.yield(true)
        await until { if case .myVoice = routing.source { return true } else { return false } }
        #expect(routing.cloneAvailability != .down)

        cont.yield(false)                                   // idle exit / crash / restart
        await until { routing.cloneAvailability == .down }
        #expect(routing.cloneAvailability == .down)

        await b.hold()
        let parkedBefore = await b.parkedCount
        cont.yield(true)                                    // READY again: empty slot until the load returns
        await until { await b.parkedCount > parkedBefore }
        #expect(routing.cloneAvailability == .down)
        await b.releaseLoads()
        await until { if case .myVoice = routing.source { return true } else { return false } }
        #expect(routing.hudLabel == "我的声音")
        cont.finish()
        follower.cancel()
        await follower.value
        // Finish the cancelled READY work before the test's temporary directory is removed.
        await life.queue.runAlways {}
    }

    // 2: the engine stopping mid-save (CancellationError from EngineProcess.stop / awaitReady) is
    // an engine error: the take is saved as pending_engine, not dropped as "保存被取消".
    @Test func anEngineSideCancellationSavesWithoutAudition() async throws {
        for inject in ["build", "synth"] {
            let store = VoiceStore(root: try tempRoot())
            let b = FakeBackend()
            if inject == "build" { await b.set(buildError: CancellationError()) } else { await b.set(synthError: CancellationError()) }
            let out = await EnrollmentController.auditionAttempt(try candidate(store), engine: services(b), script: .zhV1, store: store,
                                                                 routing: nil, queue: VoiceSlotQueue()) { true }
            guard case let .saveWithoutAudition(c) = out else { Issue.record("\(inject): \(out)"); continue }
            #expect(c.profile.audition == "pending_engine")
            #expect(c.blobs.isEmpty == (inject == "build"))   // blobs kept when only the audition failed
        }
    }

    // 3: a result that arrives after 放弃 / 关窗 is dropped and the saved voice goes back.
    @Test func aLateResultIsDroppedAndTheSavedVoiceRestored() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let saved = try await saveProfile(store, engine: services(b))
        let c = try await EnrollmentController.buildAndAudition(try candidate(store), engine: services(b), script: .zhV1, store: store)
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let loadsBefore = await b.loads.count
        let queue = VoiceSlotQueue()
        EnrollmentController.dropLate(c.staging, store: store, engine: services(b), routing: routing, queue: queue)
        #expect(!FileManager.default.fileExists(atPath: c.staging.path))
        await until { await b.loads.count > loadsBefore }
        await queue.runAlways {}
        #expect(await b.loads.last == saved.conditioningEntries?.first?.key)
    }

    // 6: while the unsaved candidate is in the engine SPEAK is "pending"; right after the
    // audition's synthesis the saved voice is back in the engine and on the route.
    @Test func theCandidateNeverSpeaksUnderTheSavedHandle() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let saved = try await saveProfile(store, engine: services(b))
        let savedKey = try #require(saved.conditioningEntries?.first?.key)
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        await VoiceSync.restore(store: store, engine: services(b), routing: routing)
        let seen = Flag()
        routing.observe { seen.add($0) }
        let c = try await EnrollmentController.buildAndAudition(try candidate(store), engine: services(b), script: .zhV1,
                                                                store: store, routing: routing)
        #expect(c.audition?.passed == true)
        #expect(seen.values.first == .myVoicePending)
        #expect(await b.loads.last == savedKey)
        #expect(routing.voice?.conditioningKey == savedKey)
        // Never routed to anything but the saved key.
        for v in seen.values { if case let .myVoice(h, _) = v { #expect(h.conditioningKey == savedKey) } }
    }

    // 7: a configured ASR on an engine that is not READY yet is waited for, not treated as
    // "no ASR role" (WER is measured, not skipped).
    @Test func aStoppedEngineWithAnASRRoleStillMeasuresWER() async throws {
        let b = FakeBackend(takes: [.en: [.init(seconds: 4, readback: "thanks everyone")]])
        await b.set(ready: EngineReadiness(running: true, asr: .ready), script: [.stopped, .stopped])
        let svc = EngineVoiceServices(backend: b, to16k: { x, _ in x }, asrWait: .seconds(10), asrPoll: .milliseconds(1))
        let blobs = try await svc.buildConditioning(referenceWAV: referenceWAV, scriptText: "x", modes: [.icl])
        let a = try await svc.audition(conditioning: blobs, modes: [.en: .icl, .de: .icl], profileID: UUID().uuidString,
                                       referenceWAV: referenceWAV)
        #expect(a.clip(.en)?.failure == .wer)          // measured, and rejected
        #expect(a.clips.allSatisfy { !$0.werPending })
    }
}

/// Third review of voice-m2: epoch, no double restore, save() driven end to end.
@Suite(.temporaryFiles) struct ThirdReviewTests {
    private func until(_ cond: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<5000 where !(await cond()) { try? await Task.sleep(for: .milliseconds(1)) }
    }

    @Test func aLoadThatStartedBeforeTheEngineWentDownDoesNotRouteBack() {
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let h = VoiceHandle(profileID: UUID(), conditioningKey: "k", mode: .icl, model: NamedTTS("q").id)
        let e = routing.markPending()                 // align, before loadVoice
        routing.useMyVoicePending()                   // follower: engine left READY meanwhile
        #expect(!routing.useMyVoice(h, playoutGainDb: 0, ifEpoch: e))
        #expect(routing.cloneAvailability == .down)
        let e2 = routing.markPending()
        #expect(routing.useMyVoice(h, playoutGainDb: 1, ifEpoch: e2))
        #expect(routing.voice == h)
    }

    @Test func alreadyRestoredOnlyForTheSavedHandle() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        _ = try await saveProfile(store, engine: services(b))
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        #expect(!VoiceSync.alreadyRestored(store: store, routing: routing))
        await VoiceSync.restore(store: store, engine: services(b), routing: routing)
        #expect(VoiceSync.alreadyRestored(store: store, routing: routing))
        routing.useMyVoicePending()
        #expect(!VoiceSync.alreadyRestored(store: store, routing: routing))
    }

    private static let device = InputDeviceInfo(objectID: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                                transport: "bltn", nominalSampleRate: Synth.rate, inputChannels: 1,
                                                isAlive: true, isAggregate: false)

    @Test @MainActor func aFailedReplacementAuditionPreservesTheSavedVoice() async throws {
        for failure in ["build", "synth"] {
            let store = VoiceStore(root: try tempRoot()), b = FakeBackend()
            let saved = try await saveProfile(store, engine: services(b))
            let savedKey = try #require(saved.conditioningEntries?.first?.key)
            let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
            let c = EnrollmentController(store: store, transcriber: nil, engine: services(b), routing: routing, script: .zhV1)
            c.seedReview(take: Synth.take(segments: [6.0, 6.0], pauses: [0.6]), report: savedReport(), device: Self.device)
            if failure == "build" { await b.set(buildError: FakeEngineError()) }
            else { await b.set(synthError: FakeEngineError()) }
            c.save()
            await c.lastSaveAttempt?.value

            if case .failed = c.phase { } else { Issue.record("\(failure): expected a retryable failure, got \(c.phase)") }
            #expect(try store.loadProfile() == saved)
            #expect(await b.loads.last == savedKey)
            #expect(routing.voice?.conditioningKey == savedKey)
            let staging = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".voice-staging-") }
            #expect(staging.isEmpty)
        }
    }

    // save() → auditioning, 放弃 while the candidate's load is parked: the candidate never stays in
    // the engine, no staging is left, and the saved voice is the last one loaded.
    @Test @MainActor func cancellingADrivenSaveRestoresTheSavedVoice() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let saved = try await saveProfile(store, engine: services(b))
        let savedKey = try #require(saved.conditioningEntries?.first?.key)
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let c = EnrollmentController(store: store, transcriber: nil, engine: services(b), routing: routing)
        c.seedReview(take: Synth.take(segments: [6.0, 6.4], pauses: [0.6]), report: savedReport(), device: Self.device)
        await b.hold()
        c.save()
        #expect(c.phase == .auditioning)
        await until { await b.parkedCount > 0 }
        c.cancel()
        await b.releaseLoads()
        // The end of the attempt, not an intermediate state: buildAndAudition's own restore already
        // shows the saved key, but the drop (staging, second restore) is still to come.
        await c.lastSaveAttempt?.value
        #expect(await b.loads.last == savedKey)
        #expect(routing.voice?.conditioningKey == savedKey)
        let stagings = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".voice-staging-") }
        #expect(stagings.isEmpty)
        #expect(try store.loadProfile().id == saved.id)
    }

    // A driven save that passes: review, then 保存 commits and SPEAK follows the new profile.
    @Test @MainActor func aDrivenSaveReviewsThenCommits() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let c = EnrollmentController(store: store, transcriber: nil, engine: services(b), routing: routing)
        c.seedReview(take: Synth.take(segments: [6.0, 6.4], pauses: [0.6]), report: savedReport(), device: Self.device)
        c.save()
        await c.lastSaveAttempt?.value
        guard case .auditionReview = c.phase else { Issue.record("\(c.phase)"); return }
        c.save()
        // The phase changes before alignment finishes; savedProfile is set after all disk work.
        await until { @MainActor in c.savedProfile != nil }
        #expect(c.savedProfile != nil)
        let p = try store.loadProfile()
        #expect(c.phase == .saved && p.audition == "passed")
        #expect(routing.voice?.conditioningKey == p.conditioningEntries?.first?.key)
    }
}

/// `VoiceLifecycle.readyStream` and `init(engineProcess:)` against the real EngineProcess and the
/// EngineHost tests' stdlib-only fake engine (needs 127.0.0.1 binding: run outside the sandbox,
/// as check.sh does).
@Suite(.serialized, .temporaryFiles) struct EngineFollowTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("EngineHostTests/Fixtures/fake_engine")

    static let python: URL = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", "import sys; print(sys.executable)"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path.isEmpty ? "/usr/bin/python3" : path)
    }()

    static func engine(extra: [String] = []) throws -> EngineProcess {
        let root = try tempRoot()
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let paths = EnginePaths(home: root.appendingPathComponent("home"), logs: root.appendingPathComponent("logs"),
                                caches: root.appendingPathComponent("caches"), engineSource: fixture, installerScript: nil)
        let rev = String(repeating: "a", count: 40)
        let json = """
        {"version":1,"profile":"max","engine_api":2,"runtime":"python-mlx","flavour":"main","lock_sha256":"x",
         "roles":{"tts":{"id":"tts-x","rev":"\(rev)"},"asr":{"id":"asr-y","rev":"\(String(repeating: "c", count: 40))"}},
         "models":[]}
        """
        let record = try JSONDecoder().decode(EngineInstallation.Record.self, from: Data(json.utf8))
        var t = EngineConfig.Timing()
        t.readyTimeout = .seconds(10)
        t.termGrace = .milliseconds(500)
        return EngineProcess(config: EngineConfig(python: python, source: fixture, modelsDirs: [root.appendingPathComponent("models")],
                                                  warmupDir: nil, profile: "max", roles: ["tts", "asr"], tts: "tts-x", asr: "asr-y",
                                                  record: record, paths: paths,
                                                  extraArguments: ["--scenario", "ok", "--state-dir", state.path] + extra, timing: t))
    }

    private func until(_ cond: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<15000 where !(await cond()) { try? await Task.sleep(for: .milliseconds(1)) }
    }

    @Test func readyStreamMapsEngineStatus() async throws {
        let e = try Self.engine()
        do {
            var it = VoiceLifecycle.readyStream(e).makeAsyncIterator()
            #expect(await it.next() == false)               // stopped
            try await e.start()
            var sawReady = false
            while let r = await it.next() { if r { sawReady = true; break } }
            #expect(sawReady)
            await e.stop()
            #expect(await it.next() == false)
        } catch {
            await e.stop()
            throw error
        }
    }

    @Test func auditionRequiresItsLoadedIdentityAndClearsItOnUnload() async throws {
        let e = try Self.engine(extra: ["--require-voice-key", "--tts-chunks", "1", "--tts-chunk-ms", "1"])
        do {
            let backend = RemoteQwenVoiceBackend(engine: e)
            await #expect(throws: RemoteEngineError.voiceNotReady) {
                _ = try await backend.synthesize(text: "Hello there.", lang: .en, seed: 1)
            }
            #expect(await e.launches == 0)
            try await backend.load(blob: Data([1]), model: "tts-x", key: "voice-a", mode: .icl, profileID: UUID())
            #expect(try await backend.synthesize(text: "Hello there.", lang: .en, seed: 1).samples.count == 1920)

            // A different client replaces the slot: the audition must still request voice-a.
            let client = try #require(await e.client)
            try await client.loadVoice(blob: Data([2]), model: "tts-x", key: "voice-b")
            await #expect(throws: EngineAPIError.http(status: 409, code: "voice_key_mismatch", message: "loaded voice does not match the requested voice")) {
                _ = try await backend.synthesize(text: "Hello there.", lang: .en, seed: 1)
            }
            #expect(try await backend.unload())
            await #expect(throws: RemoteEngineError.voiceNotReady) {
                _ = try await backend.synthesize(text: "Hello there.", lang: .en, seed: 1)
            }
        } catch {
            await e.stop()
            throw error
        }
        await e.stop()
    }

    @Test @MainActor func initWithAnEngineProcessFollowsItsStatus() async throws {
        let store = VoiceStore(root: try tempRoot())
        _ = try await saveProfile(store)                 // pending_engine profile
        let e = try Self.engine()
        let routing = SpeakVoiceRouting(clone: NamedTTS("q"), system: NamedTTS("s"))
        let life = VoiceLifecycle(store: store, engineProcess: e, monitor: RecordingAuditionMonitor(), routing: routing,
                                  passthroughGains: InMemoryPassthroughGainStore())
        do {
            #expect(routing.source == .myVoicePending)
            try await e.start()
            // READY → voiceReady: built, loaded, routed (the fake engine's audition fails its checks; the
            // voice is still the saved one).
            await until { if case .myVoice = routing.source { return true } else { return false } }
            if case .myVoice = routing.source {
                #expect(try store.loadProfile().conditioning == "built")
            } else {
                Issue.record("not routed: \(routing.source)")
            }
        } catch {
            await e.stop()
            await life.queue.runAlways {}
            throw error
        }
        await e.stop()                                   // idle exit / crash
        await until { routing.cloneAvailability == .down }
        #expect(routing.cloneAvailability == .down)
        await life.queue.runAlways {}
    }
}

// Third review item 2: reopening within the idle window cancels the scheduled idle exit.
@Suite(.temporaryFiles) struct IdleHookTests {
    private static let device = InputDeviceInfo(objectID: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                                transport: "bltn", nominalSampleRate: Synth.rate, inputChannels: 1,
                                                isAlive: true, isAggregate: false)

    @Test @MainActor func saveCancelsTheIdleExitAndCloseSchedulesItInOrder() async throws {
        let store = VoiceStore(root: try tempRoot())
        let b = FakeBackend()
        let first = EnrollmentController(store: store, transcriber: nil, engine: services(b))
        first.finish()                                      // window closed: idle exit scheduled
        let c = EnrollmentController(store: store, transcriber: nil, engine: services(b))
        c.seedReview(take: Synth.take(segments: [6.0, 6.4], pauses: [0.6]), report: savedReport(), device: Self.device)
        c.save()                                            // reopened and saving: idle exit cancelled
        c.finish()                                          // closed right away: scheduled again, after
        for _ in 0..<5000 where await b.events.filter({ $0 == "started" || $0 == "finished" }).count < 3 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let hooks = await b.events.filter { $0 == "started" || $0 == "finished" }
        #expect(hooks == ["finished", "started", "finished"])
        c.cancel()
        await c.lastSaveAttempt?.value
    }
}
