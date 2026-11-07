import Testing
@testable import TalkTalkCore

@Suite struct ConversationDockTests {
    @Test func breakpointsAndDockHeights() {
        let regular = ConversationLayout(contentWidth: 760, contentHeight: 480)
        #expect(!regular.stacked && regular.showsColumnHeader && regular.headerHeight == 20)
        #expect(regular.dockHeight(speaking: false) == 48)
        // min(34% of 480 = 163.2, 160)
        #expect(regular.dockHeight(speaking: true) == 160)
        #expect(regular.timelineHeight(dockHeight: 48) == 480 - 20 - 48)
        #expect(abs(ConversationLayout(contentWidth: 760, contentHeight: 300).dockHeight(speaking: true) - 102) < 1e-9)

        #expect(ConversationLayout(contentWidth: 519, contentHeight: 480).stacked)
        #expect(!ConversationLayout(contentWidth: 519, contentHeight: 480).showsColumnHeader)
        #expect(!ConversationLayout(contentWidth: 520, contentHeight: 480).stacked)

        let low = ConversationLayout(contentWidth: 760, contentHeight: 259)
        #expect(low.compactDock && !low.lastRowOnly && low.dockHeight(speaking: false) == 28)
        #expect(!ConversationLayout(contentWidth: 760, contentHeight: 260).compactDock)

        let tiny = ConversationLayout(contentWidth: 760, contentHeight: 139)
        #expect(tiny.lastRowOnly && !tiny.showsColumnHeader && !tiny.dockExpands)
        #expect(tiny.dockHeight(speaking: true) == 28)
        #expect(!ConversationLayout(contentWidth: 760, contentHeight: 140).lastRowOnly)
        #expect(ConversationLayout.minimumContentHeight(translationSize: 22) < 140)
    }

    @Test func pairColumnsAndLongSourceRule() {
        let columns = ConversationLayout.columns(rowWidth: 736, stacked: false)
        // 736 − 24 track − 16 gap = 696: 40% source, 60% translation.
        #expect(columns.sourceX == 24 && columns.sourceWidth == 278)
        #expect(columns.translationX == 24 + 278 + 16 && columns.translationWidth == 418)
        let stacked = ConversationLayout.columns(rowWidth: 400, stacked: true)
        #expect(stacked.sourceWidth == 376 && stacked.translationX == 24 && stacked.translationWidth == 376)

        #expect(ConversationLayout.truncatedSourceHeight(source: 80, translation: 40, sourceLine: 20) == nil)
        #expect(ConversationLayout.truncatedSourceHeight(source: 81, translation: 40, sourceLine: 20) == 60)
        #expect(ConversationLayout.truncatedSourceHeight(source: 200, translation: 0, sourceLine: 20) == nil)
        #expect(ConversationLayout.rowHeight(source: 60, translation: 30, stacked: false) == 6 + 60 + 8)
        #expect(ConversationLayout.rowHeight(source: 20, translation: 30, stacked: true) == 6 + 30 + 4 + 20 + 8)
    }

