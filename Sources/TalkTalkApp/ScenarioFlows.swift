// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkAudio
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

// The three scene pages' flow diagrams (docs/decisions/2026-11-06-settings-visual-system.md
// §7.1–§7.3) and the facts they draw: one source for the nodes' badges, the page's problem line
// and the scene card's corner, so the meeting check reads the same in the node, the problem line
// and the menu.

private typealias Icon = SubtitleTokens.SettingsIcon

/// The sections a flow node or a menu problem row scrolls to (§2, §6.3, §8.1): on its own page,
/// or on the page a link opens.
enum SettingsAnchor {
    static let microphone = "audio.microphone"
    static let talkTalkMic = "audio.meetingInput"
    static let playback = "audio.playback"
    static let phoneDial = "phone.dial"
    /// 模型 › 语音识别's diagram and problem line.
    static let recognition = "model.recognition"
    /// 模型 › 文本翻译's diagram and problem line (TalkTalkCloudUI draws it).
    static let translation = TranslationSettingsView.flowAnchor
    /// 安装与维护 › 语音资源 › 引擎.
    static let engine = "components.engine"
    static let driver = "components.driver"
    /// 通用 › 使用引导….
    static let onboarding = "general.onboarding"
    /// 隐私与诊断 › 故障检查 › 诊断录音, and 字幕分析's flow.
    static let diagnosticRecording = "diagnostics.recording"
    static let subtitleAnalysis = "diagnostics.analysis"
}

/// What one scene's page reads from the session, the audio check and the components.
@MainActor
struct ScenarioFacts {
    let state: AppState
    let mode: MeetingMode
    var audio: AudioSettingsModel = AppUIModels.shared.audio
    var engine: EngineComponentsModel = AppUIModels.shared.engine
    /// Onboarding step 7's own meeting check, read instead of the running session's.
    var check: MeetingMicCheck? = nil

    var sessionBusy: Bool { state.meetingActive || state.meetingStarting || state.meetingStopping }
    /// This scene's session runs now.
    var running: Bool { state.meetingActive && state.meetingMode == mode }
    /// The phone scene's session is starting, running or stopping.
    var phoneSession: Bool { mode == .phone && sessionBusy && state.meetingMode == .phone }
    /// Another scene's session is starting, running or stopping.
    var anotherRunning: Bool { sessionBusy && state.meetingMode != mode }

    /// The meeting or Phone check (MeetingMicGuard) of this scene's running session.
    var micCheck: MeetingMicCheck {
        if let check { return check }
        return running && mode.supportsSpeaking ? audio.meetingMic : .notChecked
    }

    var voice: VoiceState? {
        guard running else { return nil }
        return mode == .phone ? state.phoneVoice : state.meetingVoice
    }

    /// The other party can hear the original voice now.
    var risk: Bool {
        guard running || check != nil, mode.supportsSpeaking else { return false }
        if case .physicalMic = micCheck { return true }
        return voice?.kind == .remoteHearsOriginal
    }

    var noMicrophone: Bool {
        mode.supportsSpeaking && audio.devicesLoaded && audio.selection.device == nil
    }

    /// The chosen source's bundle id; empty for automatic selection.
    var sourceID: String {
        switch mode {
        case .meeting: state.meetingSourceID
        case .captions: state.videoSourceID
        case .phone: MeetingMode.phoneAppID
        }
    }

    /// The chosen app when it is not open now (no automatic switch to another source).
    var missingSource: String? {
        guard mode != .phone, !sourceID.isEmpty,
              !state.availableSources.contains(where: { $0.id == sourceID }) else { return nil }
        return Self.name(sourceID, in: state.availableSources)
    }

    /// The app this scene listens to: the chosen one, else the running session's own; nil while
    /// automatic selection has not picked one.
    var sourceApp: (id: String, name: String)? {
        if !sourceID.isEmpty { return (id: sourceID, name: Self.name(sourceID, in: state.availableSources)) }
        guard running, let name = state.meetingApp, !name.isEmpty else { return nil }
        let id = state.availableSources.first { $0.name == name }?.id ?? MeetingApp.known.first { $0.name == name }?.id
        return id.map { (id: $0, name: name) }
    }

    var browserSource: Bool {
        guard let id = sourceApp?.id else { return false }
        return ScenarioSourceNote.showsBrowserNote(selectedID: id)
    }

