// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

// Onboarding steps 7 and 8, the scenario page before step 1 and the done page (settings visual
// system §7.17): flow diagrams and status rows from the settings pages, no explanation lines.

private typealias Icon = SubtitleTokens.SettingsIcon
private typealias Ladder = SubtitleTokens.SettingsIcon.Size

extension MeetingMicCheck {
    /// The meeting check without a session (onboarding step 7) in the settings words: the same
    /// as the scene page's meeting-app node and 音频's row. The long sentence is the help.
    var meetingProblem: SettingsProblem {
        switch self {
        case .notChecked:
            SettingsProblem(.pending, String(appLocalized: "会议麦克风待确认"),
                            help: String(appLocalized: "打开会议应用的麦克风测试后自动更新"))
        case .green:
            SettingsProblem(.ok, text)
        case let .physicalMic(app, _):
            SettingsProblem(.risk, String(appLocalized: "对方能听到原声 · 在 \(app) 选 TalkTalk Mic"), help: text)
        case .nobodyReads:
            SettingsProblem(.warn, String(appLocalized: "会议尚未使用 TalkTalk Mic"), help: text)
        }
    }

    /// The meeting-app node's and step 7's ① state (§3.3): orange while nobody reads TalkTalk
    /// Mic; the physical microphone is the risk badge on a ready node, its words in the risk chip
    /// or the scene's 对方听到原声 node.
    var nodeState: NodeState { self == .nobodyReads ? .needsAction : .ready }
}

/// Step 7 (§7.17): the two steps in the meeting app as a StepTrack, the check's one status row
/// and the physical-microphone risk, then the meeting scene's diagram without its chips and
/// links. The check runs while the page shows.
struct MeetingMicStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        let check = model.meetingMic
        let problem = check.meetingProblem
        OnboardingPage(title: StepTitle(.meetingMic, String(appLocalized: "确认会议麦克风"))) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    FlowGrid.meetingMicSteps(check)
                    StatusLabel(problem.text, problem.status, help: problem.help)
                    FactRow([FactChip.risk(String(appLocalized: "实体麦克风 → 对方听到原声"),
                                           help: String(appLocalized: "按键翻译时也关不掉原声"),
                                           spoken: String(appLocalized: "会议应用直接使用实体麦克风时，对方听到原声，TalkTalk 无法在按键翻译时关闭原声"))])
                }
                .padding(.vertical, 4)
            }
            if let driver = model.driverPage {
                Section {
                    FlowGrid.meeting(ScenarioFacts(state: model.appState, mode: .meeting, check: check),
                                     driver: driver, links: nil)
                        .padding(.vertical, 4)
                }
            }
        }
        // What the read-only diagram reads (TalkTalk Mic's badge, 无可用麦克风), loaded as the
        // scene page does: onboarding may resume here before any settings page opened.
        .onAppear {
            model.driverPage?.load()
            AppUIModels.shared.audio.reload()
            model.beginMeetingMicCheck()
        }
        .onDisappear { model.endMeetingMicCheck() }
    }
}

