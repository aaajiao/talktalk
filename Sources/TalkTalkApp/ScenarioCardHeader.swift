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
        CardRow(String(localized: "使用场景"), items: Self.modes.map(item), selection: $state.requestedScenario)
    }

    private func item(_ mode: MeetingMode) -> CardItem<MeetingMode> {
        let running = state.meetingActive && state.meetingMode == mode
        return CardItem(id: mode, title: mode.scene.title, symbol: mode.sceneSymbol, summary: mode.sceneSummary,
                        badge: badge(mode),
                        runningSince: running ? (state.meetingStartedAt ?? .now) : nil)
    }

    /// The page's problem line in the corner (one source with the page and the menu).
    private func badge(_ mode: MeetingMode) -> CardBadge? {
        ScenarioFacts(state: state, mode: mode).cardBadge
    }
}