    /// The page's one problem line (§2): only the most severe.
    var problem: SettingsProblem? {
        let app = sourceApp?.name ?? String(localized: "会议应用")
        let risk = risk ? SettingsProblem(.risk, SettingsStatus.risk.spokenName,
                                          help: mode == .phone ? String(localized: "Phone 麦克风选“使用系统设置”")
                                              : String(localized: "在 \(app) 的音频设置里选 TalkTalk Mic")) : nil
        let noMic = noMicrophone ? SettingsProblem(.failed, String(localized: "无可用麦克风")) : nil
        let missing = missingSource.map {
            SettingsProblem(.warn, String(localized: "\($0) 未打开"), help: String(localized: "不会自动换用其他来源"))
        }
        switch mode {
        case .meeting:
            let check: SettingsProblem? = switch micCheck {
            case .nobodyReads: SettingsProblem(.warn, String(localized: "会议尚未使用 TalkTalk Mic"), help: micCheck.text)
            case .notChecked where running: SettingsProblem(.pending, String(localized: "会议麦克风待确认"))
            default: nil
            }
            return SettingsProblem.mostSevere([risk, noMic, missing, check])
        case .captions:
            return SettingsProblem.mostSevere([missing])
        case .phone:
            let check = phoneCheck.status == .warn ? phoneCheck : nil
            return SettingsProblem.mostSevere([risk, noMic, check, state.phoneProblem.map { SettingsProblem(.warn, sentence: $0) }])
        }
    }

    /// The Phone check (§7.2), read by the Phone node and the problem line alike: TalkTalk Mic
    /// read is ok, the physical microphone a risk, nothing reading it during a call orange;
    /// before a call nothing reads it yet.
    var phoneCheck: SettingsProblem {
        switch micCheck {
        case .green: SettingsProblem(.ok, micCheck.text)
        case .physicalMic: SettingsProblem(.risk, String(localized: "Phone 正在使用实体麦克风"), help: micCheck.text)
        case .nobodyReads where state.phoneAudioActive:
            SettingsProblem(.warn, String(localized: "Phone 尚未使用 TalkTalk Mic"), help: micCheck.text)
        case .nobodyReads, .notChecked: SettingsProblem(.pending, String(localized: "通话前检查"))
        }
    }

    /// Why a chip of this page cannot change now: another scene's session holds the shared
    /// language (nil when it can).
    var lockedBy: MeetingMode? { anotherRunning ? state.meetingMode : nil }

    /// The scene card's corner (§3.1): the problem, except a check that has not run yet.
    var cardBadge: CardBadge? {
        guard let problem, problem.status != .pending else { return nil }
        return .status(problem.status, problem.text)
    }

    private static func name(_ id: String, in sources: [AppState.SourceOption]) -> String {
        sources.first { $0.id == id }?.name ?? MeetingApp.named(id)?.name ?? id
    }
}

/// The recognition and synthesis models' state, shared by the 模型 cards and the flow nodes.
extension EngineComponentsModel {
    @MainActor func recognitionProblem(_ state: AppState, speaking: Bool? = nil) -> SettingsProblem? {
        let appleProfile = installedProfile?.usesAppleRecognition == true
        let qwenRequired = speaking.map { $0 ? state.effectiveSpeakASREngine == .qwen : state.effectiveListenASREngine == .qwen }
            ?? (state.effectiveListenASREngine == .qwen || state.effectiveSpeakASREngine == .qwen)
        return SettingsProblem.mostSevere([
            speaking != true && state.meetingActive && state.effectiveListenASREngine == .qwen && state.listenASRFallback
                ? SettingsProblem(.warn, String(localized: "已转 Apple 备用")) : nil,
            qwenRequired && record?.roles["asr"] == nil && !appleProfile
                ? SettingsProblem(.pending, String(localized: "识别模型未安装")) : nil,
            qwenRequired && appleProfile && !installed ? problem : nil
        ])
    }

    @MainActor var synthesisProblem: SettingsProblem? {
        record?.roles["tts"] == nil ? SettingsProblem(.pending, String(localized: "合成模型未安装")) : nil
    }
}

