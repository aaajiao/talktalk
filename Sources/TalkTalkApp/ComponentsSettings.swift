// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkDriverSupport
import TalkTalkSettingsUI

enum ComponentsSettingsTab: CaseIterable, Identifiable {
    case engine, driver
    var id: Self { self }

    var title: String {
        switch self {
        case .engine: String(appLocalized: "语音资源")
        case .driver: "TalkTalk Mic"
        }
    }

    /// Compact card text. The full title and purpose remain available to accessibility.
    var navigationTitle: String {
        switch self {
        case .engine: String(appLocalized: "nav.components.resources")
        case .driver: title
        }
    }

    var symbol: String {
        self == .engine ? SubtitleTokens.SettingsIcon.engine : SubtitleTokens.SettingsIcon.talkTalkMic
    }

    /// The card's help and VoiceOver hint (settings visual system §3.1).
    var summary: String {
        switch self {
        case .engine: String(appLocalized: "本地引擎与识别、合成模型")
        case .driver: String(appLocalized: "把声音送进会议")
        }
    }
}

/// Settings › 安装与维护 (settings visual system §7.11, §7.12); the cards sit in the window's fixed
/// band. Each sub-page opens with its flow, whose nodes scroll to the section below (its header
/// carries the node's glyph and flashes once); no footers or explanation lines. The owners
/// survive switching cards, preserving installer progress and confirmation and blocking rules.
struct ComponentsSettingsView: View {
    @Bindable var navigation: SettingsNavigation
    let engine: EngineComponentsModel
    let driver: DriverComponentsPage

    private typealias Icon = SubtitleTokens.SettingsIcon

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Group {
                    switch navigation.componentsTab {
                    case .engine: enginePage(proxy)
                    case .driver: driverPage(proxy)
                    }
                }
                .id(navigation.componentsTab)
                // A menu problem row (组件未就绪) lands on 引擎 and flashes it (§8.1).
                .settingsAnchorTarget(navigation, proxy)
            }
        }
        .settingsPageScroll(navigation, subpage: navigation.componentsTab)
        .onAppear { engine.reload(); driver.load() }
    }

    /// A node's in-page link (§6.3): scroll to its section and flash the header once.
    private func jump(_ anchor: String, _ proxy: ScrollViewProxy) {
        proxy.scrollTo(anchor, anchor: .top)
        navigation.flow.flash(anchor)
    }

    // MARK: 语音资源

    @ViewBuilder private func enginePage(_ proxy: ScrollViewProxy) -> some View {
        if engine.installer == nil {
            EngineUnavailableView()
        } else {
            Form {
                Section {
                    FlowGrid.engine(engine, link: NodeLink(String(appLocalized: "引擎")) { jump(SettingsAnchor.engine, proxy) })
                        .padding(.vertical, 4)
                }
                Section {
                    EngineControlRows(model: engine)
                } header: {
                    SectionHeader(String(appLocalized: "引擎"), symbol: Icon.engine)
                        .flowFlash(SettingsAnchor.engine, in: navigation.flow)
                }
                .id(SettingsAnchor.engine)
                Section {
                    EngineModelRows(model: engine)
                } header: {
                    SectionHeader(String(appLocalized: "模型"), symbol: Icon.Page.models)
                }
            }
            .formStyle(.grouped)
            .labelStyle(.settingsRow)
        }
    }

    // MARK: TalkTalk Mic

    @ViewBuilder private func driverPage(_ proxy: ScrollViewProxy) -> some View {
        if let model = driver.model {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        FlowGrid.driver(model, talkTalkMic: NodeLink(String(appLocalized: "驱动")) { jump(SettingsAnchor.driver, proxy) })
                        FactRow([FactChip(String(appLocalized: "需管理员授权"), symbol: Icon.locked,
                                          help: String(appLocalized: "安装、更新和卸载时输入密码"))],
                                info: InfoButton(topic: "TalkTalk Mic", lines: [
                                    String(appLocalized: "TalkTalk Mic 仅在 TalkTalk 运行时出现；安装或维护时系统声音会短暂中断。")
                                ]))
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    DriverComponentRows(model: model)
                } header: {
                    SectionHeader(String(appLocalized: "驱动"), symbol: Icon.talkTalkMic)
                        .flowFlash(SettingsAnchor.driver, in: navigation.flow)
                }
                .id(SettingsAnchor.driver)
            }
            .formStyle(.grouped)
            .labelStyle(.settingsRow)
            .driverComponentLifecycle(model, host: .settings)
        } else if let problem = driver.problem {
            // A binary without a bundle id, or the smoke run (§5.2, §7.12): the reason is the help.
            ContentUnavailableView(String(appLocalized: "此构建不可用"), systemImage: Icon.unavailable)
                .help(problem)
        } else {
            // §7.11: the busy glyph, not a sentence.
            StatusGlyph(.busy)
                .help(String(appLocalized: "正在读取组件"))
                .accessibilityLabel(String(appLocalized: "正在读取组件"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
