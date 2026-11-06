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
                                                        playing: playing, risk: risk), scene: scene)
        }
        let original = dock(.original)
        #expect(original.label == "原声" && original.consequence == "对方能听到你")
        #expect(original.tone == .original && original.wave == .solid && original.allowsStartHint)
        #expect(original.accessibilityLabel == "麦克风：原声，对方能听到你")
        #expect(dock(.translating).label == "翻译中" && dock(.translating).wave == .solid)
        #expect(dock(.switching).label == "松开 右⌥ 确认" && dock(.switching).wave == .outlined)
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

        // Phone separates local readiness, Phone input and the other person.
        #expect(dock(.phoneReady, scene: .phone).label == "电话同传已就绪")
        #expect(dock(.phoneReady, scene: .phone).consequence == "接通后对方才能听到你")
        #expect(dock(.original, scene: .phone, confirmed: true).consequence == "正在送入 Phone")
        #expect(dock(.original, scene: .phone).label == "本机试说")
        #expect(dock(.draining, scene: .phone, confirmed: true, playing: true).label == "译音已送入 Phone")
        let localOnly = dock(.draining, scene: .phone, playing: true)
        #expect(localOnly.label == "译音只在本机播放" && localOnly.consequence == "Phone 没有读取 TalkTalk Mic")
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