/// TalkTalk Mic's state (`DriverComponentModel.status`), shared by its maintenance card and the
/// flow nodes; nil until the page has built the driver model, and while the driver is loaded.
extension DriverComponentsPage {
    var driverProblem: SettingsProblem? {
        guard let status = model?.status, status.status != .ok else { return nil }
        return status
    }
}

extension AppState.RemoteLanguage {
    /// The language chip's code ("EN").
    var code: String { rawValue.uppercased() }
}

extension SpeakSourceLanguage {
    var title: String { self == .zh ? String(localized: "中文") : String(localized: "英语") }
    var code: String { self == .zh ? String(localized: "中") : "EN" }
}

extension SpeakTargetLanguage {
    var title: String {
        switch self {
        case .zh: String(localized: "中文")
        case .en: String(localized: "英语")
        case .de: String(localized: "德语")
        }
    }
    var code: String { self == .zh ? String(localized: "中") : rawValue.uppercased() }
}

/// What the scene diagrams link to: another page (with ReturnPill) and a section of it.
@MainActor
struct ScenarioLinks {
    let open: (SettingsSection, SettingsSubpage?, String?) -> Void

    func node(_ destination: String, _ section: SettingsSection, _ subpage: SettingsSubpage? = nil,
              anchor: String? = nil) -> NodeLink {
        NodeLink(destination) { open(section, subpage, anchor) }
    }
}

/// The scene factories (§7.1–§7.3). The same meaning sits in the same column in every scene:
/// 识别与翻译 in column 2, the app in column 3, the other party in column 4.
@MainActor
extension FlowGrid {
    /// `links` nil: onboarding step 7's read-only copy (§7.17), without the chips and links.
    static func meeting(_ facts: ScenarioFacts, driver: DriverComponentsPage, links: ScenarioLinks?) -> FlowGrid {
        let state = facts.state
        let remote = FlowNode(String(localized: "对方"), glyph: .symbol(Icon.remote), accessory: links == nil ? nil : .controls {
            HStack(spacing: 4) {
                SourceChip(facts: facts)
                LanguageChip(state: state, speak: false, paired: true)
            }
        })
        return FlowGrid(String(localized: "会议同传声音路径"), lanes: [
            listenLane(facts, remote: remote, links: links),
            originalLane(facts, driver: driver, app: meetingAppNode(facts, links: links), links: links),
            translateLane(facts, links: links)
        ], loop: loop)
    }

    static func phone(_ facts: ScenarioFacts, driver: DriverComponentsPage, links: ScenarioLinks) -> FlowGrid {
        let remote = FlowNode(String(localized: "对方"), glyph: .symbol(SubtitleTokens.ConversationIcon.phoneRemote),
                              accessory: .controls {
                                  LanguageChip(state: facts.state, speak: false, paired: false, lockedBy: facts.lockedBy)
                              })
        return FlowGrid(String(localized: "电话同传声音路径"), lanes: [
            listenLane(facts, remote: remote, links: links),
            originalLane(facts, driver: driver, app: phoneAppNode(facts, links: links), links: links),
            translateLane(facts, links: links)
        ], loop: loop)
    }

    static func video(_ facts: ScenarioFacts, links: ScenarioLinks) -> FlowGrid {
        let app = facts.sourceApp
        let source = FlowNode(String(localized: "应用声音"), glyph: .app(bundleID: app?.id, fallback: Icon.speech),
                              accessory: .controls {
                                  HStack(spacing: 4) {
                                      SourceChip(facts: facts)
                                      LanguageChip(state: facts.state, speak: false, paired: true)
                                  }
                              })
        return FlowGrid(String(localized: "视频字幕声音路径"), lanes: [
            FlowLane(String(localized: "听应用"), gutter: .symbol(Icon.listen), cells: [
                .node(source), .node(recognition(facts, links: links)), .node(subtitles(facts, links: links)), .empty
            ])
        ])
    }