    @Test func dockTextFollowsTheVoiceState() {
        func dock(_ audio: HUDModel.MeetingAudio?, scene: SubtitleScene = .meeting, confirmed: Bool = false,
                  playing: Bool = false, risk: VoiceState.Risk? = nil) -> MicDockPresentation {
            MicDockPresentation.make(VoiceState.resolve(audio: audio, scene: scene, phoneInputConfirmed: confirmed,
                                                        playing: playing, risk: risk), scene: scene, audio: audio, playing: playing)
        }
        let original = dock(.original)
        #expect(original.label == "原声" && original.consequence == "对方能听到你")
        #expect(original.tone == .original && original.wave == .solid && original.allowsStartHint)
        #expect(original.accessibilityLabel == "麦克风：原声，对方能听到你")
        #expect(dock(.translating).label == "翻译中" && dock(.translating).wave == .solid)
        #expect(dock(.switching).label == "松开右⌥确认" && dock(.switching).wave == .outlined)
        #expect(dock(.draining, playing: true).label == "译音播放中" && dock(.draining, playing: true).wave == .dashed)
        // Draining before any Feed playback is processing, not playback.
        #expect(dock(.draining).label == "译音处理中")
        #expect(dock(.restoringOriginal).label == "正在恢复原声…" && dock(.restoringOriginal).wave == .flat)
        #expect(dock(.phoneReady).label == "未发送" && dock(.phoneReady).consequence == "对方听不到你")

        let risk = dock(.original, risk: .meetingNotUsingMic)
        #expect(risk.label == "对方能听到原声" && risk.consequence == "会议没有使用 TalkTalk Mic")
        #expect(risk.emphasis == .risk && risk.wave == .none && risk.action == .fix && risk.action?.title == "修复…")
        let unavailable = dock(.unavailable(reason: "x"))
        #expect(unavailable.label == "音频不可用" && unavailable.consequence == "未发送")
        #expect(unavailable.emphasis == .unavailable && unavailable.action == .details)
        // 修复… keeps its word in the full dock; 详情 and the compact dock show only the icon,
        // with the title as tooltip and VoiceOver label.
        #expect(MicDockPresentation.Action.fix.symbol == SubtitleTokens.ConversationIcon.fix)
        #expect(MicDockPresentation.Action.details.symbol == SubtitleTokens.ConversationIcon.details)
        #expect(MicDockPresentation.Action.fix.showsTitle(compact: false))
        #expect(!MicDockPresentation.Action.fix.showsTitle(compact: true))
        #expect(!MicDockPresentation.Action.details.showsTitle(compact: false))
        // The hidden consequence stays on hover.
        #expect(risk.toolTip == "对方能听到原声 · 会议没有使用 TalkTalk Mic")
        #expect(dock(.switching).toolTip == "松开右⌥确认")

        // Phone separates local readiness, Phone input and the other person.
        // The capsule's own words: the dock reads the same VoiceState.
        #expect(dock(.phoneReady, scene: .phone).label == "未接入 Phone")
        #expect(MicDockPresentation.startHint == "点按右⌥翻译你的发言")
        #expect(dock(.phoneReady, scene: .phone).consequence == "Phone 尚未接收音频")
        #expect(dock(.original, scene: .phone, confirmed: true).consequence == "正在送入 Phone")
        #expect(dock(.original, scene: .phone).label == "本机收音中")
        #expect(dock(.translating, scene: .phone).label == "本机收音中")
        let localProcessing = dock(.draining, scene: .phone)
        #expect(localProcessing.label == "本机译音处理中" && localProcessing.wave == .dashed)
        #expect(localProcessing.consequence == "Phone 未接收")
        #expect(dock(.draining, scene: .phone, confirmed: true, playing: true).label == "译音播放中")
        let localOnly = dock(.draining, scene: .phone, playing: true)
        #expect(localOnly.label == "本机译音播放中" && localOnly.consequence == nil)
        #expect(localOnly.tone == .warn)
        #expect(dock(.phoneReconnecting, scene: .phone).label == "当前发言已停止")
        #expect(dock(.phoneReconnecting, scene: .phone).consequence == "等待 Phone")
    }