/// Step 8 (§7.17): 收听 plays the English sample through the real pipeline into the subtitle
/// panel; 我说话 tries one 右⌥ turn into the headphones. Each half is its flow, its button and
/// its status at the row's end; what arrived stays below as data.
struct TryItStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        OnboardingPage(title: StepTitle(.tryIt, model.videoOnly ? String(appLocalized: "试一次视频字幕")
                                                                 : String(appLocalized: "试一次听与说"))) {
            listen
            if !model.videoOnly { speak }
        }
        .onDisappear { model.stopActivities() }
    }

    private var listen: some View {
        let demo = model.demo
        let running = demo.phase == .preparing || demo.phase == .playing
        return Section {
            FlowGrid.listenDemo(demo)
                .padding(.vertical, 4)
            HStack(spacing: 8) {
                Button {
                    if running { demo.stop() } else { model.endSpeakDemo(); demo.start() }
                } label: {
                    Label(running ? String(appLocalized: "停止示例") : String(appLocalized: "播放示例"),
                          systemImage: running ? Icon.stop : Icon.start)
                        .labelStyle(.titleAndIcon)
                }
                .help(running ? String(appLocalized: "停止示例") : String(appLocalized: "从当前扬声器或耳机播放"))
                Spacer(minLength: 8)
                if let status = listenStatus { StatusLabel(status.text, status.status, help: status.help) }
            }
            if !demo.lines.isEmpty {
                transcript(ListenDemo.sample, symbol: Icon.sourceText, name: String(appLocalized: "示例原文"))
                transcript(demo.lines.joined(separator: " "), symbol: Icon.translation,
                           name: String(appLocalized: "已收到的中文译文"))
            }
        } header: {
            SectionHeader(String(appLocalized: "收听"), symbol: Icon.listen)
        }
    }

    /// 准备中… / 播放中 · 看字幕面板 / 未收到译文 / 已收到字幕, or why it did not play.
    private var listenStatus: SettingsProblem? {
        let demo = model.demo
        switch demo.phase {
        case .idle:
            // The enabled 播放示例 already says it has not played.
            return nil
        case .preparing:
            return SettingsProblem(.busy, String(appLocalized: "准备中…"), help: String(appLocalized: "正在准备示例和字幕"))
        case .playing:
            return SettingsProblem(.busy, String(appLocalized: "播放中 · 看字幕面板"))
        case .done:
            return demo.lines.isEmpty
                ? SettingsProblem(.warn, String(appLocalized: "未收到译文"), help: String(appLocalized: "示例已结束，但没有收到译文"))
                : SettingsProblem(.ok, String(appLocalized: "已收到字幕"))
        case .failed(let reason):
            return SettingsProblem(.failed, sentence: reason)
        }
    }

    /// The sample and what arrived: data, named by its glyph (the name is the help and VoiceOver).
    private func transcript(_ text: String, symbol: String, name: String) -> some View {
        Label {
            Text(verbatim: text).font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(appLocalized: "\(name)：\(text)"))
    }

    private var speak: some View {
        let state = model.speakDemoState
        let active = state == .preparing || state == .listening || state == .played
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                FlowGrid.speakDemo(state, appState: model.appState)
                FactRow([FactChip(String(appLocalized: "戴耳机 · 先结束其他麦克风测试"), symbol: Icon.headphones, tone: .warn,
                                  help: String(appLocalized: "先结束通话和其他 App 的麦克风测试"),
                                  spoken: String(appLocalized: "先结束通话和其他 App 的麦克风测试，再戴耳机试说"))])
            }
            .padding(.vertical, 4)
            HStack(spacing: 8) {
                Button {
                    if active { model.endSpeakDemo() } else { model.beginSpeakDemo() }
                } label: {
                    Label(active ? String(appLocalized: "停止") : String(appLocalized: "试说"),
                          systemImage: active ? Icon.stop : Icon.physicalMic)
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!active && model.startSpeakDemo == nil)
                .help(active ? String(appLocalized: "停止说话测试") : String(appLocalized: "仅测试翻译；正式会议默认传原声"))
                .accessibilityLabel(active ? String(appLocalized: "停止说话测试") : String(appLocalized: "试说"))
                Spacer(minLength: 8)
                if let status = speakStatus { StatusLabel(status.text, status.status, help: status.help) }
            }
        } header: {
            SectionHeader(String(appLocalized: "我说话"), symbol: Icon.me)
        }
    }

    /// 不可用 / 准备中… / 就绪 (or the demo's own message) / 已播放译音 / 未完成：<原因>.
    private var speakStatus: SettingsProblem? {
        switch model.speakDemoState {
        case .idle:
            return model.startSpeakDemo == nil
                ? SettingsProblem(.pending, String(appLocalized: "不可用"), help: String(appLocalized: "说话测试暂不可用"))
                : nil
        case .preparing:
            return SettingsProblem(.busy, String(appLocalized: "准备中…"), help: String(appLocalized: "正在准备麦克风和耳机播放"))
        case .listening:
            return model.speakDemoStatus.map { SettingsProblem(.waiting, sentence: $0) }
                ?? SettingsProblem(.ok, String(appLocalized: "就绪"), help: String(appLocalized: "点按右⌥开始，说完再点按完成发言，等待译音"))
        case .played:
            return SettingsProblem(.ok, String(appLocalized: "已播放译音"))
        case .failed(let reason):
            let head = SettingsProblem(.failed, sentence: reason)
            return SettingsProblem(.failed, String(appLocalized: "未完成：\(head.text)"), help: reason)
        }
    }
}

