// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkDriverSupport

enum ComponentsSettingsTab: CaseIterable, Identifiable {
    case engine, driver
    var id: Self { self }

    var title: String {
        switch self {
        case .engine: String(localized: "引擎与模型")
        case .driver: String(localized: "虚拟麦克风")
        }
    }

    var symbol: String {
        self == .engine ? SubtitleTokens.SettingsIcon.engine : SubtitleTokens.SettingsIcon.talkTalkMic
    }

    /// The card's help and VoiceOver hint (settings visual system §3.1).
    var summary: String {
        switch self {
        case .engine: String(localized: "本地识别与合成")
        case .driver: String(localized: "把声音送进会议")
        }
    }
}

/// Component installation pages; their cards sit in the window's fixed band. The owners survive
/// switching cards, preserving installer progress and confirmation/blocking rules.
struct ComponentsSettingsView: View {
    @Bindable var navigation: SettingsNavigation
    let engine: EngineComponentsModel
    let driver: DriverComponentsPage

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch navigation.componentsTab {
                case .engine:
                    Section {
                        EngineComponentsRows(model: engine, refreshOnAppear: false)
                    } footer: {
                        Text("模型选择在“模型”中设置。")
                    }
                case .driver:
                    Section {
                        if let model = driver.model {
                            DriverComponentSection(model: model)
                        } else if let problem = driver.problem {
                            Text(problem).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ProgressView("正在检查组件…").controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .id(navigation.componentsTab)
        }
        .settingsPageScroll(navigation, subpage: navigation.componentsTab)
        .onAppear { engine.reload(); driver.load() }
    }
}
