// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSettingsUI

/// Independent recognition, translation and local synthesis choices.
enum ModelSettingsStage: String, CaseIterable, Identifiable {
    case recognition, translation, synthesis
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recognition: String(appLocalized: "语音识别")
        case .translation: String(appLocalized: "文本翻译")
        case .synthesis: String(appLocalized: "语音合成")
        }
    }
    /// Compact card text. The full title and purpose remain available to accessibility.
    var navigationTitle: String {
        switch self {
        case .recognition: String(appLocalized: "nav.model.recognition")
        case .translation: String(appLocalized: "nav.model.translation")
        case .synthesis: String(appLocalized: "nav.model.synthesis")
        }
    }

    var symbol: String {
        switch self {
        case .recognition: SubtitleTokens.SettingsIcon.recognition
        case .translation: SubtitleTokens.SettingsIcon.translation
        case .synthesis: SubtitleTokens.SettingsIcon.speech
        }
    }
    /// The card's help and VoiceOver hint (settings visual system §3.1); the arrows between the
    /// cards draw the same steps.
    var summary: String {
        switch self {
        case .recognition: String(appLocalized: "声音 → 原文")
        case .translation: String(appLocalized: "原文 → 译文")
        case .synthesis: String(appLocalized: "译文 → 声音")
        }
    }
}

extension SettingsAnchor {
    static let synthesis = "model.synthesis"
}

/// The three stage cards sit in the window's fixed band. Voice recording stays in 我的声音;
/// the synthesis card only chooses which local model renders that voice.
struct ModelSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    let translation: TranslationPage
    var engine: EngineComponentsModel = AppUIModels.shared.engine

    private typealias Icon = SubtitleTokens.SettingsIcon

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Group {
                    switch navigation.modelStage {
                    case .recognition: recognition
                    case .translation: TranslationPageView(page: translation, state: state, flash: navigation.flow,
                                                           openLanguages: { mode in
                                                               state.requestedScenario = mode
                                                               navigation.open(.meeting)
                                                           })
                    case .synthesis: synthesis
                    }
                }
                // A menu problem row lands on the stage's diagram (§8.1).
                .settingsAnchorTarget(navigation, proxy)
            }
        }
        .settingsPageScroll(navigation, subpage: navigation.modelStage)
        .onAppear {
            engine.reload()
            // The 文本翻译 card's badge reads the model (only whether the key item exists).
            translation.load()
        }
    }

    /// A node link: ReturnPill on the target page leads back to this stage.
    private var links: ScenarioLinks {
        ScenarioLinks { section, subpage, anchor in
            if section == .meeting {
                state.requestedScenario = state.speakLanguageMode
            }
            navigation.open(section, subpage, anchor: anchor)
        }
    }

    private var recognition: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    FlowGrid.recognition(state, engine: engine, links: links)
                    if let problem = engine.recognitionProblem(state) {
                        StatusLabel(problem.text, problem.status, help: problem.help)
                    }
                    FactRow([FactChip(String(appLocalized: "本机识别"), symbol: Icon.thisMac,
                                      help: String(appLocalized: "声音在这台 Mac 上转成原文"))])
                }
                .padding(.vertical, 4)
                .flowFlash(SettingsAnchor.recognition, in: navigation.flow)
            }
            .id(SettingsAnchor.recognition)
        }
        .formStyle(.grouped)
    }

    private var synthesis: some View {
        Form {
            Section {
                FlowGrid.synthesis(state, engine: engine, links: links)
                    .padding(.vertical, 4)
                    .flowFlash(SettingsAnchor.synthesis, in: navigation.flow)
                FactRow([FactChip(String(appLocalized: "仅本机 · 不上传"), symbol: Icon.thisMac,
                                  help: String(appLocalized: "语音合成在这台 Mac 上运行"))])
            }
            .id(SettingsAnchor.synthesis)
            Section {
                SynthesisModelRows(model: engine)
                if engine.synthesisModels.isEmpty {
                    Button {
                        navigation.open(.components, .components(.engine))
                    } label: {
                        Label(String(appLocalized: "安装与维护 · 语音资源"), systemImage: Icon.install)
                    }
                }
            } header: {
                SectionHeader(String(appLocalized: "语音合成"), symbol: Icon.speech)
            }
        }
        .formStyle(.grouped)
        .labelStyle(.settingsRow)
    }
}

/// Model-stage diagrams. Voice enrollment remains in 我的声音.
@MainActor
extension FlowGrid {
    static func synthesis(_ state: AppState, engine: EngineComponentsModel, links: ScenarioLinks) -> FlowGrid {
        typealias Icon = SubtitleTokens.SettingsIcon
        let problem = SettingsProblem.mostSevere([engine.synthesisProblem,
                                                  engine.canSelectSynthesis ? nil : engine.problem])
        let voice = state.voiceProfilePresent
            ? FlowSatellite(String(appLocalized: "我的声音"), symbol: Icon.myVoice,
                            help: String(appLocalized: "用我的声音合成译音"),
                            link: links.node(String(appLocalized: "我的声音"), .voice))
            : FlowSatellite(String(appLocalized: "系统声音"), symbol: Icon.speech,
                            help: String(appLocalized: "未录制时用系统声音"), dashed: true,
                            link: links.node(String(appLocalized: "我的声音"), .voice))
        return FlowGrid(String(appLocalized: "语音合成路径"), lanes: [
            FlowLane(String(appLocalized: "译音"), gutter: .symbol(Icon.speech), cells: [
                .node(FlowNode(String(appLocalized: "译文"), glyph: .symbol(Icon.translation))),
                .node(FlowNode(String(appLocalized: "合成译音"), glyph: .symbol(Icon.speech),
                               badge: problem?.status, badgeReason: problem?.text,
                               link: problem == nil ? nil : links.node(String(appLocalized: "安装与维护 · 语音资源"),
                                                                       .components, .components(.engine)),
                               satellite: voice,
                               help: engine.modelName(role: "tts"))),
                .node(FlowNode(String(appLocalized: "译音"), glyph: .symbol(Icon.speech))), .empty
            ])
        ])
    }

