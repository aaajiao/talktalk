import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct SubtitleTokensTests {
    @Test func conversationSizesFollowTheSquareRootWidthRule() {
        let reference = ConversationTypography(base: 22, width: 760)
        #expect(reference.remoteTranslation.size == 22)
        #expect(abs(reference.source.size - 22 * 0.78) < 1e-9)
        #expect(abs(reference.myTranslation.size - 22 * 0.86) < 1e-9)
        #expect(reference.remoteTranslation.weight == .medium && reference.remoteTranslation.lineHeight == 1.34)
        #expect(reference.source.weight == .regular && reference.source.lineHeight == 1.30)
        // √(1520/760) ≈ 1.414 is capped at 1.30; √(380/760) ≈ 0.707 is raised to 0.85.
        #expect(abs(ConversationTypography.translationSize(base: 22, width: 1520) - 22 * 1.3) < 1e-9)
        #expect(abs(ConversationTypography.translationSize(base: 22, width: 380) - 22 * 0.85) < 1e-9)
        #expect(abs(ConversationTypography.translationSize(base: 22, width: 1000) - 22 * (1000.0 / 760).squareRoot()) < 1e-9)
        // Floor 14 even for a small base; the source never drops below 12.
        #expect(ConversationTypography.translationSize(base: 12, width: 480) == 14)
        #expect(ConversationTypography(base: 12, width: 480).source.size == 12)
        #expect(ConversationTypography(base: .nan, width: .nan).remoteTranslation.size == 22)
    }

    @Test func videoSizesDependOnTheBaseWithASmallWidthTrim() {
        #expect(abs(VideoCaptionTypography.translationSize(base: 26, width: 640) - 26 * 0.85) < 1e-9)
        #expect(abs(VideoCaptionTypography.translationSize(base: 26, width: 920) - 26) < 1e-9)
        #expect(abs(VideoCaptionTypography.translationSize(base: 26, width: 1200) - 26 * 1.15) < 1e-9)
        #expect(VideoCaptionTypography.translationSize(base: 26, width: 2400)
                == VideoCaptionTypography.translationSize(base: 26, width: 1200))
        // Narrow floor 18, never above the chosen base.
        #expect(VideoCaptionTypography.translationSize(base: 20, width: 400) == 18)
        #expect(VideoCaptionTypography.translationSize(base: 16, width: 400) == 16)
        let video = VideoCaptionTypography(base: 26, width: 960)
        #expect(video.translation.weight == .semibold && video.translation.lineHeight == 1.30)
        #expect(abs(video.source.size - 26 * 0.66) < 1e-9)
        #expect(VideoCaptionTypography(base: 18, width: 960).source.size == 14)
    }

    @Test func colourTokensAndIncreaseContrastVariants() {
        typealias C = SubtitleTokens.Color
        #expect(C.voiceOriginal.rgba() == SubtitleTokens.RGBA(hex: 0x30D158))
        #expect(C.voiceTranslate.rgba() == SubtitleTokens.RGBA(hex: 0x409CFF))
        #expect(C.voiceTranslate.rgba(lightSurface: true) == SubtitleTokens.RGBA(hex: 0x0A64D6))
        #expect(C.warn.rgba(lightSurface: true) == SubtitleTokens.RGBA(hex: 0xC93400))
        let pairs: [(C, Double, Double)] = [(.textPrimary, 0.92, 1.0), (.textSource, 0.72, 0.85),
                                            (.textSourceLive, 0.80, 0.92), (.textDraft, 0.60, 0.78),
                                            (.separator, 0.08, 0.35), (.noticeStroke, 0.28, 0.6),
                                            (.controlStroke, 0.35, 0.7), (.controlDashed, 0.5, 0.8),
                                            (.controlFill, 0.12, 0.22), (.keycapStroke, 0.3, 0.7),
                                            (.controlSecondary, 0.7, 0.9), (.controlTertiary, 0.6, 0.9),
                                            (.divider, 0.2, 0.5)]
        for (role, normal, contrast) in pairs {
            #expect(role.rgba().alpha == normal)
            #expect(role.rgba(increaseContrast: true).alpha == contrast)
        }
        #expect(SubtitleTokens.trackWidth(increaseContrast: true) == 4)
        #expect(SubtitleTokens.separatorWidth(increaseContrast: true) == 1)
        #expect(SubtitleTokens.effectiveOpacity(0.5, increaseContrast: true) == 0.95)
        #expect(SubtitleTokens.effectiveOpacity(0.5, increaseContrast: false) == 0.5)
        #expect(SubtitleTokens.needsTextShadow(opacity: 0.74) && !SubtitleTokens.needsTextShadow(opacity: 0.75))
    }

    @Test func reduceMotionSwitchesEveryTransitionInstantly() {
        for motion in SubtitleTokens.Motion.allCases where motion != .videoTitlebarHideDelay {
            #expect(motion.duration(reduceMotion: true) == 0)
            #expect(motion.duration(reduceMotion: false) > 0)
        }
        #expect(SubtitleTokens.Motion.noticeFadeOut.seconds == 0.3)
        #expect(SubtitleTokens.Motion.videoTitlebarHideDelay.duration(reduceMotion: true) == 1.5)
    }

    @Test func narrowTitlebarsYieldInTheSpecifiedOrderAndKeepTheCapsule() {
        // Each step saves 10 points from a 100-point trailing group.
        let measure: (TitlebarCompaction) -> Double = { 100 - Double($0.level) * 10 }
        #expect(TitlebarCompaction.choose(windowWidth: 800, reservedLeading: 200, measure: measure).level == 0)
        #expect(TitlebarCompaction.choose(windowWidth: 290, reservedLeading: 200, measure: measure).level == 1)
        #expect(TitlebarCompaction.choose(windowWidth: 100, reservedLeading: 200, measure: measure).level == 5)
        let steps = (0...5).map { TitlebarCompaction(level: $0, windowWidth: 800) }
        #expect(steps.map(\.showsKeyAction) == [true, false, false, false, false, false])
        #expect(steps.map(\.showsPhoneText) == [true, true, false, false, false, false])
        #expect(steps.map(\.showsEndText) == [true, true, true, false, false, false])
        #expect(steps.map(\.showsChipText) == [true, true, true, true, false, false])
        #expect(steps.map(\.showsFullCapsule) == [true, true, true, true, true, false])
        #expect(!TitlebarCompaction(level: 0, windowWidth: 559).showsKeyAction)
    }

    @Test func endButtonMatchesTheScene() {
        #expect(SubtitleScene.video.endTitle == "结束" && SubtitleScene.meeting.endTitle == "结束同传")
        // The end button's label names the session; its help (also the tooltip) names what the
        // meeting or call receives afterwards, since 结束 ends with no confirmation.
        #expect(SubtitleScene.meeting.endAccessibilityLabel == "结束会议同传")
        #expect(SubtitleScene.phone.endAccessibilityLabel == "结束电话同传")
        #expect(SubtitleScene.video.endAccessibilityLabel == "结束视频字幕")
        #expect(SubtitleScene.meeting.endHelp(systemInputSwitched: true)
            == "结束会议同传：会议不会结束；系统麦克风还原后，会议会收到你的原声")
        #expect(SubtitleScene.meeting.endHelp(systemInputSwitched: false)
            == "结束会议同传：会议不会结束；之后会议听不到你的声音")
        #expect(SubtitleScene.phone.endHelp(systemInputSwitched: true)
            == "结束电话同传：通话不会挂断；系统麦克风还原后，对方会听到你的原声")
        #expect(SubtitleScene.phone.endHelp(systemInputSwitched: false)
            == "结束电话同传：通话不会挂断；之后对方听不到你的声音")
        #expect(SubtitleScene.video.endHelp(systemInputSwitched: true) == "结束视频字幕：停止收听和翻译")
    }

    @Test func oneGlyphCarriesOneMeaning() {
        typealias I = SubtitleTokens.VoiceIcon
        // Opening Phone is not delivery; local sound is not muted; a system abort is not the
        // user's end action; reconnecting is not a Reload button.
        #expect(I.openPhone == "arrow.up.forward.app" && I.openPhone != I.sentToPhone)
        #expect(I.thisMac == "laptopcomputer" && I.thisMac != I.localOnly)
        #expect(I.aborted == "xmark.octagon" && I.aborted != I.end)
        #expect(I.reconnecting == "arrow.triangle.2.circlepath")
        for kind in [VoiceState.Kind.phoneLocalTrial, .phoneLocalOnly, .localPlayback] {
            #expect(VoiceState.make(kind, phone: true, risk: nil, reason: nil).symbol == I.thisMac, "\(kind)")
        }
        for kind in [VoiceState.Kind.notSent, .phoneNotConnected] {
            #expect(VoiceState.make(kind, phone: true, risk: nil, reason: nil).symbol == I.localOnly, "\(kind)")
        }
        #expect(VoiceState.make(.phoneReconnecting, phone: true, risk: nil, reason: nil).symbol == I.reconnecting)
        #expect(HUDChip.phoneNotReceiving.symbol == I.thisMac && HUDChip.phoneNotReceiving.label == "Phone 未接收")
        typealias W = HUDModel.Warning
        #expect(W.segmentNotSent.symbol == ConversationTextRules.unsentSymbol)
        #expect(W.unsupportedTextNotSent.symbol == ConversationTextRules.unsentSymbol)
        #expect(W.openAIUnreachable.symbol == "network.slash" && W.openAIKeyInvalid.symbol == "network.slash")
        #expect(W.modelRetired.symbol == I.cloud)
        #expect(W.meetingSilent.symbol == "waveform.slash" && W.meetingSeemsOver.symbol == "person.2.slash")
        #expect(W.audioRestarting.symbol == I.reconnecting && W.tccUnconfirmed.symbol == "hand.raised")
    }

    @Test func settingsGlyphsKeepTheRemotePartyAndMyVoiceApart() {
        typealias S = SubtitleTokens.SettingsIcon
        #expect(S.remote == "person.wave.2" && S.myVoice == "waveform.and.person.filled")
        #expect(S.myVoice != S.remote && S.myVoice != SubtitleTokens.ConversationIcon.remote)
        #expect(S.talkTalkMic != S.physicalMic && S.talkTalkMic != SubtitleTokens.VoiceIcon.original)
        #expect(S.recognition == SubtitleTokens.VoiceIcon.translating && S.audio != S.recognition)
    }

    @Test func keycapShowsStartAndEndAsGlyphsButKeepsLocalTrialAndReleaseAsText() {
        let start = SpeechStatusPresentation(audio: .original)
        #expect(start.keyAction == "开始翻译" && start.keySymbol == "translate")
        let end = SpeechStatusPresentation(audio: .translating)
        #expect(end.keyAction == "结束" && end.keySymbol == "stop.fill")
        #expect(SpeechStatusPresentation(audio: .switching).keySymbol == nil)
        let trial = SpeechStatusPresentation(audio: .original, phoneInputConfirmed: false)
        #expect(trial.keyAction == "本机试说" && trial.keySymbol == nil)
        #expect(SpeechStatusPresentation(audio: .draining).keySymbol == "translate")
    }

    @Test func sceneIconsAreUnified() {
        #expect(SubtitleScene.meeting.symbol == "person.2.wave.2")
        #expect(SubtitleScene.phone.symbol == "phone")
        #expect(SubtitleScene.video.symbol == "play.rectangle")
        #expect(SubtitleTitlebarContent(scene: .phone, source: "Zoom").sourceTitle == "Phone")
    }
}
