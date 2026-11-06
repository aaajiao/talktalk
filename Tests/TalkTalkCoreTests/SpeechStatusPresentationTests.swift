import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct SpeechStatusPresentationTests {
    @Test func inputLevelTicksNeverChangeTheCompactStatusOrItsDetails() throws {
        var model = HUDModel()
        model.meetingStarted()
        model.meetingAudio = .translating
        model.pushToTalk = .holding(level: 0.1, preview: "同一句话", committed: [], queued: 0)
        let first = try #require(model.compactStatus(now: 0))
        for level: Float in [0, 0.8, 0.2] {
            model.pushToTalk = .holding(level: level, preview: "同一句话", committed: [], queued: 0)
            let changed = try #require(model.compactStatus(now: 0))
            #expect(changed == first)
            #expect(changed.summary.level == nil)
            #expect(changed.details.allSatisfy { $0.level == nil })
        }
    }

    @Test func noticesAndProblemsHaveTypedLifetimesWithoutHidingAudioFacts() throws {
        var model = HUDModel()
        model.meetingStarted()
        model.meetingAudio = .original
        #expect(model.compactStatus(now: 0)?.kind == .activity)

        model.post(.defaultInputRestored(to: "Built-in"), now: 0)
        let confirmation = try #require(model.compactStatus(now: 1))
        #expect(confirmation.kind == .notice)
        #expect(confirmation.details.contains { $0.text == HUDModel.MeetingAudio.original.text })
        #expect(model.compactStatus(now: HUDModel.noticeSeconds + 1)?.kind == .activity)

        model.post(.segmentNotSent, now: 10)
        let problem = try #require(model.compactStatus(now: 11))
        #expect(problem.kind == .problem)
        #expect(problem.summary.text == HUDModel.Warning.segmentNotSent.summary)
        #expect(problem.details.contains { $0.text == HUDModel.MeetingAudio.original.text })
        // The presenter consumes this fact separately from the problem. A warning must never
        // replace the mode with an implication that the original microphone is now closed.
        #expect(SpeechStatusPresentation(audio: model.meetingAudio).tone == .original)
    }

    @Test func informationalHintsRemainInspectableWithoutTakingOverTheStatus() throws {
        var model = HUDModel()
        model.meetingStarted()
        model.meetingAudio = .translating
        model.post(.passthroughTip, now: 0)
        model.post(.meetingSilent, now: 0)
        let status = try #require(model.compactStatus(now: 1))
        #expect(status.kind == .activity)
        #expect(status.summary.text == HUDModel.MeetingAudio.translating.text)
        #expect(status.details.contains { $0.text == HUDModel.Warning.passthroughTip.line.text })
        #expect(status.details.contains { $0.text == HUDModel.Warning.meetingSilent.line.text })
    }

    @Test func unconfirmedPhoneNeverShowsOriginalTransmission() {
        for mode in [HUDModel.MeetingAudio.phoneReady, .original, .translating, .draining, .restoringOriginal] {
            for playing in [false, true] {
                let local = SpeechStatusPresentation(audio: mode, phoneInputConfirmed: false, playing: playing)
                #expect(local.tone != .original)
                #expect(local.title != "原声")
                #expect(!local.title.contains("发送"))
            }
        }
        let original = SpeechStatusPresentation(audio: .original, phoneInputConfirmed: false)
        #expect(original.detail.contains("不能确认原声已送入 Phone"))
        let localPlayback = SpeechStatusPresentation(audio: .draining, phoneInputConfirmed: false, playing: true)
        #expect(localPlayback.title.contains("本机"))
        #expect(localPlayback.detail.contains("未确认 Phone 接入"))
    }

    @Test func preparedPhoneAndRestoringGateRemainNeutralEvenWithAReader() {
        #expect(SpeechStatusPresentation(audio: .phoneReady, phoneInputConfirmed: true).tone == .ready)
        #expect(SpeechStatusPresentation(audio: .restoringOriginal, phoneInputConfirmed: true).tone == .progress)
        let original = SpeechStatusPresentation(audio: .original, phoneInputConfirmed: true)
        #expect(original.tone == .original)
        #expect(!original.detail.contains("对方已听"))
    }

    @Test func processingBecomesPlaybackOnlyWhenActualOutputIsActive() {
        let processing = SpeechStatusPresentation(audio: .draining, playing: false)
        let playback = SpeechStatusPresentation(audio: .draining, playing: true)
        #expect(processing.tone == .progress)
        #expect(processing.symbol != playback.symbol)
        #expect(processing.title != playback.title)
        #expect(playback.symbol == "speaker.wave.2.fill")
        #expect(processing.shortcut == playback.shortcut)

        // Input and output may overlap. Output activity must not erase ongoing capture.
        let capture = SpeechStatusPresentation(audio: .translating, playing: false)
        let captureAndOutput = SpeechStatusPresentation(audio: .translating, playing: true)
        #expect(captureAndOutput == capture)
        #expect(capture.shortcut?.contains("结束收音") == true)
    }

    @Test func unavailableAudioHasNoRecordingActionAndRetainsTheReason() {
        let status = SpeechStatusPresentation(audio: .unavailable(reason: "设备断开"), phoneInputConfirmed: false)
        #expect(status.tone == .unavailable)
        #expect(status.shortcut == nil)
        #expect(status.detail == "设备断开")
    }

    @Test func videoListeningHasNoMicrophoneShortcutOrOutputIndicator() {
        for playing in [false, true] {
            let status = SpeechStatusPresentation(audio: nil, playing: playing)
            #expect(status.shortcut == nil)
            #expect(status.symbol == "ear")
            #expect(status.tone == .ready)
            #expect(status.detail.contains("麦克风未开启"))
        }
    }
}