    @Test func speakingPhaseLingersThreeSecondsAfterWorkEnds() {
        var phase = SpeakingDockPhase()
        #expect(!SpeakingDockPhase.isActive(audio: .original, pushToTalk: .idle, workPending: false, expanded: false))
        // A key press alone does not open the dock; it keeps an open turn.
        #expect(!SpeakingDockPhase.isActive(audio: .switching, pushToTalk: .idle, workPending: false, expanded: false))
        #expect(SpeakingDockPhase.isActive(audio: .switching, pushToTalk: .idle, workPending: false, expanded: true))
        #expect(SpeakingDockPhase.isActive(audio: .translating, pushToTalk: .idle, workPending: false, expanded: false))
        #expect(SpeakingDockPhase.isActive(audio: .original, pushToTalk: .idle, workPending: true, expanded: true))
        #expect(SpeakingDockPhase.isActive(audio: nil, pushToTalk: .holding(level: 0, preview: "", committed: [], queued: 0),
                                           workPending: false, expanded: false))
        let opened = phase.update(active: true, now: 10)
        #expect(opened)
        let lingering = phase.update(active: false, now: 20)
        #expect(lingering)
        #expect(phase.nextChange == 23)
        let stillOpen = phase.update(active: false, now: 22.9)
        #expect(stillOpen)
        let closed = phase.update(active: false, now: 23)
        #expect(!closed)
        #expect(phase.nextChange == nil)
        // New work during the linger keeps the dock open.
        phase.update(active: true, now: 30)
        phase.update(active: false, now: 31)
        let reopened = phase.update(active: true, now: 33)
        #expect(reopened)
        #expect(phase.nextChange == nil)
        phase.reset()
        #expect(!phase.isExpanded)
    }

    @Test func reduceMotionKeepsAFlatCurveConstant() {
        let quiet = MicWaveSignal.reducedMotionAlpha(level: 0, wave: .flat)
        #expect(MicWaveSignal.reducedMotionAlpha(level: 1, wave: .flat) == quiet)
        #expect(abs(MicWaveSignal.reducedMotionAlpha(level: 1, wave: .solid) - 0.55) < 1e-9)
        #expect(abs(MicWaveSignal.reducedMotionAlpha(level: 1, wave: .outlined) - 0.33) < 1e-9)
        #expect(MicWaveSignal.reducedMotionAlpha(level: 0.5, wave: .dashed) > quiet)
        // Increase Contrast raises the floor and the peak; flat still ignores the level.
        let quietIC = MicWaveSignal.reducedMotionAlpha(level: 0, wave: .flat, increaseContrast: true)
        #expect(abs(quietIC - 0.35) < 1e-9)
        #expect(MicWaveSignal.reducedMotionAlpha(level: 1, wave: .flat, increaseContrast: true) == quietIC)
        #expect(abs(MicWaveSignal.reducedMotionAlpha(level: 1, wave: .solid, increaseContrast: true) - 0.85) < 1e-9)
        #expect(abs(MicWaveSignal.reducedMotionAlpha(level: 1, wave: .outlined, increaseContrast: true) - 0.51) < 1e-9)
    }

    @Test func increaseContrastStrengthensTheCurve() {
        #expect(MicWaveSignal.colorAlpha(increaseContrast: false) == 0.55)
        #expect(MicWaveSignal.colorAlpha(increaseContrast: true) == 0.85)
        #expect(MicWaveSignal.lineWidth(.solid, increaseContrast: false) == 1.5)
        #expect(MicWaveSignal.lineWidth(.flat, increaseContrast: true) == 2)
        #expect(MicWaveSignal.lineWidth(.dashed, increaseContrast: false) == 1)
        #expect(MicWaveSignal.lineWidth(.outlined, increaseContrast: true) == 1.5)
    }

    @Test func waveSignalFlattensQuietInputAndDisappearsWithoutInput() {
        #expect(MicWaveSignal.normalized(0) == 0)
        #expect(MicWaveSignal.normalized(0.001) == 0)       // −60 dB
        #expect(abs(MicWaveSignal.normalized(0.1) - 40.0 / 60) < 1e-6)   // −20 dB
        #expect(MicWaveSignal.normalized(1) == 1)
        var signal = MicWaveSignal()
        #expect(signal.state == .removed)
        let quiet = signal.feed(0.002, now: 0)                 // about −54 dB: valid but flat
        #expect(quiet)
        #expect(signal.state == .flat && signal.amplitude == 0)
        signal.feed(0.1, now: 0.5)
        #expect(abs(signal.amplitude - 10 * 40.0 / 60) < 1e-5)
        // Missing input keeps the last measurement for 250 ms, then removes the curve.
        let missing = signal.feed(nil, now: 0.625)
        #expect(!missing)
        #expect(signal.expiresAt == 0.75)
        let early = signal.expire(now: 0.7)
        #expect(!early)
        let expired = signal.expire(now: 0.75)
        #expect(expired && signal.state == .removed)
        signal.feed(.nan, now: 1)
        #expect(signal.state == .removed)
        signal.feed(0.5, now: 2)
        let stopped = signal.stop()
        #expect(stopped && signal.state == .removed && signal.expiresAt == nil)
    }
}
