import Foundation
import Testing
@testable import TalkTalkCore

struct SpeakStrategyTests {
    private func ns(_ seconds: Double) -> HostTime { UInt64(seconds * 1e9) }

    @Test func previewOnlyVetoesWhenCaughtUpAndGermanNeedsMoreSpeech() throws {
        let profile = try TestResources.profile().speak
        let en = SpeakCommitter(profile: profile, target: .en)
        #expect(en.allows(speechS: 2, sinceOnsetS: 2, cutAt: ns(2), previewCharacters: 3, previewThrough: ns(1)))
        #expect(!en.allows(speechS: 2, sinceOnsetS: 2, cutAt: ns(2), previewCharacters: 3, previewThrough: ns(1.8)))
        let de = SpeakCommitter(profile: profile, target: .de)
        #expect(!de.allows(speechS: 2, sinceOnsetS: 2, cutAt: ns(2), previewCharacters: nil, previewThrough: nil))
        #expect(de.allows(speechS: 2.3, sinceOnsetS: 2.3, cutAt: ns(2.3), previewCharacters: nil, previewThrough: nil))
    }

    @Test func cutsAtSilenceMidpointHonorsHardCapAndCapturesOnlyReleaseTail() throws {
        var profile = try TestResources.profile().speak
        profile.boundary.stallMs = 10_000
        var segmenter = SpeakSegmenter(profile: profile, target: .en, start: 0)
        var commits: [SpeakSegmenter.Commit] = []
        for i in 0..<118 {
            commits += segmenter.audio(.init(start: ns(Double(i) * 0.02), end: ns(Double(i + 1) * 0.02),
                                             speech: i < 100, energy: i < 100 ? 1 : 0))
        }
        #expect(commits.count == 1)
        #expect(commits.first?.reason == .silence)
        #expect(commits.first?.end == ns(2.18))

        var capped = SpeakSegmenter(profile: profile, target: .en, start: 0)
        var forced: [SpeakSegmenter.Commit] = []
        for i in 0..<225 {
            forced += capped.audio(.init(start: ns(Double(i) * 0.02), end: ns(Double(i + 1) * 0.02), speech: true, energy: 1))
        }
        #expect(forced.count == 1 && forced[0].reason == .hardCap)
        #expect(forced[0].end - forced[0].start <= ns(4.5))

        var released = SpeakSegmenter(profile: profile, target: .en, start: 0)
        _ = released.audio(.init(start: 0, end: ns(0.8), speech: true, energy: 1))
        #expect(released.release(at: ns(0.8)).isEmpty)
        #expect(released.releaseThrough == ns(1.05))
        let tail = released.audio(.init(start: ns(0.8), end: ns(1.1), speech: false, energy: 0))
        #expect(tail.count == 1 && tail[0].speechMs == 800 && tail[0].isFinalChunk)
        #expect(tail[0].end == ns(1.05))
        #expect(released.finish(at: ns(1.1)).isEmpty)
        var alreadySilent = SpeakSegmenter(profile: profile, target: .en, start: 0)
        _ = alreadySilent.audio(.init(start: 0, end: ns(0.8), speech: true, energy: 1))
        _ = alreadySilent.audio(.init(start: ns(0.8), end: ns(1.1), speech: false, energy: 0))
        #expect(alreadySilent.release(at: ns(1.1)).first?.isFinalChunk == true)
        #expect(alreadySilent.finished)
        var delayedCapture = SpeakSegmenter(profile: profile, target: .en, start: 0)
        _ = delayedCapture.audio(.init(start: 0, end: ns(0.8), speech: true, energy: 1))
        _ = delayedCapture.audio(.init(start: ns(0.8), end: ns(0.9), speech: false, energy: 0))
        _ = delayedCapture.release(at: ns(1))
        #expect(delayedCapture.releaseThrough == ns(1.15)) // unobserved time is not silence
    }

