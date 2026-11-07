import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct SpeechStatusPresentationTests {
    @Test func inputLevelTicksNeverChangeTheTitlebarState() throws {
        var model = HUDModel()
        model.meetingStarted()
        model.meetingAudio = .translating
        model.pushToTalk = .holding(level: 0.1, preview: "同一句话", committed: [], queued: 0)
        let voice = try #require(model.voiceState)
        let issue = model.issueSlot(now: 0)
        let key = model.titlebarKey
        for level: Float in [0, 0.8, 0.2] {
            model.pushToTalk = .holding(level: level, preview: "同一句话", committed: [], queued: 0)
            #expect(model.voiceState == voice)
            #expect(model.issueSlot(now: 0) == issue)
            #expect(model.titlebarKey == key)
            #expect(model.activityDetails(now: 0).allSatisfy { $0.level == nil })
        }
    }

    @Test func noticesAndProblemsHaveTypedLifetimesWithoutHidingAudioFacts() throws {
        var model = HUDModel()
        model.meetingStarted()
        model.meetingAudio = .original
        #expect(model.issueSlot(now: 0) == nil)

        model.post(.defaultInputRestored(to: "Built-in"), now: 0)
        let confirmation = try #require(model.issueSlot(now: 1)?.chip)
        #expect(confirmation.tone == .notice)
        #expect(model.voiceState?.kind == .original)
        #expect(model.issueSlot(now: HUDModel.noticeSeconds + 1) == nil)

        model.post(.segmentNotSent, now: 10)
        let problem = try #require(model.issueSlot(now: 11)?.chip)
        #expect(problem.isProblem)
        #expect(problem.label == "这段未发送")
        // A warning must never replace the mode with an implication that the original
        // microphone is now closed: the capsule is a separate, unchanged fact.
        #expect(model.voiceState?.kind == .original)
        #expect(SpeechStatusPresentation(audio: model.meetingAudio).tone == .original)
    }

    @Test func informationalHintsRemainInspectableWithoutTakingOverTheStatus() throws {
        var model = HUDModel()
        model.meetingStarted()
        model.meetingAudio = .translating
        model.post(.meetingSilent, now: 0)
        let chip = try #require(model.issueSlot(now: 1)?.chip)
        #expect(chip.tone == .info && chip.label == "未听到对方")
        #expect(model.voiceState?.kind == .translating)
        #expect(chip.detail == HUDModel.Warning.meetingSilent.text)
    }

    @Test func keyActionsAreTheFourTitlebarVerbs() {
        #expect(SpeechStatusPresentation(audio: .original).keyAction == "开始翻译")
        #expect(SpeechStatusPresentation(audio: .restoringOriginal).keyAction == "开始翻译")
        #expect(SpeechStatusPresentation(audio: .draining, playing: true).keyAction == "开始翻译")
        #expect(SpeechStatusPresentation(audio: .translating).keyAction == "完成发言")
        #expect(SpeechStatusPresentation(audio: .switching).keyAction == "松开确认")
        for audio in [HUDModel.MeetingAudio.phoneReady, .original] {
            #expect(SpeechStatusPresentation(audio: audio, phoneInputConfirmed: false).keyAction == "本机试说")
        }
        #expect(SpeechStatusPresentation(audio: .original, phoneInputConfirmed: true).keyAction == "开始翻译")
        #expect(SpeechStatusPresentation(audio: .phoneReconnecting, phoneInputConfirmed: true).keyAction == nil)
        #expect(SpeechStatusPresentation(audio: .unavailable(reason: "x")).keyAction == nil)
        #expect(SpeechStatusPresentation(audio: .translating).shortcut == "右⌥ 完成发言")
    }

    @Test func micSlashOnlyMeansOriginalOffOrUnavailable() {
        let all: [HUDModel.MeetingAudio] = [.preparing, .phoneReady, .original, .switching, .translating, .draining,
                                            .restoringOriginal, .phoneReconnecting, .unavailable(reason: "x")]
        for audio in all {
            for confirmed: Bool? in [nil, false, true] {
                let status = SpeechStatusPresentation(audio: audio, phoneInputConfirmed: confirmed, playing: true)
                let allowed = audio == .restoringOriginal || audio == .unavailable(reason: "x")
                #expect((status.symbol == "mic.slash") == allowed, "\(audio)")
                #expect(status.symbol != "phone", "\(audio)")
            }
        }
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
        #expect(capture.keyAction == "完成发言")
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
