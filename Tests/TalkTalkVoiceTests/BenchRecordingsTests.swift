import Foundation
import Testing
@testable import TalkTalkVoice

// Fixtures shaped like tools/bench/corpus/t5.json and t17.json (corpus session's format).
private let t5Fixture = """
{"set":"t5","record":true,"lang":"zh","stop":"auto","silence_stop_s":1.0,"max_s":10,"how":"按屏幕上的字读",
 "items":[{"id":"t5-001","text":"iPhone 17 的销量比预期高了百分之十五。","spoken":"iPhone 十七的销量比预期高了百分之十五。",
           "mixed":true,"tags":["number:percent"],"terms":["iPhone"],"est_s":3.9},
          {"id":"t5-002","text":"项目整体进展还算顺利。","mixed":false,"tags":[],"terms":[],"est_s":2.0}]}
"""

private let t17Fixture = """
{"set":"t17","record":true,"lang":"zh","stop":"manual","max_s":60,
 "items":[{"id":"t17-p01","kind":"press","text":"好的，我们开始吧。","expect":"短句","gap_after_s":3.0},
          {"id":"t17-tap1","kind":"tap","taps":2,"text":"（轻点）","expect":"轻点","gap_after_s":2.0},
          {"id":"t17-p02","kind":"press","text":"大家好。","gap_after_s":4.0}]}
"""

@Suite struct BenchCorpusTests {
    @Test func decodesT5() throws {
        let set = try BenchCorpusSet.decode(Data(t5Fixture.utf8))
        #expect(set.set == "t5")
        #expect(set.autoStop)
        #expect(set.silenceStopSeconds == 1.0)
        #expect(set.items[0].prompt == "iPhone 十七的销量比预期高了百分之十五。")
        #expect(set.items[1].prompt == "项目整体进展还算顺利。")
        #expect(set.recordedItems.count == 2)
    }

    @Test func decodesT17() throws {
        let set = try BenchCorpusSet.decode(Data(t17Fixture.utf8))
        #expect(!set.autoStop)
        #expect(set.recordedItems.map(\.id) == ["t17-p01", "t17-p02"])
        #expect(set.items[1].taps == 2)
    }

    @Test func rejectsUnsafeOrDuplicateIDsAndNonRecordingSets() {
        let bad = t5Fixture.replacingOccurrences(of: "t5-002", with: "../evil")
        #expect(throws: BenchCorpusSet.Failure.badID("../evil")) { try BenchCorpusSet.decode(Data(bad.utf8)) }
        let dup = t5Fixture.replacingOccurrences(of: "t5-002", with: "t5-001")
        #expect(throws: BenchCorpusSet.Failure.duplicateID("t5-001")) { try BenchCorpusSet.decode(Data(dup.utf8)) }
        let tts = t5Fixture.replacingOccurrences(of: "\"record\":true", with: "\"record\":false")
        #expect(throws: BenchCorpusSet.Failure.notRecordable("t5")) { try BenchCorpusSet.decode(Data(tts.utf8)) }
    }

    @Test func locatesCorpusFromTheBundle() throws {
        let repo = try tempRoot().deletingLastPathComponent()
        let corpus = repo.appendingPathComponent("tools/bench/corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        try Data(t5Fixture.utf8).write(to: corpus.appendingPathComponent("t5.json"))
        let bundle = repo.appendingPathComponent("build/TalkTalk-Dev.app", isDirectory: true)
        let found = try #require(BenchCorpusSet.locateCorpusDir(explicit: nil, startingAt: bundle))
        #expect(found.standardizedFileURL.path == corpus.standardizedFileURL.path)
        #expect(try BenchCorpusSet.load("t5", corpusDir: found).items.count == 2)
        #expect(throws: BenchCorpusSet.Failure.badID("../t5")) { try BenchCorpusSet.load("../t5", corpusDir: found) }
    }
}

@Suite struct BenchTakeTests {
    @Test func autoSetsAreTrimmedAroundSpeech() {
        let take = Synth.take(segments: [2.0], pauses: [], lead: 1.5, tail: 1.5)
        let c = BenchTakeCheck.evaluate(id: "t5-001", take: take, sampleRate: Synth.rate, noiseFloorDb: -68, trim: true, micUID: "m")
        #expect(c.status == .pass)
        #expect(abs(c.meta.durationSeconds - 2.6) < 0.05)
        #expect(c.meta.trimmed)
        let manual = BenchTakeCheck.evaluate(id: "t17-p01", take: take, sampleRate: Synth.rate, noiseFloorDb: -68, trim: false, micUID: "m")
        #expect(manual.samples.count == take.count)
    }

