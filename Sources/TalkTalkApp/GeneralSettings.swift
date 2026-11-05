// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore
import TalkTalkDriverSupport
import TalkTalkSession

/// UserDefaults keys of the settings pages. The old passthrough key/switch/cue preferences
/// remain readable for compatibility, but are no longer user-facing meeting controls.
enum UIPrefKey {
    static let announcementEnabled = "speak.announcement.enabled" // §16 决定 6: default on
    static let passthroughEnabled = "speak.passthrough.enabled"
    static let passthroughKey = "speak.passthrough.key"          // PassthroughKeyChoice raw value
    static let micUID = "audio.micUID"                           // nil: MicPolicy's choice
    static let hotMic = "speak.hotMic"                           // §16 决定 3: default on
    static let monitor = "speak.monitor"                         // §3.4 自听: default off
    static let cuesEnabled = "speak.passthrough.cues.enabled"
    static let cueDbfs = "speak.passthrough.cues.dbfs"
    static let switchDefaultInput = "sysinput.switchDefaultInput" // §16 决定 4: default on
    static let headphoneAnswers = "audio.headphoneAnswers"       // [uid: Bool] "这是耳机吗？"
    static let headphoneNames = "audio.headphoneNames"           // [uid: name] for the list only
}

/// Legacy preference decoding only; normal meetings now use default original audio and right ⌥.
enum PassthroughKeyChoice: String, CaseIterable, Identifiable {
    case rightCommand, rightControl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rightCommand: String(localized: "右⌘")
        case .rightControl: String(localized: "右⌃（外接键盘）")
        }
    }
}

@MainActor
@Observable
final class GeneralSettingsModel {
    @ObservationIgnored private let defaults: UserDefaults
    let launch: LaunchAtLogin

    var announcementEnabled: Bool {
        didSet { defaults.set(announcementEnabled, forKey: UIPrefKey.announcementEnabled) }
    }
    var passthroughEnabled: Bool {
        didSet { defaults.set(passthroughEnabled, forKey: UIPrefKey.passthroughEnabled) }
    }
    var passthroughKey: PassthroughKeyChoice {
        didSet { defaults.set(passthroughKey.rawValue, forKey: UIPrefKey.passthroughKey) }
    }
    private(set) var autoEndNotificationsEnabled: Bool
    private(set) var notificationAuthorization: MeetingAutoEndNotification.Authorization = .checking
    private(set) var notificationRequesting = false
    var autoEndNotificationSetting: MeetingAutoEndNotification.Setting {
        .init(enabled: autoEndNotificationsEnabled, authorization: notificationAuthorization)
    }
    var notificationPermissionText: String {
        switch notificationAuthorization {
        case .checking: String(localized: "正在检查系统通知权限…")
        case .allowed: String(localized: "系统通知权限：已允许")
        case .notDetermined: String(localized: "通知尚未生效：需要允许系统通知。")
        case .denied: String(localized: "通知尚未生效：系统已拒绝，请在系统设置中允许 TalkTalk。")
        case .unavailable: String(localized: "当前运行方式不支持系统通知。")
        }
    }
    /// "重新运行引导" was pressed: the app shows onboarding from step 1.
    var onRestartOnboarding: (() -> Void)?

    init(defaults: UserDefaults = .standard, launch: LaunchAtLogin = LaunchAtLogin()) {
        self.defaults = defaults
        self.launch = launch
        announcementEnabled = defaults.object(forKey: UIPrefKey.announcementEnabled) as? Bool ?? true
        passthroughEnabled = defaults.object(forKey: UIPrefKey.passthroughEnabled) as? Bool ?? true
        passthroughKey = PassthroughKeyChoice(rawValue: defaults.string(forKey: UIPrefKey.passthroughKey) ?? "") ?? .rightCommand
        autoEndNotificationsEnabled = MeetingAutoEndNotification.isEnabled(defaults: defaults)
    }

    func refreshNotifications() async {
        notificationAuthorization = await MeetingAutoEndNotification.authorization()
        autoEndNotificationsEnabled = MeetingAutoEndNotification.isEnabled(defaults: defaults)
    }

    /// The ordinary app switch is independent of OS permission and never opens a system prompt.
    func setAutoEndNotifications(_ enabled: Bool) {
        guard !notificationRequesting else { return }
        saveNotificationPreference(enabled)
    }

    /// Only the explicit permission button reaches this branch.
    func authorizeNotifications() {
        guard !notificationRequesting else { return }
        notificationRequesting = true
        Task {
            defer { notificationRequesting = false }
            await refreshNotifications()
            switch autoEndNotificationSetting.action(enabling: true) {
            case .enable: break
            case .requestAuthorization:
                _ = await MeetingAutoEndNotification.requestAuthorization()
                await refreshNotifications()
            case .openSystemSettings: openNotificationSettings()
            case .disable, .none: break
            }
        }
    }

