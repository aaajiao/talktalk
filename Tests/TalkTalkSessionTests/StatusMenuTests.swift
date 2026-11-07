import AppKit
import Testing
@testable import TalkTalkCore
@testable import TalkTalkSession

/// Settings visual system §8: the menu bar menu's four states, no 更多, problem rows with their
/// fixes, most severe first.
@Suite struct StatusMenuTests {
    private typealias Row = StatusMenuRow

    private func titles(_ rows: [Row]) -> [String] { rows.map { $0.kind == .separator ? "—" : $0.title } }
    private func row(_ rows: [Row], _ title: String) -> Row? { rows.first { $0.title == title } }
    private func index(_ rows: [Row], _ title: String) -> Int? { rows.firstIndex { $0.title == title } }

    private func voice(_ kind: VoiceState.Kind, phone: Bool = false) -> VoiceState {
        VoiceState.make(kind, phone: phone, risk: nil, reason: nil)
    }

    private func running(_ mode: MeetingMode = .meeting) -> StatusMenuFacts {
        var f = StatusMenuFacts()
        f.phase = .running
        f.mode = mode
        f.meetingApp = mode == .phone ? nil : "Zoom"
        f.elapsed = 723
        f.icon = .listening
        return f
    }

    /// Entries that moved to Settings (§8.6, §9.6 #3).
    private let removed = ["更多", "我的声音…", "隐私与诊断…", "使用引导…", "通知设置…", "电话同传设置…",
                           "语音识别", "字幕翻译：Apple", "会议麦克风：TalkTalk Mic"]