/// "你会用 TalkTalk 做什么？" before step 1 (redesign §7, §7.17): the settings window's scene cards,
/// each one a toggle, without summaries; video alone takes the reduced "准备视频字幕" path.
struct ScenarioChoiceStep: View {
    @Bindable var model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("你会用 TalkTalk 做什么？").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("可多选").foregroundStyle(.secondary)
                    .help(String(appLocalized: "只看视频时只需收听、识别与语音资源"))
            }
            CardRow(String(appLocalized: "使用场景，可多选"), items: OnboardingScenario.allCases.map { scenario in
                let mode = OnboardingFlowModel.mode(scenario)
                return CardItem(id: scenario, title: mode.scene.title, symbol: mode.sceneSymbol, summary: mode.sceneSummary)
            }, selected: model.selectedScenarios) { model.toggleScenario($0) }
        }
        .padding(OnboardingLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The done page (§7.17): the menu bar diagram, then the three scenes, each with its one fact
/// as a chip; a row opens settings at that scene.
struct DoneStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        OnboardingPage(title: StepTitle(symbol: SubtitleTokens.OnboardingIcon.done, title: String(appLocalized: "引导完成"))) {
            Section {
                FlowGrid.startFromMenu()
                    .padding(.vertical, 4)
            }
            Section {
                scenarioRow(.meeting,
                            chip: FactChip(String(appLocalized: "输入选 TalkTalk Mic"), symbol: Icon.talkTalkMic,
                                           help: String(appLocalized: "在会议应用的音频设置里")),
                            note: String(appLocalized: "听对方看双语字幕；会议应用的输入选 TalkTalk Mic。"))
                scenarioRow(.phone,
                            chip: FactChip(String(appLocalized: "先准备，再拨号或接听"), symbol: SubtitleTokens.SceneIcon.phone,
                                           help: String(appLocalized: "结束同传后恢复麦克风")),
                            note: String(appLocalized: "固定使用 Mac 的 Phone 和你的 iPhone 号码。先准备同传，再拨号或接听；结束同传后恢复麦克风。"))
                scenarioRow(.captions,
                            chip: FactChip(String(appLocalized: "不用麦克风"), symbol: Icon.noMicrophone,
                                           help: String(appLocalized: "只收听应用声音")),
                            note: String(appLocalized: "只收听应用声音，中文、英语和德语可互译，原文与译文成对显示，不使用麦克风。"))
            }
        }
    }

    /// A scene row: its glyph and name, its chip and the link chevron; it opens settings at that
    /// scene. The scene's sentence is the VoiceOver hint.
    private func scenarioRow(_ mode: MeetingMode, chip: FactChip, note: String) -> some View {
        Button {
            model.openScenario?(mode)
        } label: {
            HStack(spacing: 8) {
                Label(mode.scene.title, systemImage: mode.sceneSymbol)
                Spacer(minLength: 8)
                chip
                Image(systemName: Icon.link)
                    .font(.system(size: Ladder.micro, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.openScenario == nil)
        .accessibilityHint(Text(verbatim: "\(note) \(String(appLocalized: "打开设置中的这个场景"))"))
    }
}

// MARK: - diagrams

@MainActor
extension FlowGrid {
    /// Step 7's StepTrack (§3.5): ① 输入选 TalkTalk Mic → ② 打开麦克风测试, both in the meeting
    /// app. The physical microphone (risk) or no reader yet (warn) badges ①, in the scene
    /// page's node state (`nodeState`); a reader of either kind means the test is open.
    static func meetingMicSteps(_ check: MeetingMicCheck) -> FlowGrid {
        let chosen: StepState
        let tested: StepState
        let badge: (SettingsStatus, String)?
        switch check {
        case .green:
            chosen = .done; tested = .done; badge = nil
        case let .physicalMic(app, _):
            chosen = .todo; tested = .done
            badge = (.risk, String(appLocalized: "\(app) 正在使用实体麦克风"))
        case .nobodyReads:
            chosen = .todo; tested = .todo
            badge = (.warn, String(appLocalized: "会议尚未使用 TalkTalk Mic"))
        case .notChecked:
            chosen = .todo; tested = .todo; badge = nil
        }
        return FlowGrid(String(appLocalized: "会议麦克风步骤"), lanes: [
            FlowLane(String(appLocalized: "会议麦克风步骤"), cells: [
                .node(FlowNode(String(appLocalized: "输入选 TalkTalk Mic"), glyph: .step(1, chosen),
                               state: check.nodeState, badge: badge?.0, badgeReason: badge?.1,
                               help: String(appLocalized: "开启默认输入切换后也可选“默认”"))),
                .node(FlowNode(String(appLocalized: "打开麦克风测试"), glyph: .step(2, tested),
                               help: String(appLocalized: "在会议应用的音频设置里"))),
                .empty, .empty
            ])
        ])
    }

    /// Step 8's 收听 (§7.17): the sample in the meeting's listen lane columns. The sample is live
    /// while it plays; 双语字幕 says whether translations arrived once it ended.
    static func listenDemo(_ demo: ListenDemo) -> FlowGrid {
        let ended = demo.phase == .done
        let arrived = !demo.lines.isEmpty
        let captions: (SettingsStatus, String)? = arrived ? (.ok, String(appLocalized: "已收到字幕"))
            : ended ? (.warn, String(appLocalized: "未收到译文")) : nil
        return FlowGrid(String(appLocalized: "示例音频路径"), lanes: [
            FlowLane(String(appLocalized: "听对方"), gutter: .symbol(Icon.listen), cells: [
                .node(FlowNode(String(appLocalized: "英语示例"), glyph: .symbol(Icon.remote),
                               state: demo.phase == .playing ? .live : .ready,
                               help: String(appLocalized: "从当前扬声器或耳机播放"))),
                .node(FlowNode(String(appLocalized: "识别与翻译"), glyph: .symbol(Icon.translation),
                               help: String(appLocalized: "云端不可用时由 Apple 翻译"))),
                .node(FlowNode(String(appLocalized: "双语字幕"), glyph: .symbol(Icon.subtitles), badge: captions?.0,
                               badgeReason: captions?.1, help: String(appLocalized: "原文与译文在字幕面板成对显示"))),
                .empty
            ])
        ])
    }

    /// Step 8's 我说话 (§7.17): the selected source with 右⌥ → 翻译与合成 → 耳机听译音, in the
    /// translated lane (译音). The speaker is live while the demo listens.
    static func speakDemo(_ state: OnboardingFlowModel.SpeakDemoState, appState: AppState) -> FlowGrid {
        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
        return FlowGrid(String(appLocalized: "试说路径"), lanes: [
            FlowLane(String(appLocalized: "我说话 · 译音"), gutter: .voice(translating), cells: [
                .node(FlowNode(String(appLocalized: "我说"), glyph: .symbol(Icon.me), state: state == .listening ? .live : .ready,
                               accessory: .display {
                                   HStack(spacing: 4) {
                                       Text(verbatim: appState.speakSourceLanguage.title).font(.caption2).foregroundStyle(.secondary)
                                       Keycap(key: TitlebarKey(action: String(appLocalized: "开始翻译"), style: .idle), showsAction: false)
                                   }
                               }, help: String(appLocalized: "按选定语言识别；说完再点按右⌥完成发言"))),
                .node(FlowNode(String(appLocalized: "翻译与合成"), glyph: .symbol(Icon.translation),
                               help: String(appLocalized: "原文和译文显示在“我的发言”区"))),
                .node(FlowNode(String(appLocalized: "耳机听译音"), glyph: .symbol(Icon.headphones),
                               badge: state == .played ? .ok : nil,
                               badgeReason: state == .played ? String(appLocalized: "已播放译音") : nil,
                               accessory: .display {
                                   Text(verbatim: appState.speakLanguage.title).font(.caption2).foregroundStyle(.secondary)
                               },
                               help: String(appLocalized: "译音在耳机里播放"))),
                .empty
            ])
        ])
    }

    /// The done page's small diagram (§7.17): the status item → 开始上次场景, with 选其他场景 as
    /// the dashed other way.
    static func startFromMenu() -> FlowGrid {
        typealias O = SubtitleTokens.OnboardingIcon
        return FlowGrid(String(appLocalized: "从菜单开始"), lanes: [
            FlowLane(String(appLocalized: "从菜单开始"), cells: [
                .node(FlowNode(String(appLocalized: "菜单栏图标"), glyph: .symbol(O.menuBar),
                               help: String(appLocalized: "点菜单栏里的 TalkTalk 图标"))),
                .node(FlowNode(String(appLocalized: "开始上次场景"), glyph: .symbol(O.quickStart),
                               satellite: FlowSatellite(String(appLocalized: "选其他场景"), symbol: O.otherScenes,
                                                        help: String(appLocalized: "菜单里的三个场景"), dashed: true))),
                .empty, .empty
            ])
        ])
    }
}
