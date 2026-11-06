// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// Phone has its own preparation and dialing workflow; the system Phone app owns the call.
/// Opening this scene only changes the settings view, never the current audio session.
/// Redesign §7: a three-step checklist (prepare → dial or answer → end after hanging up).
struct PhoneSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation

    private var sessionBusy: Bool {
        state.meetingActive || state.meetingStarting || state.meetingStopping
    }

    private var anotherSceneIsRunning: Bool {
        sessionBusy && state.meetingMode != .phone
    }

    private var phoneSession: Bool { sessionBusy && state.meetingMode == .phone }

    private var checklist: PhoneChecklist {
        PhoneChecklist.make(phoneSession: phoneSession, starting: state.meetingStarting, stopping: state.meetingStopping,
                            active: state.meetingActive, readyToDial: state.phoneReadyToDial,
                            dialing: state.phoneDialing, callAudioActive: state.phoneAudioActive)
    }

    private var canDial: Bool {
        state.meetingMode == .phone && state.meetingActive && state.phoneReadyToDial
            && !state.meetingStarting && !state.meetingStopping
            && !state.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.onDialPhone != nil
    }

    var body: some View {
        Section {
            if phoneSession { phoneSpeechStatus }

            VStack(alignment: .leading, spacing: 12) {
                Text("听对方").font(.subheadline.weight(.semibold))
                SpeechFlow(steps: [
                    ("phone.fill", String(localized: "电话对方说英语／德语")),
                    ("character.bubble", String(localized: "识别与翻译")),
                    ("captions.bubble", String(localized: "原文＋中文字幕"))
                ], links: [
                    1: FlowLink(String(localized: "模型设置")) { follow { navigation.openModel(.recognition) } },
                    2: FlowLink(String(localized: "字幕设置")) { follow { navigation.selection = .subtitles } }
                ])
                Divider()
                SpeakingLanes(mode: .phone, follow: follow, navigation: navigation)
            }
        } header: {
            HStack {
                Text("工作方式")
                InfoButton(topic: String(localized: "电话同传"), lines: [
                    String(localized: "TalkTalk 专门收听 Phone；拨号、接听、静音和挂断都在 Phone 中完成。"),
                    String(localized: "准备好后即可收音，点按右⌥就能翻译自己的发言，不必等电话接通。")
                ])
            }
        }

        Section {
            if let problem = state.phoneProblem {
                StatusLabel(problem, .warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("对方语言", selection: $state.remoteLanguage) {
                ForEach(AppState.RemoteLanguage.allCases) { Text($0.title).tag($0) }
            }
            .disabled(anotherSceneIsRunning)
            Picker("我的译音", selection: $state.speakLanguage) {
                ForEach(AppState.RemoteLanguage.allCases) { Text($0.title).tag($0) }
            }
            .disabled(anotherSceneIsRunning)
        } header: {
            Text("通话语言")
        }

        Section {
            checklistRow(1, status: checklist.prepare, title: String(localized: "准备电话同传")) { prepareStep }
            checklistRow(2, status: checklist.dial, title: String(localized: "拨号或接听")) { dialStep }
            checklistRow(3, status: checklist.finish, title: String(localized: "挂断后结束同传")) {
                Text("在 Phone 中挂断后，点“结束电话同传”还原麦克风；结束同传不会挂断电话。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("通话步骤")
        }

        Section {
            DisclosureGroup("首次使用：连接 iPhone 与麦克风") {
                Text("Mac 与 iPhone 登录同一 Apple 账户，并连接同一网络。在 iPhone 的“电话”设置中允许“在其他设备上通话”，并开启这台 Mac。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("在 Phone 菜单栏的“音频 › 麦克风”中选择“使用系统设置”，让 Phone 跟随 TalkTalk 的麦克风切换。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("建议使用耳机，避免对方的声音从扬声器回到麦克风。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开音频设置") { follow { navigation.selection = .audio } }
            }
        }
    }

    private func follow(_ open: @escaping () -> Void) {
        navigation.follow(from: .phone, open)
    }

    private func checklistRow<Content: View>(_ number: Int, status: PhoneChecklist.Status, title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ChecklistStatusCircle(number: number, status: status)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "第 \(number) 步，\(title)"))
        .accessibilityValue(statusText(status))
    }

    private func statusText(_ status: PhoneChecklist.Status) -> String {
        switch status {
        case .pending: String(localized: "未完成")
        case .inProgress: String(localized: "进行中")
        case .done: String(localized: "已完成")
        }
    }

    /// ① The same action as the bottom bar's primary button.
    @ViewBuilder private var prepareStep: some View {
        switch checklist.prepare {
        case .done:
            Label("已就绪，可拨号", systemImage: "checkmark").font(.callout).foregroundStyle(.green)
        case .inProgress:
            // While ending, step ③ and the bottom-bar spinner carry the state; the last ready
            // sentence would be stale.
            if !state.meetingStopping {
                Text(state.phoneStatus ?? String(localized: "正在准备电话同传…"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .pending:
            Button {
                state.onToggleListening?(.phone)
            } label: {
                Label("准备电话同传", systemImage: MenuQuickStart.symbol)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sessionBusy || state.onToggleListening == nil || !state.meetingAvailable)
        }
    }

    /// ② Dimmed until ① is ready.
    private var dialStep: some View {
        let enabled = checklist.dialEnabled
        return VStack(alignment: .leading, spacing: 8) {
            if !enabled {
                Text("准备完成后可拨号").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                HStack {
                    TextField(String(localized: "电话号码（可选，含国家区号）"), text: $state.phoneNumber)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(String(localized: "电话号码"))
                    Button(state.phoneDialing ? String(localized: "正在打开 Phone…") : String(localized: "拨打此号码")) {
                        state.onDialPhone?(state.phoneNumber)
                    }
                    .disabled(!canDial || state.phoneDialing || state.phoneAudioActive)
                }
                Button {
                    state.onOpenPhone?()
                } label: {
                    Label("打开 Phone 接听来电", systemImage: "phone.arrow.down.left")
                }
                .disabled(state.onOpenPhone == nil)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
    }

    /// The details button shows severity by shape and colour (§7.2): the risk glyph while the
    /// other party hears the original voice, the triangle while the Phone does not receive;
    /// otherwise ⓘ, which is what the button opens. 13 pt in a 22 × 22 click area.
    @ViewBuilder private func statusGlyph(_ tone: VoiceTone) -> some View {
        Group {
            switch tone {
            case .risk: StatusGlyph(.risk)
            case .warn: StatusGlyph(.warn)
            case .original, .translate, .neutral:
                Image(systemName: SubtitleTokens.SettingsIcon.info)
                    .font(.system(size: SubtitleTokens.SettingsIcon.Size.inline, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: SubtitleTokens.SettingsIcon.Size.hitArea, height: SubtitleTokens.SettingsIcon.Size.hitArea)
        .contentShape(Rectangle())
    }

    /// The live voice capsule, the same component and vocabulary as the subtitle window (§5).
    @ViewBuilder private var phoneSpeechStatus: some View {
        if state.meetingStopping {
            // The bottom bar's spinner is the one ending indicator; the voice is already gone.
            EmptyView()
        } else if state.meetingStarting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在准备电话同传…").font(.callout)
            }
            .padding(.vertical, 8)
        } else if let voice = state.phoneVoice {
            HStack(spacing: 10) {
                VoiceCapsule(state: voice).accessibilityLabel(voice.accessibilityLabel)
                Text(voice.consequence).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    state.phoneStatusDetailsPresented.toggle()
                } label: {
                    statusGlyph(voice.appearance.tone)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "状态与提示"))
                .accessibilityValue(voice.accessibilityLabel)
                .help(String(localized: "状态与提示"))
                .popover(isPresented: $state.phoneStatusDetailsPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Text("状态与提示").font(.headline)
                            Spacer()
                            Button {
                                state.phoneStatusDetailsPresented = false
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel(String(localized: "关闭详情"))
                            .help(String(localized: "关闭详情"))
                        }
                        VoiceCapsule(state: voice)
                        Text(voice.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if [.unavailable, .phoneLocalOnly, .remoteHearsOriginal].contains(voice.kind) {
                            Button("打开音频设置") {
                                state.phoneStatusDetailsPresented = false
                                follow { navigation.selection = .audio }
                            }
                        }
                    }
                    .padding(16)
                    .frame(width: 320, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }
}