    @Test func englishPunctuationCanCommitBeforeHardCapForChineseOutput() throws {
        var profile = try TestResources.profile().speak
        profile.boundary.stallMs = 10_000
        var segmenter = SpeakSegmenter(profile: profile, target: .zh, start: 0)
        #expect(segmenter.audio(.init(start: 0, end: ns(2), speech: true, energy: 1)).isEmpty)
        #expect(segmenter.preview(stableText: "We will continue tomorrow.", through: ns(2), at: ns(2)).isEmpty)
        let cuts = segmenter.audio(.init(start: ns(2), end: ns(2.3), speech: true, energy: 1))
        #expect(cuts.count == 1 && cuts.first?.reason == .punctuation && cuts.first?.end == ns(2))
    }

    @Test func chineseDurationCalibrationUsesCharactersAndStaysLanguageScoped() {
        let voice = VoiceHandle(profileID: UUID(), conditioningKey: "v1", mode: .icl,
                                model: .init(name: "test", revision: "1", placement: .engineGPU))
        let text = "我们明天继续讨论。", expected = ExpectedDuration.seconds("我们明天继续讨论。", .zh)
        var calibration = DurationCalibration()
        let summary = TTSSummary(audioS: expected * 1.5, frames: 100,
                                 timing: .init(received: 0, started: 0, firstOutput: 0, finished: 0))
        calibration.record(voice: voice, language: .zh, text: text, summary: summary, completed: true)
        #expect(calibration.expectedSeconds(text: text, voice: voice, language: .zh) == expected * 1.5)
        #expect(calibration.scale(voice: voice, language: .en) == 1)
    }

    @Test func backlogChangesOncePerThresholdAndUsesDownwardDeadband() throws {
        var b = BacklogController(config: try TestResources.profile().speak.backlog, language: .en)
        #expect(b.update(renderedS: 3, unrenderedS: 0, inFlightSourceS: 0).level == .normal)
        #expect(b.update(renderedS: 1, unrenderedS: 2, inFlightSourceS: 0.1).tempo == 1.1)
        #expect(b.update(renderedS: 5.1, unrenderedS: 0, inFlightSourceS: 0).mtMode == .concise)
        #expect(b.update(renderedS: 4.5, unrenderedS: 0, inFlightSourceS: 0).level == .concise)
        #expect(b.update(renderedS: 4, unrenderedS: 0, inFlightSourceS: 0).level == .faster)
        #expect(b.update(renderedS: 8.1, unrenderedS: 0, inFlightSourceS: 0).summarizeWaiting)
        #expect(b.update(renderedS: 12.1, unrenderedS: 0, inFlightSourceS: 0).dropOldestWaiting)
    }

    @Test func releaseTailInHostGapFinishesWithObservedAudio() throws {
        var segmenter = SpeakSegmenter(profile: try TestResources.profile().speak, target: .en, start: 0)
        _ = segmenter.audio(.init(start: 0, end: ns(0.8), speech: true, energy: 1))
        _ = segmenter.release(at: ns(0.8))
        _ = segmenter.audio(.init(start: ns(0.8), end: ns(1.049), speech: false, energy: 0))
        let tail = segmenter.audio(.init(start: ns(1.051), end: ns(1.071), speech: false, energy: 0))
        #expect(segmenter.finished)
        #expect(tail.count == 1 && tail[0].isFinalChunk && tail[0].end == ns(1.049))
    }