    /// Each lane chooses recognition independently from the local model preset and TTS.
    /// Legacy synthesis-only installations retain their intentional Apple path.
    static func recognition(_ state: AppState, engine: EngineComponentsModel, links: ScenarioLinks) -> FlowGrid {
        typealias Icon = SubtitleTokens.SettingsIcon
        let problem = engine.recognitionProblem(state, speaking: false)
        let appleProfile = engine.usesAppleRecognition
        let configuredForApple = engine.usesAppleRecognition
        let missing = engine.record?.roles["asr"] == nil && !configuredForApple
        let qwen = state.effectiveListenASREngine == .qwen
        let fellBack = state.meetingActive && state.listenASRFallback
        let manage = missing || configuredForApple
            ? links.node(String(appLocalized: "安装与维护 · 语音资源"), .components, .components(.engine)) : nil
        let model = engine.modelName(role: "asr")
        let speakProblem = engine.recognitionProblem(state, speaking: true)
        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
        let listen = FlowNode(String(appLocalized: "识别"), glyph: .symbol(Icon.recognition),
                              badge: problem?.status, badgeReason: problem?.text, link: manage,
                              accessory: .controls { RecognitionEngineChip(state: state, engine: engine) },
                              // Apple stands by for Qwen; solid once it took over.
                              satellite: qwen ? FlowSatellite(String(appLocalized: "备用 Apple"), symbol: Icon.thisMac,
                                                              help: fellBack ? String(appLocalized: "Apple Speech 已接管")
                                                                             : String(appLocalized: "Qwen 不可用时接管"),
                                                              dashed: !fellBack) : nil,
                              help: appleProfile ? RecognitionEngineChip.legacyProfileHelp : qwen ? model : nil)
        let speak = FlowNode(String(appLocalized: "识别"), glyph: .symbol(Icon.recognition),
                             badge: speakProblem?.status,
                             badgeReason: speakProblem?.text,
                             link: manage,
                             accessory: .controls { RecognitionEngineChip(state: state, engine: engine, speaking: true) },
                             satellite: FlowSatellite(String(appLocalized: "术语表"), symbol: Icon.glossary,
                                                      help: String(appLocalized: "常用中英文名称帮助识别"),
                                                      link: links.node(String(appLocalized: "术语表"), .glossary)),
                             help: appleProfile ? RecognitionEngineChip.legacyProfileHelp
                                : state.effectiveSpeakASREngine == .qwen
                                    ? [model, String(appLocalized: "Apple Speech 备用")].compactMap { $0 }.joined(separator: " · ") : nil)
        let source = FlowNode(String(appLocalized: "原文"), glyph: .symbol(Icon.sourceText))
        return FlowGrid(String(appLocalized: "语音识别路径"), lanes: [
            FlowLane(String(appLocalized: "听对方"), gutter: .symbol(Icon.listen), cells: [
                .node(FlowNode(String(appLocalized: "应用声音"), glyph: .symbol(Icon.remote))), .node(listen), .node(source), .empty
            ]),
            FlowLane(String(appLocalized: "我说话 · 译音"), gutter: .voice(translating), cells: [
                .node(FlowNode(String(appLocalized: "我说"), glyph: .symbol(Icon.me),
                               link: links.node(String(appLocalized: "使用场景"), .meeting),
                               accessory: .display {
                                   Text(verbatim: state.speakSourceLanguage.title).font(.caption2).foregroundStyle(.secondary)
                               },
                               help: String(appLocalized: "按选定语言识别；点按右⌥开始或结束翻译"))),
                .node(speak), .node(source), .empty
            ])
        ])
    }

}

/// 识别引擎 (§3.4, §7.8): Qwen3-ASR or Apple Speech, in effect at once (a running session
/// rebuilds its recognition).
private struct RecognitionEngineChip: View {
    @Bindable var state: AppState
    let engine: EngineComponentsModel
    var speaking = false

    static var legacyProfileHelp: String {
        String(appLocalized: "当前配置仅包含语音合成模型，识别使用 Apple Speech；如需 Qwen3-ASR，请在“安装与维护”的语音资源中选择本地组合。")
    }

    var body: some View {
        let appleProfile = engine.usesAppleRecognition
        let effective = speaking ? state.effectiveSpeakASREngine : state.effectiveListenASREngine
        let qwen = effective == .qwen
        NodeChip(effective.title,
                 accessibilityLabel: speaking ? String(appLocalized: "我说话识别引擎") : String(appLocalized: "听对方识别引擎"),
                 help: appleProfile ? Self.legacyProfileHelp : String(appLocalized: "选择识别引擎不会下载模型或更改语音合成"),
                 items: [
                     NodeChipItem(appleProfile ? String(appLocalized: "Qwen3-ASR（当前档位未包含）") : "Qwen3-ASR",
                                  isOn: qwen, isEnabled: !appleProfile) { select(.qwen) },
                     NodeChipItem("Apple Speech", isOn: !qwen) { select(.apple) }
                 ])
    }

    private func select(_ value: AppState.ListenASREngine) {
        if speaking { state.speakASREngine = value }
        else { state.listenASREngine = value }
    }
}
