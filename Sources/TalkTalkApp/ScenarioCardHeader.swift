// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// The three scene cards pinned above Settings › 使用场景 and › 字幕 (settings visual system
/// §3.1, §6.2): one `CardRow` on the shared `requestedScenario`. A card only chooses which
/// scene is being edited; it never starts or switches a session. The running scene's card shows
/// the dot and elapsed time; the corner warns while that scene needs something.
struct ScenarioCardHeader: View {
    @Bindable var state: AppState

    static let modes: [MeetingMode] = [.meeting, .phone, .captions]

    var body: some View {
        CardRow(String(appLocalized: "使用场景"), items: Self.modes.map(item), selection: $state.requestedScenario)
    }

    private func item(_ mode: MeetingMode) -> CardItem<MeetingMode> {
        let running = state.meetingActive && state.meetingMode == mode
        return CardItem(id: mode, title: mode.navigationTitle, symbol: mode.sceneSymbol, summary: mode.sceneSummary,
                        badge: badge(mode),
                        runningSince: running ? (state.meetingStartedAt ?? .now) : nil,
                        accessibilityTitle: mode.scene.title)
    }

    /// The page's problem line in the corner (one source with the page and the menu).
    private func badge(_ mode: MeetingMode) -> CardBadge? {
        ScenarioFacts(state: state, mode: mode).cardBadge
    }
}

/// Short labels for the fixed settings cards; full scene names remain in help and VoiceOver.
private extension MeetingMode {
    var navigationTitle: String {
        switch self {
        case .meeting: String(appLocalized: "nav.scene.meeting")
        case .phone: String(appLocalized: "nav.scene.phone")
        case .captions: String(appLocalized: "nav.scene.video")
        }
    }
}