    @Test func calibrationUsesRawCompleteDurationsAndQueueReplacementKeepsFIFO() {
        let voice = VoiceHandle(profileID: UUID(), conditioningKey: "v1", mode: .icl,
                                model: .init(name: "test", revision: "1", placement: .engineGPU))
        let text = "This sentence has five words."
        let expected = ExpectedDuration.seconds(text, .en)
        var calibration = DurationCalibration()
        let summary = TTSSummary(audioS: expected * 2, frames: 100,
                                 timing: .init(received: 0, started: 0, firstOutput: 0, finished: 0))
        calibration.record(voice: voice, language: .en, text: text, summary: summary, completed: false)
        #expect(calibration.scale(voice: voice, language: .en) == 1)
        calibration.record(voice: voice, language: .en, text: text, summary: summary, completed: true)
        #expect(calibration.expectedSeconds(text: text, voice: voice, language: .en) == expected * 2)
        #expect(calibration.scale(voice: voice, language: .de) == 1)

        var queue = TTSQueue(config: .init(mergeWindowMs: 0, mergeMaxWords: 8, wholeClauseBelowExpectedS: 1.5))
        for id in UInt64(1)...3 { queue.enqueue(clause: id, text: text, lang: .en, at: id * 2_000_000) }
        #expect(queue.replace(clauses: [1, 3], with: 4, text: text, lang: .en, at: 10) == nil)
        #expect(queue.replace(clauses: [1, 2], with: 4, text: text, lang: .en, at: 10) == [1, 2])
        #expect(queue.items.map(\.clause) == [4, 3])
        _ = queue.next(job: 1, voice: voice)
        #expect(queue.replace(clauses: [4], with: 5, text: text, lang: .en, at: 11) == nil)
    }

    @Test func remoteSpeechNeedsDurationEnergyAcousticsAndNewWords() throws {
        var detector = RemoteSpeechDetector(config: try TestResources.profile().speak.floor)
        _ = detector.observe(vadSpeech: false, energyDb: -60, echoScore: nil, volatileText: "", playingText: "", at: 0)
        _ = detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0, volatileText: "", playingText: "hello world", at: ns(1))
        #expect(!detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0,
            volatileText: "other person", playingText: "hello world", at: ns(1.599)).speaking)
        #expect(!detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0.5,
            volatileText: "other person", playingText: "hello world", at: ns(1.6)).speaking)
        #expect(detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0.49,
            volatileText: "other person", playingText: "hello world", at: ns(1.6)).speaking)
        #expect(!detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0,
            volatileText: "hello person", playingText: "hello world", at: ns(1.7)).speaking)
    }

    @Test func floorBoundsYieldNeverClearsAndKeepsPassthroughExclusive() throws {
        var floor = FloorManager(config: try TestResources.profile().speak.floor)
        #expect(floor.observe(remoteSpeaking: true, remoteSilenceMs: 0, isPlaying: true, atBoundary: false, at: ns(1)) == [.finishCurrent(until: ns(2.5))])
        #expect(floor.observe(remoteSpeaking: true, remoteSilenceMs: 0, isPlaying: true, atBoundary: false, at: ns(2.5)) == [.cutAndPause])
        #expect(floor.observe(remoteSpeaking: true, remoteSilenceMs: 0, isPlaying: false, atBoundary: false, at: ns(10.5)) == [.offerClear])
        #expect(floor.observe(remoteSpeaking: false, remoteSilenceMs: 700, isPlaying: false, atBoundary: false, at: ns(11)) == [.resume])
        #expect(floor.observe(remoteSpeaking: true, remoteSilenceMs: 0, isPlaying: true, atBoundary: false, at: ns(11.5)).isEmpty)
        #expect(floor.requestPassthrough(atBoundary: true, at: ns(12)) == [.pause, .passthroughReady])
        floor.passthroughOpened()
        #expect(floor.observe(remoteSpeaking: false, remoteSilenceMs: 5000, isPlaying: false, atBoundary: true, at: ns(20)).isEmpty)
        floor.passthroughClosed(at: ns(20))
        #expect(floor.newPress(at: ns(20.1)) == [.resume])
    }

    @Test func degradationEscalatesWithFreshWindowsAndRecoversOneTierAtATime() {
        var ladder = DegradationLadder()
        #expect(ladder.observe(rtf: 0.7, underrunCount: 0, thermalSerious: false, lowPower: false, at: 0) == nil)
        #expect(ladder.observe(rtf: 0.7, underrunCount: 0, thermalSerious: false, lowPower: false, at: ns(9.9)) == nil)
        for (time, tier) in [(10.0, DegradationLadder.Tier.buffered), (20, .pauseAppleDrafts), (30, .wholeClause), (40, .cloneUnavailable)] {
            #expect(ladder.observe(rtf: 0.7, underrunCount: 0, thermalSerious: false, lowPower: false, at: ns(time))?.to == tier)
        }
        _ = ladder.observe(rtf: 0.35, underrunCount: 0, thermalSerious: false, lowPower: false, at: ns(41))
        #expect(ladder.observe(rtf: 0.35, underrunCount: 0, thermalSerious: false, lowPower: false, at: ns(161))?.to == .wholeClause)
        #expect(ladder.observe(rtf: 0.35, underrunCount: 0, thermalSerious: false, lowPower: false, at: ns(161.1)) == nil)
        var battery = DegradationLadder()
        #expect(battery.observe(rtf: 0.2, underrunCount: 0, thermalSerious: false, lowPower: true, at: 0)?.to == .buffered)
        #expect(battery.observe(rtf: 0.2, underrunCount: 0, thermalSerious: false, lowPower: true, at: ns(200)) == nil)
    }
}

