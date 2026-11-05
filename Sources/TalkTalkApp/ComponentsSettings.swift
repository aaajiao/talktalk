// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
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

    var symbol: String { self == .engine ? "cpu" : "mic" }

    var summary: String {
        switch self {
        case .engine: String(localized: "语音识别 · 语音合成")
        case .driver: String(localized: "TalkTalk Mic · 连接会议应用")
        }
    }
}

/// Component installation pages share the model page's tab navigation. Their owners survive
/// switching tabs, preserving installer progress and confirmation/blocking rules.
struct ComponentsSettingsView: View {
    @Bindable var navigation: SettingsNavigation
    let engine: EngineComponentsModel
    let driver: DriverComponentsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(ComponentsSettingsTab.allCases) { tab in
                    SettingsTabButton(title: tab.title, symbol: tab.symbol, summary: tab.summary,
                                      selected: navigation.componentsTab == tab) {
                        navigation.componentsTab = tab
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "组件分类"))
            .padding([.horizontal, .top], 20)

            Form {
                switch navigation.componentsTab {
                case .engine:
                    Section {
                        EngineComponentsRows(model: engine, refreshOnAppear: false)
                    } footer: {
                        Text("本页管理本地安装；模型选择在“模型”中设置。")
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
        .onAppear { engine.reload(); driver.load() }
    }
}