    /// The phone page's three steps (§3.5, §7.2): one lane, no gutter.
    static func phoneSteps(_ checklist: PhoneChecklist, problem: String?, dial: NodeLink) -> FlowGrid {
        // ② waits for interpretation preparation; opening Phone itself remains available in
        // its row. ③ also waits, but not while it is the step in progress.
        let dialState: NodeState = checklist.dialEnabled ? .ready : .dimmed
        let finishState: NodeState = checklist.dialEnabled || checklist.finish != .pending ? .ready : .dimmed
        let headline = problem.map { SettingsProblem(.warn, sentence: $0).text }
        return FlowGrid(String(localized: "通话步骤"), lanes: [
            FlowLane(String(localized: "通话步骤"), cells: [
                .node(FlowNode(String(localized: "准备"), glyph: .step(1, StepState(checklist.prepare)),
                               badge: problem == nil ? nil : .warn, badgeReason: headline,
                               help: String(localized: "用底栏的“准备”"))),
                .node(FlowNode(String(localized: "拨号／接听"), glyph: .step(2, StepState(checklist.dial)),
                               state: dialState, link: checklist.dialEnabled ? dial : nil,
                               help: String(localized: "在系统 Phone 中拨号或接听"))),
                .node(FlowNode(String(localized: "挂断后结束"), glyph: .step(3, StepState(checklist.finish)),
                               state: finishState, help: String(localized: "结束同传不会挂断电话"))),
                .empty
            ])
        ])
    }

    /// 首次连接 (§7.2): the iPhone hands the call to this Mac, where Phone takes it.
    static func phoneSetup() -> FlowGrid {
        FlowGrid(String(localized: "首次连接"), lanes: [
            FlowLane(String(localized: "首次连接"), cells: [
                .node(FlowNode("iPhone", glyph: .symbol(Icon.iPhone),
                               satellite: FlowSatellite(String(localized: "同一账户"), symbol: Icon.sameAccount,
                                                        help: String(localized: "Mac 与 iPhone 登录同一 Apple 账户")),
                               help: String(localized: "在其他设备上通话"))),
                .node(FlowNode("Mac", glyph: .symbol(Icon.thisMac),
                               satellite: FlowSatellite(String(localized: "同一网络"), symbol: Icon.sameNetwork,
                                                        help: String(localized: "Mac 与 iPhone 连接同一网络")))),
                .node(FlowNode("Phone", glyph: .app(bundleID: MeetingMode.phoneAppID, fallback: SubtitleTokens.SceneIcon.phone))),
                .empty
            ], arrows: [0: Icon.handoff])
        ])
    }

    // MARK: lanes

    private static var loop: LoopRow {
        LoopRow(key: TitlebarKey(action: String(localized: "结束翻译"), drawsAction: false, style: .idle),
                text: String(localized: "播完回到原声"), spoken: String(localized: "再点按右⌥结束；译音播完后回到原声"))
    }

    private static func listenLane(_ facts: ScenarioFacts, remote: FlowNode, links: ScenarioLinks?) -> FlowLane {
        FlowLane(String(localized: "听对方"), gutter: .symbol(Icon.listen), cells: [
            .node(remote), .node(recognition(facts, links: links)), .node(subtitles(facts, links: links)), .empty
        ])
    }

    private static func originalLane(_ facts: ScenarioFacts, driver: DriverComponentsPage, app: FlowNode,
                                     links: ScenarioLinks?) -> FlowLane {
        let original = VoiceState.resolve(audio: .original, scene: facts.mode.scene, phoneInputConfirmed: true)
        let remoteSymbol = facts.mode == .phone ? SubtitleTokens.ConversationIcon.phoneRemote : Icon.remote
        let live = facts.voice?.kind == .original
        let driverProblem = driver.driverProblem
        return FlowLane(String(localized: "我说话 · 原声"), gutter: .voice(original, caption: String(localized: "默认")), cells: [
            .node(FlowNode(String(localized: "麦克风"), glyph: .symbol(Icon.physicalMic),
                           badge: facts.noMicrophone ? .failed : nil,
                           badgeReason: facts.noMicrophone ? String(localized: "无可用麦克风") : nil,
                           link: links?.node(String(localized: "音频 · 麦克风"), .audio, anchor: SettingsAnchor.microphone))),
            .node(FlowNode("TalkTalk Mic", glyph: .symbol(Icon.talkTalkMic), badge: driverProblem?.status,
                           badgeReason: driverProblem?.text,
                           link: links?.node(String(localized: "安装与维护 · TalkTalk Mic"), .components, .components(.driver)))),
            .node(app),
            .node(FlowNode(String(localized: "对方听到原声"), glyph: .symbol(remoteSymbol),
                           state: facts.risk ? .risk : live ? .live : .ready))
        ])
    }