    private func saveNotificationPreference(_ enabled: Bool) {
        autoEndNotificationsEnabled = enabled
        MeetingAutoEndNotification.setEnabled(enabled, defaults: defaults)
        if !enabled { MeetingAutoEndNotification.clear() }
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    /// §8.6: with the driver layer not counting, launch at login is strongly recommended while
    /// the default-input switch is on.
    var loginStronglyRecommended: Bool {
        let switchOn = defaults.object(forKey: UIPrefKey.switchDefaultInput) as? Bool ?? true
        return switchOn && SystemInputPlan.Config.default.loginStartStronglyRecommended
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel
    let driver: DriverComponentsPage

    var body: some View {
        let appVersion = AppVersion.current
        Form {
            Section {
                LaunchAtLoginRow(launch: model.launch, stronglyRecommended: model.loginStronglyRecommended)
            } header: { Label("启动", systemImage: "power") }
            Section {
                SpeechFlow(steps: [
                    ("mic", String(localized: "默认原声")),
                    ("option", String(localized: "点按右⌥开始翻译")),
                    ("speaker.wave.2", String(localized: "再点按结束发言"))
                ])
                SettingsNote("点按一次右⌥开始翻译，原声随即关闭；说中文，可夹英语。再点按结束发言，等剩余译音播完后自动恢复原声。")
                Label("需要静音时，请使用会议应用的静音按钮。", systemImage: "mic.slash")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Label("会议发言方式", systemImage: "mic.and.signal.meter") }
            Section {
                Toggle(isOn: Binding(
                    get: { model.autoEndNotificationsEnabled },
                    set: { model.setAutoEndNotifications($0) })) {
                    Label("会议自动结束通知", systemImage: "bell")
                }
                .disabled(model.notificationRequesting)
                notificationStatus
                if model.notificationAuthorization == .notDetermined {
                    Button { model.authorizeNotifications() } label: {
                        Label("允许系统通知…", systemImage: "bell.badge")
                    }
                    .disabled(model.notificationRequesting)
                }
                if model.notificationAuthorization == .denied {
                    Button { model.openNotificationSettings() } label: {
                        Label("打开系统通知设置…", systemImage: "gearshape")
                    }
                }
                SettingsNote("关闭通知不会改变自动结束会议的规则；视频字幕同样适用。")
            } header: { Label("通知", systemImage: "bell")
            } footer: {
                Text("提醒你会议似乎已结束。")
            }
            Section {
                Toggle(isOn: $model.announcementEnabled) {
                    Label("第一次按键翻译时播放告知语", systemImage: "megaphone")
                }
                SettingsNote("向对方说明你正在使用机器同传和合成声音。")
                SettingsNote("也可以从菜单选择“现在播放告知语”。")
            } header: { Label("告知对方", systemImage: "megaphone") }
            Section {
                Button { model.onRestartOnboarding?() } label: {
                    Label("重新运行引导…", systemImage: "arrow.clockwise.circle")
                }
                .disabled(model.onRestartOnboarding == nil)
            } header: { Label("首次引导", systemImage: "list.number")
            } footer: {
                Text("重新检查权限、组件和声音设置，保留已安装的模型与声音档案。")
            }
            Section {
                LabeledContent("版本") {
                    Text(verbatim: appVersion.displayString).textSelection(.enabled)
                }
                Button { NSApp.orderFrontStandardAboutPanel(nil) } label: {
                    Label("关于 \(appVersion.name)…", systemImage: "info.circle")
                }
            } header: { Label("关于", systemImage: "info.circle") }
            Section {
                if let component = driver.model {
                    FullUninstallSection(model: component)
                } else if let problem = driver.problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView("正在检查组件…").controlSize(.small)
                }
            } header: { Label("应用管理", systemImage: "app.badge") }
        }
        .formStyle(.grouped)
        .onAppear { driver.load(); model.launch.refresh(); Task { await model.refreshNotifications() } }
    }

    @ViewBuilder private var notificationStatus: some View {
        if model.notificationRequesting {
            HStack {
                ProgressView().controlSize(.small)
                Text("正在检查系统通知授权…").font(.callout).foregroundStyle(.secondary)
            }
        } else if model.autoEndNotificationSetting.isEffective {
            Label("已开启，系统通知已允许", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        } else if !model.autoEndNotificationsEnabled {
            Label("已关闭，不发送会议结束通知", systemImage: "bell.slash")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.notificationPermissionText).font(.caption).foregroundStyle(.secondary)
        } else {
            Label(model.notificationPermissionText,
                  systemImage: model.notificationAuthorization == .checking ? "hourglass" : "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(model.notificationAuthorization == .notDetermined || model.notificationAuthorization == .denied
                    ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LaunchAtLoginRow: View {
    let launch: LaunchAtLogin
    let stronglyRecommended: Bool

    var body: some View {
        let p = launch.presentation(stronglyRecommended: stronglyRecommended)
        VStack(alignment: .leading, spacing: 6) {
            Toggle("登录时启动 TalkTalk", isOn: Binding(get: { p.isOn }, set: { launch.set($0) }))
                .disabled(!p.canToggle)
            if let note = p.note {
                Text(note).font(.callout)
                    .foregroundStyle(p.stronglyRecommended ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if p.offerSystemSettings {
                Button("打开登录项设置") { launch.openSystemSettings() }
            }
            if let e = launch.lastError {
                Text(e).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Gray explanatory text under a control. The text is a localization key.
struct SettingsNote: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }
    var body: some View {
        Text(key).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The models behind Settings › 通用 / 音频 / 组件, shared with onboarding (one LaunchAtLogin,
/// one EngineComponentsModel), created on first use like `PrivacySettings.shared`.
@MainActor
final class AppUIModels {
    static let shared = AppUIModels()
    let launch = LaunchAtLogin()
    let engine = EngineComponentsModel()
    lazy var general = GeneralSettingsModel(launch: launch)
    lazy var audio = AudioSettingsModel(launch: launch)
}