    @Test func silenceAndZerosAreRejected() {
        let quiet = BenchTakeCheck.evaluate(id: "a", take: Synth.noise(2, db: -70), sampleRate: Synth.rate,
                                            noiseFloorDb: -70, trim: true, micUID: "m")
        #expect(quiet.status == .reject)
        let zeros = BenchTakeCheck.evaluate(id: "a", take: [Float](repeating: 0, count: 48_000), sampleRate: Synth.rate,
                                            noiseFloorDb: -120, trim: true, micUID: "m")
        #expect(zeros.message.contains("权限"))
    }

    @Test func storeWritesPrivateFilesAndManifest() throws {
        let root = try tempRoot().deletingLastPathComponent().appendingPathComponent("TalkTalk-bench/recordings")
        let store = BenchRecordingStore(root: root)
        let take = Synth.take(segments: [2.0], pauses: [])
        let c = BenchTakeCheck.evaluate(id: "t5-001", take: take, sampleRate: Synth.rate, noiseFloorDb: -68, trim: true, micUID: "m")
        try store.save(c, set: "t5")
        #expect(store.hasTake(set: "t5", id: "t5-001"))
        #expect(mode(root) == 0o700)
        #expect(mode(store.setDir("t5")) == 0o700)
        #expect(excludedFromBackup(store.setDir("t5")))
        #expect(mode(store.takeURL(set: "t5", id: "t5-001")) == 0o600)
        #expect(store.manifest(set: "t5")["t5-001"]?.sampleRate == 48_000)
        #expect(store.load(set: "t5", id: "t5-001")?.samples.count == c.samples.count)
    }

    @Test func t17AssemblyPlacesPressesTapsAndGaps() throws {
        let set = try BenchCorpusSet.decode(Data(t17Fixture.utf8))
        let one = WAVFile.Decoded(samples: [Float](repeating: 0.1, count: 48_000), sampleRate: 48_000)       // 1.0 s
        let two = WAVFile.Decoded(samples: [Float](repeating: 0.2, count: 48_000), sampleRate: 24_000)       // 2.0 s at 24 k
        let a = try T17Assembly.assemble(set: set, takes: ["t17-p01": one, "t17-p02": two])
        #expect(a.sampleRate == 48_000)
        #expect(a.events.map(\.kind) == ["press", "tap", "tap", "press"])
        let e = a.events
        #expect(abs(e[0].pressSeconds - 1.0) < 1e-6)                 // 1 s lead
        #expect(abs(e[0].releaseSeconds - 2.0) < 1e-6)
        #expect(abs(e[1].pressSeconds - 5.0) < 1e-6)                 // + 3 s gap
        #expect(abs(e[1].releaseSeconds - e[1].pressSeconds - 0.08) < 1e-3)
        #expect(abs(e[2].pressSeconds - (5.08 + 0.4)) < 1e-3)
        #expect(abs(e[3].pressSeconds - (5.56 + 2.0)) < 1e-3)        // + 2 s gap after the taps
        #expect(abs(e[3].releaseSeconds - e[3].pressSeconds - 2.0) < 0.01)   // resampled to 48 k, same duration
        #expect(abs(Double(a.samples.count) / 48_000 - (e[3].releaseSeconds + 4.0)) < 0.01)
        #expect(throws: T17Assembly.Failure.missingTake("t17-p02")) {
            try T17Assembly.assemble(set: set, takes: ["t17-p01": one])
        }
    }
}