    private static func translateLane(_ facts: ScenarioFacts, links: ScenarioLinks?) -> FlowLane {
        let state = facts.state
        let translating = VoiceState.resolve(audio: .translating, scene: facts.mode.scene, phoneInputConfirmed: true)
        let remoteSymbol = facts.mode == .phone ? SubtitleTokens.ConversationIcon.phoneRemote : Icon.remote
        let profile = state.voiceProfilePresent
        return FlowLane(String(localized: "我说话 · 译音"), gutter: .voice(translating), cells: [
            .node(FlowNode(String(localized: "我说"), glyph: .symbol(Icon.me),
                           accessory: .controls {
                               HStack(spacing: 4) {
                                   SpeakSourceChip(state: state, paired: false, mode: facts.mode)
                                   Keycap(key: TitlebarKey(action: String(localized: "开始翻译"), style: .idle), showsAction: false)
                               }
                           }, help: String(localized: "按选定语言识别；点按右⌥开始或结束翻译"))),
            .node(FlowNode(String(localized: "识别与翻译"), glyph: .symbol(Icon.translation),
                           link: links?.node(String(localized: "识别与翻译 · 文本翻译"), .translation, .model(.translation)))),
            .node(FlowNode(String(localized: "我的声音"), glyph: .symbol(Icon.myVoice),
                           badge: profile ? nil : .pending, badgeReason: profile ? nil : String(localized: "未录制"),
                           link: links?.node(String(localized: "我的声音"), .voice),
                           satellite: profile ? nil : FlowSatellite(String(localized: "系统声音"), symbol: Icon.speech,
                                                                    help: String(localized: "未录制时用系统声音"),
                                                                    dashed: true))),
            .node(FlowNode(String(localized: "对方听到译音"), glyph: .symbol(remoteSymbol), accessory: .controls {
                LanguageChip(state: state, speak: true, paired: false, mode: facts.mode)
            }))
        ])
    }

    // MARK: nodes

    private static func recognition(_ facts: ScenarioFacts, links: ScenarioLinks?) -> FlowNode {
        let problem = facts.engine.recognitionProblem(facts.state)
        return FlowNode(String(localized: "识别与翻译"), glyph: .symbol(Icon.translation), badge: problem?.status,
                        badgeReason: problem?.text,
                        link: links?.node(String(localized: "识别与翻译 · 语音识别"), .translation, .model(.recognition)))
    }

    private static func subtitles(_ facts: ScenarioFacts, links: ScenarioLinks?) -> FlowNode {
        FlowNode(String(localized: "双语字幕"), glyph: .symbol(Icon.subtitles),
                 state: facts.state.subtitlesVisible ? .ready : .off,
                 link: links?.node(String(localized: "字幕"), .subtitles))
    }

    /// The meeting app's check (§7.1): the badge the menu's 会议麦克风 line also shows.
    private static func meetingAppNode(_ facts: ScenarioFacts, links: ScenarioLinks?) -> FlowNode {
        let app = facts.sourceApp
        let check = facts.micCheck
        let badge: (SettingsStatus, String) = switch check {
        case .notChecked: (.pending, String(localized: "会议麦克风待确认"))
        case .green: (.ok, check.text)
        case let .physicalMic(app, _): (.risk, String(localized: "\(app) 正在使用实体麦克风"))
        case .nobodyReads: (.warn, String(localized: "会议尚未使用 TalkTalk Mic"))
        }
        return FlowNode(app?.name ?? String(localized: "会议应用"), glyph: .app(bundleID: app?.id, fallback: Icon.unknownApp),
                        state: check.nodeState, badge: badge.0, badgeReason: badge.1,
                        link: links?.node(String(localized: "音频 · TalkTalk Mic"), .audio, anchor: SettingsAnchor.talkTalkMic),
                        // A long app name truncates in the node: the tooltip carries it whole.
                        help: [app?.name, String(localized: "静音请用会议应用的按钮")].compactMap { $0 }.joined(separator: " · "))
    }

    /// The Phone check (§7.2, `ScenarioFacts.phoneCheck`), as the problem line reads it.
    private static func phoneAppNode(_ facts: ScenarioFacts, links: ScenarioLinks?) -> FlowNode {
        let check = facts.phoneCheck
        return FlowNode("Phone", glyph: .app(bundleID: MeetingMode.phoneAppID, fallback: SubtitleTokens.SceneIcon.phone),
                        state: check.status == .warn ? .needsAction : .ready, badge: check.status, badgeReason: check.text,
                        link: links?.node(String(localized: "音频 · TalkTalk Mic"), .audio, anchor: SettingsAnchor.talkTalkMic),
                        help: String(localized: "静音或挂断请用 Phone"))
    }
}

