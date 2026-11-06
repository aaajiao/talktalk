// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkAudio
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
                        badge: badge(mode, running: running),
                        runningSince: running ? (state.meetingStartedAt ?? .now) : nil)
    }

    private func badge(_ mode: MeetingMode, running: Bool) -> CardBadge? {
        let voice = mode == .phone ? state.phoneVoice : state.meetingVoice
        let risk: CardBadge? = running && voice?.appearance == .riskFill
            ? .status(.risk, String(localized: "对方能听到原声")) : nil
        switch mode {
        case .meeting, .captions:
            return .mostSevere([risk, missingSource(mode).map { .status(.warn, String(localized: "\($0) 未打开")) }])
        case .phone:
            // The short cause (as the HUD chip); the full sentence stays on the phone page.
            return .mostSevere([risk, state.phoneProblem.map { _ in .status(.warn, String(localized: "电话需要检查")) }])
        }
    }

    /// The scene's chosen app when it is not running now (no automatic switch to another source).
    private func missingSource(_ mode: MeetingMode) -> String? {
        let id = mode == .meeting ? state.meetingSourceID : state.videoSourceID
        guard !id.isEmpty, !state.availableSources.contains(where: { $0.id == id }) else { return nil }
        return MeetingApp.named(id)?.name ?? id
    }
}
