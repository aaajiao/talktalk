// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// The scenario page's fixed bottom bar (settings visual system §3.15): 56 pt on the bar
/// material, under a divider. Left, while a session runs: the voice dot, the scene's icon and
/// "<来源> · 12:03", which selects the running scene's card; the phone's 通话不会挂断; the hidden
/// subtitles with a way back. Right: one primary button with a short word, locked to the running
/// session while another scene is browsed. No description line and no running banner.
struct ScenarioBottomBar: View {
    @Bindable var state: AppState

    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    private var runState: ScenarioRunState {
        let phase: ScenarioRunState.Phase = state.meetingStopping ? .stopping
            : state.meetingStarting ? .starting : state.meetingActive ? .running : .idle
        return ScenarioRunState(running: state.meetingMode, phase: phase, browsing: state.requestedScenario)
    }

    var body: some View {
        let run = runState
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let source = run.runningSource(meetingApp: state.meetingApp), let running = run.running {
                    runningStatus(running, source: source)
                    if running == .phone {
                        FactChip(String(localized: "通话不会挂断"), symbol: SubtitleTokens.SceneIcon.phone,
                                 help: String(localized: "结束同传不会挂断电话"))
                    }
                }
                if !state.subtitlesVisible {
                    HStack(spacing: 4) {
                        FactChip(String(localized: "字幕已隐藏"), symbol: SubtitleTokens.SettingsIcon.subtitlesHidden,
                                 tone: .warn, help: String(localized: "所有场景的字幕窗口都已隐藏"))
                        Button("显示") { state.subtitlesVisible = true }
                            .buttonStyle(.link)
                            .font(.callout)
                            .help("显示字幕窗口")
                    }
                }
                Spacer(minLength: 12)
                primaryButton(run)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
        .background(.bar)
    }

    /// "● [scene] Zoom · 12:03": the dot in the running voice's colour (video listens only:
    /// neutral); only the clock text is in a TimelineView.
    private func runningStatus(_ running: MeetingMode, source: String) -> some View {
        let voice = runningVoice(running)
        return Button {
            state.requestedScenario = running
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: SubtitleStyle.toneColor(voice.appearance.tone)))
                    .frame(width: Ladder.runningDot, height: Ladder.runningDot)
                Image(systemName: running.sceneSymbol)
                    .font(.system(size: Ladder.inline, weight: .regular))
                    .foregroundStyle(.secondary)
                if let since = state.meetingStartedAt {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(verbatim: "\(source) · \(SessionClock.elapsed(context.date.timeIntervalSince(since)))")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                    }
                } else {
                    Text(verbatim: source).font(.callout.weight(.medium))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("回到运行中的场景")
        .accessibilityLabel(String(localized: "运行中：\(running.scene.title) · \(source)"))
        .accessibilityValue(voice.accessibilityLabel)
        .accessibilityHint(String(localized: "回到运行中的场景"))
    }

    /// The running session's voice state, as the menu's dot.
    private func runningVoice(_ running: MeetingMode) -> VoiceState {
        switch running {
        case .meeting: state.meetingVoice ?? VoiceState.resolve(audio: .original, scene: .meeting)
        case .phone: state.phoneVoice ?? VoiceState.resolve(audio: nil, scene: .phone)
        case .captions: VoiceState.resolve(audio: nil, scene: .video)
        }
    }

    private func primaryButton(_ run: ScenarioRunState) -> some View {
        let (mode, ends): (MeetingMode?, Bool) = switch run.action {
        case let .start(mode): (mode, false)
        case let .end(mode): (mode, true)
        case .progress, .blocked: (nil, false)
        }
        return Button {
            if let mode { state.onToggleListening?(mode) }
        } label: {
            HStack(spacing: 6) {
                if let symbol = run.symbol {
                    Image(systemName: symbol)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: run.title)
            }
            .font(.body.weight(.semibold))
            .frame(minWidth: 140)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(ends ? Color.red : Color.accentColor)
        .help(run.help(systemInputSwitched: state.systemInputHeld) ?? "")
        .accessibilityLabel(run.accessibilityLabel)
        .disabled(!run.isEnabled || state.onToggleListening == nil
                  || (!state.meetingActive && !state.meetingAvailable))
    }
}
