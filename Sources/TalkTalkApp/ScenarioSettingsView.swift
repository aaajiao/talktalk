// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// Settings › 使用场景 (settings visual system §7.1–§7.3). The scene cards sit in the window's
/// fixed band (ScenarioCardHeader); switching cards scrolls back to the top. Each scene opens
/// with its flow diagram, including language chips in the relevant nodes, then the problem
/// line and safety facts; the bottom bar stays locked
/// to the running session while another scene is browsed (§33), and the running card's dot and
/// clock say which one runs (no banner).
struct MeetingSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    let driver: DriverComponentsPage

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Form {
                    switch state.requestedScenario {
                    case .meeting:
                        meetingScenario
                    case .phone:
                        PhoneSettingsView(state: state, navigation: navigation, driver: driver, links: links) { id in
                            proxy.scrollTo(id, anchor: .top)
                            navigation.flow.flash(id)
                        }
                    case .captions:
                        videoScenario
                    }
                }
                .formStyle(.grouped)
                .labelStyle(.settingsRow)
                .id(state.requestedScenario)
                // Back from a flow link's page: the previous position; otherwise the top.
                .settingsPageScroll(navigation, subpage: state.requestedScenario)
            }
            ScenarioBottomBar(state: state)
        }
        .onAppear {
            state.onRefreshSources?()
            AppUIModels.shared.audio.reload()
            driver.load()
        }
        // The app opened or the microphone plugged in while this page stays mounted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.onRefreshSources?()
            AppUIModels.shared.audio.reload()
        }
        // A visit of the phone scene ends: 首次连接 takes its default afresh next time.
        .onDisappear { navigation.phoneSetupDefault = nil }
        .onChange(of: state.requestedScenario) { _, _ in
            navigation.phoneSetupDefault = nil
            state.onRefreshSources?()
        }
    }

    /// A flow link: ReturnPill on the target page leads back to this scene and position.
    private var links: ScenarioLinks {
        ScenarioLinks(flash: navigation.flow) { section, subpage, anchor in
            navigation.open(section, subpage, scenario: state.requestedScenario, anchor: anchor)
        }
    }

    // MARK: scenes

    private var meetingScenario: some View {
        let facts = ScenarioFacts(state: state, mode: .meeting)
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                FlowGrid.meeting(facts, driver: driver, links: links)
                problemLine(facts)
                if facts.browserSource { FactRow([browserTabs]) }
            }
            .padding(.vertical, 4)
        }
    }

    private var videoScenario: some View {
        let facts = ScenarioFacts(state: state, mode: .captions)
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                FlowGrid.video(facts, links: links)
                problemLine(facts)
                FactRow([FactChip(String(appLocalized: "不用麦克风"), symbol: SubtitleTokens.SettingsIcon.noMicrophone,
                                  help: String(appLocalized: "不启用按键说话，不改默认麦克风"))]
                        + (facts.browserSource ? [browserTabs] : []))
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func problemLine(_ facts: ScenarioFacts) -> some View {
        if let problem = facts.problem {
            StatusLabel(problem.text, problem.status, help: problem.help)
        }
    }

    /// A browser source is one audio helper for all its tabs (§5.4).
    private var browserTabs: FactChip {
        FactChip(String(appLocalized: "含其他标签页"), symbol: SubtitleTokens.SettingsIcon.browserTabs,
                 help: String(appLocalized: "浏览器的其他标签页也会被收听"))
    }
}

extension MeetingMode {
    /// The subtitle settings tab of this scenario.
    var subtitlePresentation: SubtitlePanel.Presentation {
        switch self {
        case .meeting: .meeting
        case .phone: .phone
        case .captions: .video
        }
    }
}