@Suite struct SpeakChineseEchoTests {
    @Test func speakerModeRejectsChineseRemotePhraseButKeepsShortOrUnrelatedSpeech() throws {
        let gate = SpeakLanguageGate(try TestResources.profile().speak)
        let remote = ["我们明天讨论合同细节。"]
        #expect(gate.check("明天讨论合同", speakerMode: true, remoteOverlap: nil, recentRemoteText: remote) == .remoteText)
        #expect(gate.check("明天讨论合同", speakerMode: false, remoteOverlap: nil, recentRemoteText: remote) == nil)
        #expect(gate.check("明天我们去公园", speakerMode: true, remoteOverlap: 0, recentRemoteText: remote) == nil)
        for text in ["好", "好的", "明天见", "好的好的", "哈哈哈哈"] {
            #expect(gate.check(text, speakerMode: true, remoteOverlap: nil, recentRemoteText: [text]) == nil)
        }
        #expect(gate.check("好的", speakerMode: true, remoteOverlap: 0.9, recentRemoteText: []) == .remoteOverlap)
    }

    @Test func chineseFloorEvidenceDistinguishesRemoteSpeechFromPlayedText() throws {
        let config = try TestResources.profile().speak.floor
        var detector = RemoteSpeechDetector(config: config)
        _ = detector.observe(vadSpeech: false, energyDb: -60, echoScore: nil, volatileText: "", playingText: "", at: 0)
        _ = detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0,
            volatileText: "", playingText: "我们明天讨论合同细节", at: 1_000_000_000)
        let afterMinimum = UInt64(1000 + config.ignoreMs) * 1_000_000
        #expect(!detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0,
            volatileText: "明天讨论合同", playingText: "我们明天讨论合同细节", at: afterMinimum).speaking)
        #expect(detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0,
            volatileText: "今天需要检查系统", playingText: "我们明天讨论合同细节", at: afterMinimum).speaking)
        #expect(!detector.observe(vadSpeech: true, energyDb: -40, echoScore: 0.9,
            volatileText: "今天需要检查系统", playingText: "我们明天讨论合同细节", at: afterMinimum).speaking)
    }

    @Test func latinRemoteEchoBehaviorIsPreserved() throws {
        let gate = SpeakLanguageGate(try TestResources.profile().speak)
        #expect(gate.check("check the deployment pipeline", speakerMode: true, remoteOverlap: 0,
            recentRemoteText: ["Please check the deployment pipeline."]) == .remoteText)
        #expect(gate.check("check the deployment pipeline", speakerMode: false, remoteOverlap: 0,
            recentRemoteText: ["Please check the deployment pipeline."]) == nil)
    }
}
