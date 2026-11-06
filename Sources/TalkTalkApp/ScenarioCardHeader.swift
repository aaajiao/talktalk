// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession

/// The three scene cards pinned above Settings › 使用场景 and › 字幕 (never collapses, never scrolls).
struct ScenarioCardHeader: View {
    let selection: MeetingMode
    /// The running session's scene (meetingActive); nil otherwise.
    let running: MeetingMode?
    let startedAt: Date?
    let select: (MeetingMode) -> Void

    static let modes: [MeetingMode] = [.meeting, .phone, .captions]

    var body: some View {
        // Ticks once a second only while a card shows the elapsed time.
        TimelineView(.periodic(from: .now, by: running != nil ? 1 : 3600)) { context in
            HStack(spacing: 12) {
                ForEach(Self.modes, id: \.self) { mode in
                    let isRunning = running == mode
                    SettingsTabButton(title: mode.scene.title, symbol: mode.sceneSymbol, summary: mode.sceneSummary,
                                      selected: selection == mode, running: isRunning,
                                      runningSubtitle: isRunning ? ScenarioRunState.cardSubtitle(
                                          elapsed: startedAt.map { context.date.timeIntervalSince($0) }) : nil) {
                        select(mode)
                    }
                }
            }
        }
        .padding([.horizontal, .top], 20).padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "使用场景"))
    }
}