    @Test func idleMenuIsStartScenesLanguagesAndTheTail() {
        let rows = StatusMenu.rows(StatusMenuFacts())
        #expect(titles(rows) == ["开始会议同传 · 自动", "会议同传…", "电话同传…", "视频字幕…", "—",
                                 "显示字幕", "耳机译音", "—",
                                 "设置…", "TalkTalk \(EnginePins.appVersion) (\(EnginePins.appBuild))", "退出 TalkTalk"])
        let start = rows[0]
        #expect(start.kind == .action(.quickStart(.meeting)) && start.bold && start.isEnabled)
        #expect(start.subtitle == "英语 → 中文" && start.symbol == MenuQuickStart.symbol && start.help == nil)
        #expect(rows[1].kind == .action(.openScene(.meeting)) && rows[3].kind == .action(.openScene(.captions)))
        #expect(row(rows, "显示字幕")?.kind == .toggle(.toggleSubtitles, on: true))
        #expect(row(rows, "耳机译音")?.kind == .toggle(.toggleMonitor, on: false))
        #expect(row(rows, "设置…")?.keyEquivalent == "," && row(rows, "退出 TalkTalk")?.keyEquivalent == "q")
        // The app identity stays on one line with the menu's standard monochrome glyph.
        let about = rows.first { $0.command == .about }
        #expect(about?.subtitle == nil && about?.symbol == "bubble.left.and.bubble.right")
        #expect(row(rows, "退出 TalkTalk")?.symbol == nil)
    }

    @Test func menuHasNoLanguageSelectorsAndQuickStartSummarizesVideoDirection() {
        var facts = StatusMenuFacts()
        facts.lastScenario = .captions
        facts.listenLanguage = "中文"
        facts.listenTargetLanguage = "德语"
        #expect(StatusMenu.rows(facts).first?.subtitle == "中文 → 德语")
        for mode in [MeetingMode.meeting, .phone, .captions] {
            facts.mode = mode
            facts.phase = .running
            #expect(!StatusMenu.rows(facts).contains { $0.title.hasPrefix("字幕：") || $0.title.hasPrefix("我说话：") })
        }
    }

    @Test func appIdentityShowsTheVersionAndBuildOnOneLineAndKeepsAbout() {
        var f = StatusMenuFacts()
        f.appName = "TalkTalk Dev"
        f.appVersion = "2.3.4 (567)"
        let about = StatusMenu.rows(f).first { $0.command == .about }
        #expect(about?.title == "TalkTalk Dev 2.3.4 (567)")
        #expect(about?.subtitle == nil)
        #expect(about?.kind == .action(.about) && about?.isEnabled == true)
        #expect(about?.symbol == "bubble.left.and.bubble.right" && about?.tone == nil && about?.keyEquivalent == nil)
    }

    @Test func quickStartNamesTheLastSceneItsSourceAndLanguages() {
        var f = StatusMenuFacts()
        f.lastScenario = .captions
        f.quickStartSource = "Chrome"
        f.listenLanguage = "德语"
        let start = StatusMenu.rows(f)[0]
        #expect(start.title == "开始视频字幕 · Chrome" && start.subtitle == "德语 → 中文")
        #expect(start.kind == .action(.quickStart(.captions)))
        f.lastScenario = .phone
        #expect(StatusMenu.rows(f)[0].title == "准备电话同传")
        var dev = StatusMenuFacts()
        dev.devBuild = true
        #expect(StatusMenu.rows(dev).last?.title == "退出 TalkTalk Dev")
    }

    @Test func unfinishedOnboardingComesFirstAndHoldsTheStart() {
        var f = StatusMenuFacts()
        f.onboardingNeeded = true
        f.onboardingProgress = OnboardingProgress(step: 3, count: 8)
        // Swallowed by the onboarding row (§8.2).
        f.icon = .missing
        f.appleCheck = "Apple：缺少英语识别资源"
        let rows = StatusMenu.rows(f)
        #expect(rows[0].title == "继续使用引导 · 第 3 步，共 8 步" && rows[0].bold)
        #expect(rows[0].kind == .action(.continueOnboarding) && rows[0].symbol == SubtitleTokens.MenuIcon.onboarding)
        #expect(rows[1].kind == .separator)
        #expect(!rows[2].isEnabled && rows[2].help == "完成引导后可用" && rows[2].title == "开始会议同传 · 自动")
        // The scene rows only open Settings.
        #expect(row(rows, "会议同传…")?.isEnabled == true)
        #expect(row(rows, "组件未就绪") == nil && row(rows, "Apple 资源待配置") == nil)
        f.onboardingProgress = nil
        #expect(StatusMenu.rows(f)[0].title == "继续使用引导")
        // Once done, the same facts are problem rows with their fixes.
        f.onboardingNeeded = false
        let done = StatusMenu.rows(f)
        #expect(done[0].kind == .action(.quickStart(.meeting)) && done[0].isEnabled)
        #expect(row(done, "安装与维护…")?.kind == .action(.open(.components)))
        // 通用's 使用引导… row, which carries the same status and downloads again.
        #expect(row(done, "通用设置…")?.kind == .action(.open(.onboarding)))
        #expect(row(done, "Apple 资源待配置")?.help == "Apple：缺少英语识别资源")
    }

    @Test func noStateHasTheMoreSubmenuOrTheEntriesThatMovedToSettings() {
        var states: [StatusMenuFacts] = [StatusMenuFacts(), running(), running(.phone), running(.captions)]
        var onboarding = StatusMenuFacts()
        onboarding.onboardingNeeded = true
        states.append(onboarding)
        for f in states {
            let rows = StatusMenu.rows(f)
            for title in removed { #expect(row(rows, title) == nil, "\(title)") }
            #expect(!rows.contains { $0.title.hasPrefix("字幕：") || $0.title.hasPrefix("我说话：") })
        }
    }

    @Test func runningMeetingHasTitleVoiceEndAndTheSessionRows() {
        var f = running()
        f.voice = voice(.original)
        f.canPlayAnnouncement = true
        f.translation = .openAI
        let rows = StatusMenu.rows(f)
        #expect(Array(titles(rows).prefix(5)) == ["会议同传 · Zoom · 12:03", "原声 · 对方可听到", "结束会议同传", "—", "查看当前场景…"])
        #expect(rows[0].kind == .status && rows[0].live == .sessionTitle && rows[0].symbol == SubtitleTokens.SceneIcon.meeting)
        #expect(rows[1].kind == .status && rows[1].live == .voice && rows[1].tone == .voice(.original))
        #expect(rows[2].kind == .action(.end) && rows[2].symbol == SubtitleTokens.VoiceIcon.end)
        #expect(rows[2].help == SubtitleScene.meeting.endHelp(systemInputSwitched: false))
        #expect(rows[4].kind == .action(.openScene(.meeting)))
        #expect(row(rows, "播放告知语")?.kind == .action(.playAnnouncement))
        let cloud = row(rows, "字幕翻译：OpenAI")
        #expect(cloud?.kind == .status && cloud?.symbol == SubtitleTokens.SettingsIcon.cloud)
        #expect(row(rows, "收听所有应用（备用）")?.kind == .toggle(.toggleGlobalFallback, on: false))
        #expect(row(rows, "锁定字幕位置") == nil && row(rows, "会议同传…") == nil)
        // In use: the toggle names the source it listens to.
        f.usesGlobalFallback = true
        #expect(row(StatusMenu.rows(f), "收听：所有应用（备用）")?.kind == .toggle(.toggleGlobalFallback, on: true))
        // Apple only: no translation line at all (§8.6).
        f.translation = .appleOnly
        #expect(!StatusMenu.rows(f).contains { $0.title.hasPrefix("字幕翻译") })
    }

    /// §5.4 云端 / §8.4: the information line appears whenever a direction's text goes to OpenAI.
    @Test func theCloudLineCoversEitherDirection() {
        func cloud(_ f: StatusMenuFacts) -> Row? { StatusMenu.rows(f).first { $0.symbol == SubtitleTokens.SettingsIcon.cloud } }
        var f = running()
        f.translation = .appleOnly
        f.speakCloud = true
        #expect(cloud(f)?.title == "我说话翻译：OpenAI" && cloud(f)?.kind == .status)
        #expect(cloud(f)?.help == "我说的话以文字发给 OpenAI 翻译")
        f.translation = .openAI
        #expect(cloud(f)?.title == "翻译：OpenAI")
        // A late sentence was still sent: the cloud line stays beside the fallback line.
        f.speakCloud = false
        f.translation = .appleFallback(reason: "deadline")
        #expect(cloud(f)?.title == "字幕翻译：OpenAI" && row(StatusMenu.rows(f), "字幕翻译：Apple 备用") != nil)
        // Nothing leaves this Mac while offline or paused.
        f.translation = .appleFallback(reason: "paused:401")
        #expect(cloud(f) == nil)
        f.translation = .openAI
        f.speakCloud = true
        f.offline = true
        #expect(cloud(f) == nil)
        // 视频字幕 has no 我说话; nothing outside a session.
        var video = running(.captions)
        video.speakCloud = true
        #expect(cloud(video) == nil)
        var idle = StatusMenuFacts()
        idle.translation = .openAI
        idle.speakCloud = true
        #expect(cloud(idle) == nil)
    }

    /// A recognition failure stays in the menu until recognition is rebuilt (§8.6 drops only the
    /// normal-state 语音识别 row).
    @Test func aRecognitionFailureHasItsLine() throws {
        var f = running()
        f.voice = voice(.original)
        f.asrFailure = "字幕识别未能恢复：engine exited"
        let rows = StatusMenu.rows(f)
        let line = try #require(index(rows, "字幕识别出错"))
        #expect(rows[line].tone == .failed && rows[line].help == "字幕识别未能恢复：engine exited")
        #expect(rows[line + 1].kind == .action(.open(.recognition)) && rows[line + 1].indented)
        var idle = StatusMenuFacts()
        idle.asrFailure = "x"
        #expect(row(StatusMenu.rows(idle), "字幕识别出错") == nil)
    }

    /// §5.4 录音: a diagnostic recording and the subtitle analysis show in the menu, with the page
    /// that controls them.
    @Test func recordingLinesComeFirstWithTheirPage() {
        var f = running()
        f.voice = voice(.original)
        f.recording = .recording(tracks: "我 · 译音 · 对方")
        f.savingSubtitleText = true
        f.micCheck = .init(.warn, "会议尚未使用 TalkTalk Mic")
        var rows = StatusMenu.rows(f)
        #expect(Array(titles(rows).prefix(7)) == ["会议同传 · Zoom · 12:03", "原声 · 对方可听到", "录音中：我 · 译音 · 对方", "查看诊断录音…",
                                                  "正在保存字幕文字", "查看字幕分析…", "会议尚未使用 TalkTalk Mic"])
        #expect(rows[2].kind == .status && rows[2].tone == .recording(active: true)
                && rows[2].symbol == SubtitleTokens.SettingsIcon.recordingActive)
        #expect(rows[3].kind == .action(.open(.diagnosticRecording)) && rows[3].indented && rows[3].help == rows[2].help)
        #expect(rows[4].tone == .recording(active: false) && rows[5].kind == .action(.open(.subtitleAnalysis)))
        // Set for the next session, while idle: after the scenes.
        var idle = StatusMenuFacts()
        idle.recording = .planned(thisSession: false)
        rows = StatusMenu.rows(idle)
        #expect(Array(titles(rows)[4...7]) == ["—", "下场将录音", "查看诊断录音…", "—"])
        f.recording = .planned(thisSession: true)
        #expect(row(StatusMenu.rows(f), "本场将录音")?.tone == .recording(active: false))
    }

    @Test func phoneShowsDeliveryAndOpenPhoneAndEndKeepsTheCall() {
        var f = running(.phone)
        f.voice = voice(.original, phone: true)
        f.phoneStatus = "收音已就绪"
        var rows = StatusMenu.rows(f)
        #expect(rows[0].title == "电话同传 · Phone · 12:03")
        let delivery = row(rows, "已送入 Phone")
        #expect(delivery?.symbol == SubtitleTokens.VoiceIcon.sentToPhone && delivery?.live == .phoneDelivery)
        #expect(delivery?.help == "收音已就绪")
        #expect(index(rows, "打开 Phone")! < index(rows, "结束电话同传")!)
        #expect(row(rows, "结束电话同传")?.help?.contains("通话不会挂断") == true)
        #expect(row(rows, "收听所有应用（备用）") == nil)
        f.voice = voice(.phoneLocalOnly, phone: true)
        rows = StatusMenu.rows(f)
        #expect(row(rows, "仅本机 · Phone 未接收")?.symbol == SubtitleTokens.VoiceIcon.thisMac)
        // Ending: one progress row instead of 结束, no Phone rows.
        f.phase = .stopping
        rows = StatusMenu.rows(f)
        #expect(row(rows, "正在结束电话同传…")?.kind == .status && row(rows, "结束电话同传") == nil)
        #expect(row(rows, "打开 Phone") == nil && row(rows, "仅本机 · Phone 未接收") == nil)
    }

    @Test func problemsComeMostSevereFirstEachWithItsFix() {
        var f = running()
        f.voice = voice(.remoteHearsOriginal)
        f.micCheck = .init(.risk, "对方能听到原声 · 在 Zoom 选 TalkTalk Mic", help: "会议绕过 TalkTalk 使用实体麦克风")
        f.asrFallback = true
        f.asrStatus = "Apple Speech（Qwen 不可用，备用接管）"
        f.translation = .appleFallback(reason: "deadline")
        f.icon = .remoteHearsOriginal
        let rows = StatusMenu.rows(f)
        #expect(Array(titles(rows).prefix(8)) == ["会议同传 · Zoom · 12:03", "对方能听到原声", "检查麦克风…",
                                                  "识别：Apple 备用", "识别与翻译…", "字幕翻译：Apple 备用", "识别与翻译…",
                                                  "结束会议同传"])
        // The risk capsule's words are the risk line: not twice.
        #expect(!rows.contains { $0.live == .voice })
        let risk = rows[1], fix = rows[2]
        #expect(risk.kind == .status && risk.tone == .risk && risk.symbol == SubtitleTokens.VoiceIcon.originalRisk)
        #expect(risk.help?.contains("在 Zoom 选 TalkTalk Mic") == true && risk.help?.contains("实体麦克风") == true)
        #expect(fix.indented && fix.kind == .action(.open(.talkTalkMic)) && fix.symbol == SubtitleTokens.SettingsIcon.talkTalkMic)
        #expect(fix.help == risk.help)
        #expect(rows[3].tone == .warn && rows[3].help == f.asrStatus)
        #expect(rows[4].kind == .action(.open(.recognition)) && rows[4].indented)
        #expect(rows[5].help == "⚠︎ 字幕翻译：Apple 翻译（超时）")
        #expect(rows[6].kind == .action(.open(.translation)))
        // The status item's word is not repeated when a line explains its glyph.
        #expect(row(rows, "对方能听到原声")?.kind == .status && rows.filter { $0.title == "对方能听到原声" }.count == 1)
    }

    @Test func meetingCheckWordsAndThePhoneCheckBeforeTheCall() {
        var f = running()
        f.voice = voice(.original)
        f.micCheck = .init(.warn, "会议尚未使用 TalkTalk Mic", help: "尚无会议应用或 Phone 使用 TalkTalk Mic")
        var rows = StatusMenu.rows(f)
        let warn = row(rows, "会议尚未使用 TalkTalk Mic")
        #expect(warn?.tone == .warn && warn?.symbol == SubtitleTokens.MenuIcon.micUnused)
        #expect(index(rows, "原声 · 对方可听到")! < index(rows, "会议尚未使用 TalkTalk Mic")!)
        // Phone before the call: pending, without colour (ScenarioFacts.sessionCheck's words).
        var phone = running(.phone)
        phone.micCheck = .init(.pending, "通话前检查")
        rows = StatusMenu.rows(phone)
        let pending = row(rows, "通话前检查")
        #expect(pending?.tone == .pending && pending?.symbol == SubtitleTokens.SettingsIcon.statusPending)
        #expect(rows[rows.firstIndex { $0.title == "通话前检查" }! + 1].title == "检查麦克风…")
        // Video never uses TalkTalk Mic: no check line, no speaking rows.
        var video = running(.captions)
        video.micCheck = .init(.pending, "未检查")
        video.canPlayAnnouncement = true
        rows = StatusMenu.rows(video)
        for title in ["未检查", "检查麦克风…", "我说话：中文 → 英语", "耳机译音", "播放告知语"] {
            #expect(row(rows, title) == nil, "\(title)")
        }
        let lock = row(rows, "锁定字幕位置")
        #expect(lock?.kind == .toggle(.toggleSubtitleLock, on: false) && lock?.help == "鼠标穿透")
        // And no check outside a session.
        f.phase = .idle
        #expect(row(StatusMenu.rows(f), "会议尚未使用 TalkTalk Mic") == nil)
    }

    @Test func systemInputProblemSitsBetweenScenesAndLanguagesWithItsFixes() {
        var f = StatusMenuFacts()
        f.systemInput = .init(.failed, "上次的麦克风尚未还原", help: "上次会议结束前没能还原默认输入")
        f.restoreNow = true
        f.resumeFromRecord = true
        f.icon = .needsAttention
        let rows = StatusMenu.rows(f)
        #expect(Array(titles(rows).prefix(11)) == ["开始会议同传 · 自动", "会议同传…", "电话同传…", "视频字幕…", "—",
                                                   "上次的麦克风尚未还原", "还原默认输入", "开始会议同传", "查看音频设置…", "—",
                                                   "显示字幕"])
        #expect(rows[5].tone == .failed && rows[5].symbol == SubtitleTokens.SettingsIcon.talkTalkMic)
        #expect(rows[6].kind == .action(.restoreDefaultInput) && rows[6].indented)
        #expect(rows[7].kind == .action(.resumeFromRecord) && rows[7].subtitle == "恢复输入记录")
        #expect(rows[8].kind == .action(.open(.talkTalkMic)))
        // The status word "检查音频设备" is not added: the input line explains the glyph.
        #expect(row(rows, "检查音频设备") == nil)
        var override = StatusMenuFacts()
        override.systemInput = .init(.warn, "系统麦克风已改变")
        override.switchBack = true
        #expect(row(StatusMenu.rows(override), "切回 TalkTalk Mic")?.kind == .action(.switchBackToMic))
    }

    @Test func theStatusWordAppearsOnlyWhenNoLineExplainsTheGlyph() throws {
        var f = running()
        f.voice = voice(.original)
        f.icon = .degraded
        // Playing through a speaker: its own line, sentence and fix, not the bare word.
        f.iconReasons = [.speaker]
        var rows = StatusMenu.rows(f)
        let speaker = try #require(index(rows, "正在外放 · 耳机译音已停用"))
        #expect(rows[speaker].tone == .warn && rows[speaker].help == "停用耳机译音与原声通路，避免回声")
        #expect(rows[speaker + 1].kind == .action(.open(.playback)))
        #expect(row(rows, "使用备用") == nil)
        // Each icon fact has its line and fix.
        f.iconReasons = [.speakTranslation, .playbackUnknown, .systemVoice]
        rows = StatusMenu.rows(f)
        #expect(row(rows, "我说话翻译：Apple 备用") != nil && row(rows, "播放设备未确认") != nil)
        #expect(rows[try #require(index(rows, "译音：系统声音")) + 1].kind == .action(.open(.components)))
        var idleRead = StatusMenuFacts()
        idleRead.icon = .needsAttention
        idleRead.iconReasons = [.talkTalkMicReadWhileIdle]
        rows = StatusMenu.rows(idleRead)
        #expect(row(rows, "有应用在读 TalkTalk Mic")?.tone == .failed && row(rows, "检查音频设备") == nil)
        #expect(rows[try #require(index(rows, "有应用在读 TalkTalk Mic")) + 1].kind == .action(.open(.talkTalkMic)))
        // Nothing names the glyph: the bare word, still with its sentence (and the meeting check).
        f.iconReasons = []
        f.icon = .audioNeedsCheck
        rows = StatusMenu.rows(f)
        let word = try #require(index(rows, "音频未就绪"))
        #expect(rows[word].tone == .warn && rows[word].help != nil)
        #expect(rows[word + 1].kind == .action(.open(.talkTalkMic)))
        f.icon = .degraded
        rows = StatusMenu.rows(f)
        let line = row(rows, "使用备用")
        #expect(line?.kind == .status && line?.tone == .warn && line?.symbol == MenuBarIcon.degraded.symbol && line?.help != nil)
        f.asrFallback = true
        rows = StatusMenu.rows(f)
        #expect(row(rows, "使用备用") == nil && row(rows, "识别：Apple 备用") != nil)
        var idle = StatusMenuFacts()
        idle.icon = .warming
        #expect(row(StatusMenu.rows(idle), "准备中")?.symbol == MenuBarIcon.warming.symbol)
        idle.phase = .starting
        rows = StatusMenu.rows(idle)
        #expect(rows[0].title == "正在准备会议同传…" && rows[0].kind == .status && row(rows, "准备中") == nil)
        #expect(row(rows, "开始会议同传 · 自动") == nil && row(rows, "会议同传…") != nil)
    }

    @Test func hintsKeepTheirChipGlyphAndOfferToKeepListening() {
        var f = running()
        f.meetingHint = MeetingSession.Hint.meetingSeemsOver.rawValue
        var rows = StatusMenu.rows(f)
        let hint = row(rows, MeetingSession.Hint.meetingSeemsOver.rawValue)
        #expect(hint?.kind == .status && hint?.tone == nil)
        #expect(hint?.symbol == HUDModel.Warning.meetingSeemsOver.chip(scene: .meeting)?.symbol)
        let keep = row(rows, "继续收听")
        #expect(keep?.kind == .action(.stillInMeeting) && keep?.indented == true
                && keep?.symbol == SubtitleTokens.VoiceIcon.listening)
        // 视频字幕's chip: the app's sound, not people.
        f.mode = .captions
        rows = StatusMenu.rows(f)
        #expect(row(rows, MeetingSession.Hint.meetingSeemsOver.rawValue)?.symbol == "waveform.slash")
        f.meetingHint = MeetingSession.Hint.audioRestarting.rawValue
        rows = StatusMenu.rows(f)
        #expect(row(rows, MeetingSession.Hint.audioRestarting.rawValue)?.tone == .warn && row(rows, "继续收听") == nil)
    }

    @Test func automaticSourceAndFailedEndHaveTheirRows() throws {
        var f = running()
        f.meetingApp = ""
        #expect(row(StatusMenu.rows(f), "确认应用…")?.kind == .action(.openScene(.meeting)))
        f.usesGlobalFallback = true
        #expect(row(StatusMenu.rows(f), "确认应用…") == nil)
        var idle = StatusMenuFacts()
        idle.lastEndProblem = .phone
        let rows = StatusMenu.rows(idle)
        let ended = try #require(index(rows, "电话同传因错误已结束"))
        #expect(rows[ended].tone == .warn && rows[ended + 1].kind == .action(.openScene(.phone)) && rows[ended + 1].indented)
    }

    @Test func statusWordsAreTheShortOnes() {
        #expect(MenuBarIcon.missing.statusText(mode: .meeting) == "组件未就绪")
        #expect(MenuBarIcon.warming.statusText(mode: .meeting) == "准备中")
        #expect(MenuBarIcon.speaking.statusText(mode: .meeting) == "识别/播放译音")
        #expect(MenuBarIcon.audioNeedsCheck.statusText(mode: .meeting) == "音频未就绪")
        #expect(MenuBarIcon.degraded.statusText(mode: .meeting) == "使用备用")
        #expect(MenuBarIcon.needsAttention.statusText(mode: .meeting) == "检查音频设备")
        #expect(MenuBarIcon.passthroughOpen.statusText(mode: .meeting) == "原声中")
        #expect(MenuBarIcon.remoteHearsOriginal.statusText(mode: .meeting) == "对方能听到原声")
        #expect(MenuBarIcon.listening.statusText(mode: .phone) == "电话同传运行中")
    }

    /// A missing SF Symbol draws nothing: every glyph any state names exists (the risk glyph's
    /// fallback parts where the system lacks it).
    @Test func everyRowGlyphExists() {
        var all = StatusMenuFacts()
        all.onboardingNeeded = true
        all.systemInput = .init(.warn, "系统麦克风已改变")
        all.switchBack = true; all.restoreNow = true; all.resumeFromRecord = true
        all.lastEndProblem = .meeting
        var finished = all
        finished.onboardingNeeded = false
        finished.icon = .missing
        finished.appleCheck = "Apple"
        var session = running(.phone)
        session.voice = voice(.phoneLocalOnly, phone: true)
        session.micCheck = .init(.warn, "Phone 尚未使用 TalkTalk Mic")
        session.meetingHint = MeetingSession.Hint.meetingSeemsOver.rawValue
        session.canRestoreWindow = true; session.canPlayAnnouncement = true
        var meeting = running()
        meeting.voice = voice(.remoteHearsOriginal)
        meeting.micCheck = .init(.risk, "对方能听到原声")
        meeting.asrFallback = true; meeting.translation = .openAI; meeting.meetingApp = ""
        var video = running(.captions)
        video.icon = .degraded
        var facts = running()
        facts.iconReasons = MenuBarIcon.Reason.allCases
        facts.recording = .recording(tracks: "我")
        facts.savingSubtitleText = true
        facts.asrFailure = "x"
        facts.speakCloud = true
        var symbols = Set<String>()
        for f in [all, finished, session, meeting, video, facts] {
            for row in StatusMenu.rows(f) { if let s = row.symbol { symbols.insert(s) } }
        }
        #expect(symbols.count > 20)
        for name in symbols {
            if name == SubtitleTokens.VoiceIcon.originalRisk {
                for part in [SubtitleTokens.VoiceIcon.original, SubtitleTokens.VoiceIcon.originalRiskFallbackBadge] {
                    #expect(NSImage(systemSymbolName: part, accessibilityDescription: nil) != nil, "\(part)")
                }
            } else {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }
    }
}
