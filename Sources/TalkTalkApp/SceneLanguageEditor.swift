// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// The live subtitle window's native popover. Its controls are also embedded directly in
/// the existing scenario flow nodes; every control receives its scene explicitly.
struct SceneLanguageEditor: View {
    @Bindable var state: AppState
    let mode: MeetingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            listenRow
            if mode.supportsSpeaking { speakRow }
        }
        .font(.callout)
    }

    private var listenRow: some View {
        HStack(spacing: 7) {
            Text(mode == .captions ? String(appLocalized: "原文") : String(appLocalized: "对方说"))
            SceneLanguageChip(state: state, mode: mode, role: .listenSource)
            arrow
            Text(String(appLocalized: "字幕"))
            SceneLanguageChip(state: state, mode: mode, role: .listenTarget)
            SceneLanguageSwapButton(state: state, mode: mode)
            Spacer(minLength: 0)
        }
    }

    private var speakRow: some View {
        HStack(spacing: 7) {
            Text(String(appLocalized: "我说"))
            SceneLanguageChip(state: state, mode: mode, role: .speakSource)
            arrow
            Text(String(appLocalized: "译音"))
            SceneLanguageChip(state: state, mode: mode, role: .speakTarget)
            Spacer(minLength: 0)
        }
    }

    private var arrow: some View {
        Image(systemName: SubtitleTokens.SettingsIcon.flowArrow)
            .font(.system(size: SubtitleTokens.SettingsIcon.Size.badge))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A native language chip for a specific role and scene. Compact chips fit beside the
/// app-source chip or keycap in the existing flow node's accessory slot.
struct SceneLanguageChip: View {
    enum Role { case listenSource, listenTarget, speakSource, speakTarget }
    @Bindable var state: AppState
    let mode: MeetingMode
    let role: Role
    /// A flow node's chip: the short code ("中", "EN", "DE"); menu items, help and VoiceOver keep
    /// the language's name.
    var compact = false

    private var current: Lang {
        switch role {
        case .listenSource: state.listenLanguages(for: mode).source
        case .listenTarget: state.listenLanguages(for: mode).target
        case .speakSource: state.speakLanguages(for: mode).source.lang
        case .speakTarget: state.speakLanguages(for: mode).target.lang
        }
    }

    private var choices: [Lang] {
        switch role {
        case .listenSource: Lang.allCases
        case .listenTarget: state.listenLanguages(for: mode).targets
        case .speakSource: SpeakSourceLanguage.allCases.map(\.lang)
        case .speakTarget: state.speakLanguages(for: mode).source.targets.map(\.lang)
        }
    }

    private var label: String {
        switch role {
        case .listenSource: mode == .captions ? String(appLocalized: "视频原文语言") : String(appLocalized: "对方语言")
        case .listenTarget: String(appLocalized: "字幕译文语言")
        case .speakSource: String(appLocalized: "我说的语言")
        case .speakTarget: String(appLocalized: "我的译音")
        }
    }

    var body: some View {
        NodeChip(compact ? current.shortCode : current.title, width: compact ? 34 : nil,
                 accessibilityLabel: label, accessibilityValue: current.title, help: String(appLocalized: "\(label)：\(current.title)"),
                 items: choices.map { language in
                     NodeChipItem(language.title, isOn: current == language) { select(language) }
                 })
    }

    private func select(_ language: Lang) {
        switch role {
        case .listenSource:
            state.setListenLanguages(state.listenLanguages(for: mode).selectingSource(language), for: mode)
        case .listenTarget:
            state.setListenLanguages(state.listenLanguages(for: mode).selectingTarget(language), for: mode)
        case .speakSource:
            if let source = SpeakSourceLanguage(rawValue: language.rawValue) { state.setSpeakSource(source, for: mode) }
        case .speakTarget:
            if let target = SpeakTargetLanguage(rawValue: language.rawValue) { state.setSpeakTarget(target, for: mode) }
        }
    }
}

struct SceneLanguageSwapButton: View {
    @Bindable var state: AppState
    let mode: MeetingMode

    var body: some View {
        IconButton(SubtitleTokens.SettingsIcon.languageSwap, help: String(appLocalized: "交换原文与译文语言")) {
            state.setListenLanguages(state.listenLanguages(for: mode).swapped, for: mode)
        }
    }
}