extension StepState {
    init(_ status: PhoneChecklist.Status) {
        switch status {
        case .pending: self = .todo
        case .inProgress: self = .busy
        case .done: self = .done
        }
    }
}

/// The source app chip (§3.4): 自动, the open apps with their icons, a chosen app that is not
/// open (triangle), 刷新列表. Locked during a session.
private struct SourceChip: View {
    let facts: ScenarioFacts

    var body: some View {
        let state = facts.state
        let selected = facts.sourceID
        let missing = facts.missingSource
        let locked = facts.sessionBusy
        let title = selected.isEmpty ? String(localized: "自动") : (facts.sourceApp?.name ?? selected)
        var items = [NodeChipItem(String(localized: "自动"), glyph: .symbol(Icon.auto), isOn: selected.isEmpty) {
            select("")
        }]
        if let missing {
            items.append(NodeChipItem(missing, glyph: .warn, isOn: true) {})
        }
        for option in state.availableSources {
            items.append(NodeChipItem(option.name, glyph: .app(bundleID: option.id), isOn: option.id == selected) {
                select(option.id)
            })
        }
        items.append(.separator)
        items.append(NodeChipItem(String(localized: "刷新列表"), glyph: .symbol(Icon.refresh),
                                  isEnabled: state.onRefreshSources != nil) {
            state.onRefreshSources?()
        })
        // "自动 ▾" is its word alone; a chosen app shows its icon and (truncated) name.
        return NodeChip(title, leading: selected.isEmpty ? .none : .app(bundleID: selected),
                        warn: missing != nil, locked: locked, accessibilityLabel: String(localized: "声音来源"),
                        help: locked ? String(localized: "\(title) · 会话中不可更换") : title, items: items)
    }

    private func select(_ id: String) {
        guard !facts.sessionBusy else { return }
        facts.state.selectSource(id, for: facts.mode)
    }
}

/// 对方语言 or 我的译音 (§3.4, §5.5). Speaking choices belong to the supplied scene (or the
/// current speaking scene on shared model pages). Paired with another control, it is
/// 34 pt wide ("EN ▾"). `lockedBy`: the running scene that holds it now (the chip shows the lock
/// and says which scene to end first).
struct LanguageChip: View {
    @Bindable var state: AppState
    let speak: Bool
    let paired: Bool
    var lockedBy: MeetingMode?
    var mode: MeetingMode?

    var body: some View {
        let mode = mode ?? state.speakLanguageMode
        let selection = state.speakLanguages(for: mode)
        let code = speak ? selection.target.code : state.remoteLanguage.code
        let title = speak ? selection.target.title : state.remoteLanguage.title
        let items = speak ? selection.source.targets.map { language in
            NodeChipItem(language.title, isOn: language == selection.target) {
                state.setSpeakTarget(language, for: mode)
            }
        } : AppState.RemoteLanguage.allCases.map { language in
            NodeChipItem(language.title, isOn: language == state.remoteLanguage) { state.remoteLanguage = language }
        }
        NodeChip(paired ? code : title, width: paired ? 34 : nil, locked: lockedBy != nil,
                 accessibilityLabel: speak ? String(localized: "我的译音") : String(localized: "对方语言"),
                 help: lockedBy.map { String(localized: "\(title) · 先结束\($0.scene.title)") } ?? title, items: items)
    }
}

struct SpeakSourceChip: View {
    @Bindable var state: AppState
    var paired = true
    var mode: MeetingMode?

    var body: some View {
        let mode = mode ?? state.speakLanguageMode
        let source = state.speakLanguages(for: mode).source
        NodeChip(paired ? source.code : source.title, width: paired ? 34 : nil,
                 accessibilityLabel: String(localized: "我说的语言"),
                 help: String(localized: "按\(source.title)识别"),
                 items: SpeakSourceLanguage.allCases.map { language in
                     NodeChipItem(language.title, isOn: language == source) { state.setSpeakSource(language, for: mode) }
                 })
    }
}
