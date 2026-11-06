// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import SwiftUI
import TalkTalkCore
import TalkTalkSession

/// Phone has its own preparation and dialing workflow; the system Phone app owns the call.
/// Opening this scene only changes the settings view, never the current audio session.
struct PhoneSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation

    private var sessionBusy: Bool {
        state.meetingActive || state.meetingStarting || state.meetingStopping
    }

    private var anotherSceneIsRunning: Bool {
        sessionBusy && state.meetingMode != .phone
    }

    private var canDial: Bool {
        state.meetingMode == .phone && state.meetingActive && state.phoneReadyToDial
            && !state.meetingStarting && !state.meetingStopping
            && !state.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.onDialPhone != nil
    }

    var body: some View {
        Section {
            Label("电话同传", systemImage: "phone.fill").font(.headline)
            Text("通过 iPhone 使用自己的号码，在 Mac 上打电话或接听来电。听对方、看双语字幕；点按右⌥把中文翻译给对方。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("通话应用", value: "Phone")
            if state.meetingMode == .phone, sessionBusy {
                phoneSpeechStatus
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("听对方").font(.subheadline.weight(.semibold))
                SpeechFlow(steps: [
                    ("phone.fill", String(localized: "电话对方说英语／德语")),
                    ("character.bubble", String(localized: "识别与翻译")),
                    ("captions.bubble", String(localized: "原文＋中文字幕"))
                ], links: [
                    1: .init(String(localized: "模型设置")) { navigation.openModel(.recognition) },
                    2: .init(String(localized: "字幕设置")) {
                        navigation.subtitlePresentation = .phone
                        navigation.selection = .subtitles
                    }
                ])
                Divider()
                Text("我说话").font(.subheadline.weight(.semibold))
                Text("默认：你的原声 → TalkTalk Mic → Phone 对方")
                    .font(.callout).foregroundStyle(.secondary)
                SpeechFlow(steps: [
                    ("mic", String(localized: "中文，可夹英语")),
                    ("character.bubble", String(localized: "关闭原声并翻译")),
                    ("phone.fill", String(localized: "对方听英语／德语"))
                ], links: [
                    0: .init(String(localized: "麦克风设置")) { navigation.selection = .audio },
                    1: .init(String(localized: "翻译设置")) { navigation.openModel(.translation) },
                    2: .init(String(localized: "声音与试听")) { navigation.selection = .voice }
                ])
                Text("说完再点按右⌥结束发言，等剩余译音播完后自动恢复原声。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }

        Section {
            if let problem = state.phoneProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if anotherSceneIsRunning {
                Text("请先结束当前同传或视频字幕，再准备电话同传。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Picker("对方语言", selection: $state.remoteLanguage) {
                ForEach(AppState.RemoteLanguage.allCases) { Text($0.title).tag($0) }
            }
            .disabled(anotherSceneIsRunning)
            Picker("我的译音", selection: $state.speakLanguage) {
                ForEach(AppState.RemoteLanguage.allCases) { Text($0.title).tag($0) }
            }
            .disabled(anotherSceneIsRunning)

            Button("打开 Phone 拨号或接听") { state.onOpenPhone?() }
                .disabled(state.onOpenPhone == nil)
            Text("点击底部“准备电话同传”后即可收音，点按右⌥就能翻译自己的发言，不必等电话接通。TalkTalk 专门收听 Phone；拨号和接听在 Phone 中完成。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField(String(localized: "电话号码（可选，含国家区号）"), text: $state.phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(String(localized: "电话号码"))
                    .disabled(anotherSceneIsRunning || state.meetingStarting || state.meetingStopping)
                Button(state.phoneDialing ? String(localized: "正在打开 Phone…") : String(localized: "拨打此号码")) { state.onDialPhone?(state.phoneNumber) }
                    .disabled(!canDial || state.phoneDialing || state.phoneAudioActive)
            }
            Text("拨号交给 Phone 完成；也可以直接在 Phone 中选择联系人或接听来电。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("通话准备")
        }

        Section {
            Label("使用 Phone 的静音与挂断按钮", systemImage: "phone.down")
            Text("在 Phone 中静音或挂断。挂断后点“结束电话同传”，TalkTalk 会结束翻译并还原麦克风；结束同传不会替你挂断电话。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("通话中与结束")
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
                Button("打开音频设置") { navigation.selection = .audio }
            }
        }
    }

    @ViewBuilder private var phoneSpeechStatus: some View {
        if state.meetingStarting || state.meetingStopping {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(state.meetingStopping
                     ? String(localized: "正在结束电话同传…")
                     : String(localized: "正在准备电话同传…"))
                    .font(.headline)
            }
            .padding(.vertical, 8)
        } else if let audio = state.phoneSpeechMode {
            let presentation = audio.phonePresentation(inputConfirmed: state.phoneInputConfirmed)
            let color = phoneModeColor(presentation.tone)
            VStack(alignment: .leading, spacing: 8) {
                Label(presentation.title, systemImage: presentation.symbol)
                    .font(.title3.weight(.semibold)).foregroundStyle(color)
                Label(presentation.action, systemImage: "option")
                    .font(.callout.weight(.semibold))
                Text(presentation.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private func phoneModeColor(_ tone: PhoneSpeechPresentation.Tone) -> Color {
        switch tone {
        case .original: .green
        case .translation: .blue
        case .ready, .progress: .secondary
        case .unavailable: .orange
        }
    }
}
