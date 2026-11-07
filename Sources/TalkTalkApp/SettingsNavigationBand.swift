// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCloudUI
import TalkTalkCore
import TalkTalkDriverSupport
import TalkTalkSettingsUI

/// Z1 of the settings detail container (settings visual system §2, §6): the page's card row,
/// pinned above the page's Form, never collapsed and never scrolled, with a native divider
/// under it. 字幕 has its GlobalRow above the scene cards; single pages keep only the divider. The cards
/// carry state: the running scene, and a corner badge wherever a sub-page needs something
/// (no badge = ready), read from the models the pages already own.
struct SettingsNavigationBand: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    let translation: TranslationPage
    let driver: DriverComponentsPage
    let subtitles: SubtitleSettingsModel
    var engine: EngineComponentsModel = AppUIModels.shared.engine
    var privacy: PrivacySettings = .shared

    private typealias Icon = SubtitleTokens.SettingsIcon

    var body: some View {
        switch navigation.selection ?? .general {
        case .meeting:
            band { ScenarioCardHeader(state: state) }
        case .subtitles:
            band {
                VStack(alignment: .leading, spacing: 10) {
                    globalRow
                    ScenarioCardHeader(state: state)
                }
            }
        case .translation:
            band {
                CardRow(SettingsSection.translation.title, items: ModelSettingsStage.allCases.map(modelCard),
                        selection: $navigation.modelStage, arrows: true)
            }
        case .components:
            band {
                CardRow(SettingsSection.components.title, items: ComponentsSettingsTab.allCases.map(componentsCard),
                        selection: $navigation.componentsTab)
            }
        case .privacy:
            band {
                CardRow(SettingsSection.privacy.title, items: DiagnosticsSettingsTab.allCases.map(diagnosticsCard),
                        selection: $navigation.diagnosticsTab)
            }
        case .general, .audio, .voice, .glossary:
            // §2 Z1c: no cards, the same divider (it separates a ReturnPill from the Form).
            Divider()
        }
    }

    private func band<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
        }
    }

    // MARK: 字幕

    /// For every scene; the VoiceOver switch only while VoiceOver runs. Hiding it keeps the
    /// preference (`ui.announceNewTranslations`).
    private var globalRow: some View {
        GlobalRow {
            Toggle(isOn: $state.subtitlesVisible) {
                Label("显示字幕", systemImage: Icon.subtitles)
            }
            if subtitles.voiceOverRunning {
                Toggle(isOn: $state.announceNewTranslations) {
                    Label("用 VoiceOver 读出新字幕", systemImage: Icon.voiceOver)
                }
                .help("只读定稿")
                .accessibilityHint(String(localized: "用 VoiceOver 朗读每条定稿译文，不读草稿"))
            }
        }
    }

    // MARK: 模型

    private func modelCard(_ stage: ModelSettingsStage) -> CardItem<ModelSettingsStage> {
        CardItem(id: stage, title: stage.title, symbol: stage.symbol, summary: stage.summary, badge: modelBadge(stage))
    }

    private func modelBadge(_ stage: ModelSettingsStage) -> CardBadge? {
        switch stage {
        case .recognition: engine.recognitionProblem(state).map { .status($0.status, $0.text) }
        case .translation: translationBadge
        case .synthesis: engine.synthesisProblem.map { .status($0.status, $0.text) }
        }
    }

    /// The page's own facts (`TranslationFlowFacts.cardBadge`): OpenAI in use shows `network`;
    /// OpenAI chosen without a key, a failed key check or a retirement notice, a warning. Nothing
    /// until the page's model has answered whether the key item exists (a metadata query; the
    /// key is never read).
    private var translationBadge: CardBadge? {
        guard let model = translation.model else { return nil }
        let warning: String?
        if case .failed = model.verification {
            warning = String(localized: "key 未通过验证")
        } else {
            switch model.retirement {
            case .fellBackToDefault: warning = String(localized: "所选模型已下线")
            case .defaultRetiring: warning = String(localized: "模型即将下线")
            case .keep, nil: warning = nil
            }
        }
        return model.flowFacts.cardBadge(warning: warning)
    }

    // MARK: 组件

    private func componentsCard(_ tab: ComponentsSettingsTab) -> CardItem<ComponentsSettingsTab> {
        CardItem(id: tab, title: tab.title, symbol: tab.symbol, summary: tab.summary,
                 badge: tab == .engine ? engineBadge : driverBadge)
    }

    /// Install, update or repair needed: warn; a damaged record: failed. The flow and the 引擎
    /// section read the same (`EngineComponentsModel.status`).
    private var engineBadge: CardBadge? {
        engine.problem.map { .status($0.status, $0.text) }
    }

    /// Read once a page has built the driver model (its first appearance); the flow nodes
    /// read the same.
    private var driverBadge: CardBadge? {
        driver.driverProblem.map { .status($0.status, $0.text) }
    }

    // MARK: 隐私与诊断

    private func diagnosticsCard(_ tab: DiagnosticsSettingsTab) -> CardItem<DiagnosticsSettingsTab> {
        CardItem(id: tab, title: tab.title, symbol: tab.symbol, summary: tab.summary, badge: diagnosticsBadge(tab))
    }

    private func diagnosticsBadge(_ tab: DiagnosticsSettingsTab) -> CardBadge? {
        switch tab {
        case .privacy:
            return nil
        case .subtitles:
            let analysis = privacy.subtitleAnalysis
            return analysis.isRecording || analysis.isStarting
                ? .analysing(String(localized: "正在保存字幕文字")) : nil
        case .troubleshooting:
            return privacy.recorder.recordingTracks.isEmpty ? nil : .status(.recording, String(localized: "诊断录音中"))
        }
    }
}
