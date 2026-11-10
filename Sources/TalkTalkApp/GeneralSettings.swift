// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Combine
import SwiftUI
import TalkTalkCore
import TalkTalkDriverSupport
import TalkTalkSession
import TalkTalkSettingsUI

/// UserDefaults keys of the settings pages. The cue keys keep their old `speak.passthrough.`
/// names so existing values still apply.
enum UIPrefKey {
    static let announcementEnabled = "speak.announcement.enabled" // §16 决定 6: default on
    static let micUID = "audio.micUID"                           // nil: MicPolicy's choice
    static let hotMic = "speak.hotMic"                           // §16 决定 3: default on
    static let monitor = "speak.monitor"                         // §3.4 自听: default off
    static let cuesEnabled = "speak.passthrough.cues.enabled"
    static let cueDbfs = "speak.passthrough.cues.dbfs"
    static let switchDefaultInput = "sysinput.switchDefaultInput" // §16 决定 4: default on
    static let headphoneAnswers = "audio.headphoneAnswers"       // [uid: Bool] "这是耳机吗？"
    static let headphoneNames = "audio.headphoneNames"           // [uid: name] for the list only
}

@MainActor
@Observable
final class GeneralSettingsModel {
    @ObservationIgnored private let defaults: UserDefaults
    let launch: LaunchAtLogin

    var announcementEnabled: Bool {
        didSet { defaults.set(announcementEnabled, forKey: UIPrefKey.announcementEnabled) }
    }
    private(set) var autoEndNotificationsEnabled: Bool
    private(set) var notificationAuthorization: MeetingAutoEndNotification.Authorization = .checking
    private(set) var notificationRequesting = false
    var autoEndNotificationSetting: MeetingAutoEndNotification.Setting {
        .init(enabled: autoEndNotificationsEnabled, authorization: notificationAuthorization)
    }
    /// The onboarding flow, for "第 N 步，共 M 步" on 使用引导… (set by the app delegate).
    @ObservationIgnored weak var onboarding: OnboardingFlowModel?
    /// "使用引导…" was pressed: unfinished onboarding continues at its step, finished onboarding
    /// starts again from the scenario page.
    var onOpenOnboarding: (() -> Void)?

    init(defaults: UserDefaults = .standard, launch: LaunchAtLogin = LaunchAtLogin()) {
        self.defaults = defaults
        self.launch = launch
        announcementEnabled = defaults.object(forKey: UIPrefKey.announcementEnabled) as? Bool ?? true
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

    /// The notification switch is on but macOS does not deliver yet: what its row ends with, and
    /// the page hero's words for the same fact (§7.5). Nothing while the switch is off.
    var notificationProblem: (row: SettingsProblem, page: SettingsProblem)? {
        guard autoEndNotificationsEnabled, !notificationRequesting else { return nil }
        switch notificationAuthorization {
        case .notDetermined:
            let problem = SettingsProblem(.warn, String(appLocalized: "需允许通知"), help: String(appLocalized: "允许系统通知后才会提醒"))
            return (problem, problem)
        case .denied:
            let help = String(appLocalized: "在系统设置中允许 TalkTalk 通知")
            return (SettingsProblem(.failed, String(appLocalized: "系统已拒绝"), help: help),
                    SettingsProblem(.failed, String(appLocalized: "系统已拒绝通知"), help: help))
        case .checking, .allowed, .unavailable:
            return nil
        }
    }
}

/// Settings › 通用 (settings visual system §7.5). No flow to draw, so the page opens with its
/// status tile: the most severe of the rows' facts, or 已就绪. Then 登录时启动, 会议结束通知
/// and the announcement, each with only what needs the user at its end; 使用引导… (its step
/// while unfinished) and 关于 TalkTalk with the version; and last the red 完全卸载…. No section
/// titles, footers or explanation lines: purpose and consequence are in help and VoiceOver.
struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel
    @Bindable private var languages = AppLanguageStore.shared
    let driver: DriverComponentsPage
    @Bindable var navigation: SettingsNavigation
    /// Apple speech or translation resources are missing (AppState.appleCheck, §7.5 item 6): 使用引导…
    /// runs their download again, so its row says so and the menu's problem row lands on it.
    var appleCheck: String? = nil

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section { hero }
                Section {
                    Picker(selection: $languages.selection) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.nativeName).tag(language)
                        }
                    } label: {
                        Label("界面语言", systemImage: "globe")
                    }
                    .help("立即更改界面语言，不影响语音和字幕语言")
                }
                Section {
                    LaunchAtLoginRow(launch: model.launch, stronglyRecommended: model.loginStronglyRecommended)
                    notificationRow
                    Toggle(isOn: $model.announcementEnabled) {
                        Label("首次翻译前播放告知语", systemImage: Icon.announcement)
                    }
                    .help("告诉对方你在用机器同传与合成声音")
                }
                Section {
                    onboardingRow
                        .flowFlash(SettingsAnchor.onboarding, in: navigation.flow)
                    aboutRow
                }
                .id(SettingsAnchor.onboarding)
                Section {
                    FullUninstallSection(model: driver.model, unavailable: driver.problem) {
                        navigation.open(.components, .components(.engine))
                    }
                }
            }
            .formStyle(.grouped)
            .labelStyle(.settingsRow)
            .settingsPageScroll(navigation, subpage: SettingsSection.general)
            .settingsAnchorTarget(navigation, proxy)
        }
        .onAppear { driver.load(); model.launch.refresh(); Task { await model.refreshNotifications() } }
        // 完全卸载 unregisters the login item: show it once the run ends.
        .onChange(of: driver.model?.fullUninstallRunning == true) { was, running in
            if was && !running { model.launch.refresh() }
        }
        // Approval can change in System Settings while this page remains mounted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.launch.refresh()
        }
    }

    /// The Apple resources' status on 使用引导… and in the hero.
    private var appleProblem: SettingsProblem? {
        appleCheck.map { SettingsProblem(.warn, String(appLocalized: "Apple 资源待配置"), help: $0) }
    }

    // MARK: Z2

    private var hero: some View {
        let problem = SettingsProblem.mostSevere([
            model.launch.problem(stronglyRecommended: model.loginStronglyRecommended)?.page,
            model.notificationProblem?.page,
            appleProblem,
        ])
        return PageHero(String(appLocalized: "通用"), symbol: Icon.Page.general, help: String(appLocalized: "启动、通知与应用管理")) {
            if let problem {
                StatusLabel(problem.text, problem.status, help: problem.help)
            } else {
                StatusLabel(String(appLocalized: "已就绪"), .ok)
            }
        }
    }

    // MARK: rows

    /// The switch, and only while it is on and macOS does not deliver: 需允许通知 with 允许…, or
    /// 系统已拒绝 with 系统设置…; a spinner while the permission is checked or asked for.
    private var notificationRow: some View {
        let unavailable = model.notificationAuthorization == .unavailable
        let checking = model.notificationRequesting
            || (model.autoEndNotificationsEnabled && model.notificationAuthorization == .checking)
        return LabeledContent {
            HStack(spacing: 8) {
                if checking {
                    StatusGlyph(.busy).accessibilityLabel(String(appLocalized: "检查中"))
                } else if let problem = model.notificationProblem?.row {
                    StatusLabel(problem.text, problem.status, help: problem.help)
                    if model.notificationAuthorization == .denied {
                        Button { model.openNotificationSettings() } label: {
                            Label("系统设置…", systemImage: Icon.openApp).labelStyle(.titleAndIcon)
                        }
                    } else {
                        Button { model.authorizeNotifications() } label: {
                            Label("允许…", systemImage: Icon.allowNotifications).labelStyle(.titleAndIcon)
                        }
                    }
                }
                Toggle(String(appLocalized: "会议结束通知"), isOn: Binding(
                    get: { model.autoEndNotificationsEnabled },
                    set: { model.setAutoEndNotifications($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.notificationRequesting || unavailable)
                    .accessibilityHint(String(appLocalized: "会议似乎已结束时提醒你；关闭通知不影响自动结束；电话与视频字幕同样适用"))
            }
        } label: {
            Label("会议结束通知", systemImage: Icon.notifications)
        }
        .help(unavailable ? String(appLocalized: "当前运行方式不支持通知") : String(appLocalized: "会议似乎结束时提醒你"))
    }

    /// Continues unfinished onboarding at its step (shown at the row's end) or runs it again; it
    /// ends with Apple 资源待配置 while those resources are missing (its step downloads them).
    private var onboardingRow: some View {
        let progress = model.onboarding?.progress
        return HStack(spacing: 8) {
            Button { model.onOpenOnboarding?() } label: {
                Label("使用引导…", systemImage: Icon.onboarding).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.onOpenOnboarding == nil)
            .help("保留已装模型与声音档案")
            .accessibilityValue(progress?.text ?? "")
            .accessibilityHint(String(appLocalized: "重新检查权限、组件和声音设置，保留已装模型与声音档案"))
            Spacer(minLength: 8)
            if let problem = appleProblem {
                StatusLabel(problem.text, problem.status, help: problem.help)
            }
            if let progress {
                Text(verbatim: progress.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The standard About panel; the version stays selectable for copying.
    private var aboutRow: some View {
        HStack(spacing: 8) {
            Button { NSApp.orderFrontStandardAboutPanel(nil) } label: {
                Label {
                    Text("关于 TalkTalk")
                } icon: {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: Ladder.row, height: Ladder.row)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text(verbatim: AppVersion.current.displayString)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// Settings › 通用 › 登录时启动 (§7.5): the switch, and at the row's end only what needs the
/// user: warn 建议开启 with its ⓘ, waiting 待系统允许 with 登录项…,
/// failed 未能更改. Unsigned builds disable the switch with the reason in help. The switch lives
/// only here; 音频 has a status-only row with a link to 通用 (§7.6, `recommendedProblem`).
struct LaunchAtLoginRow: View {
    let launch: LaunchAtLogin
    let stronglyRecommended: Bool

    private typealias Icon = SubtitleTokens.SettingsIcon

    var body: some View {
        let p = launch.presentation(stronglyRecommended: stronglyRecommended)
        let problem = launch.problem(stronglyRecommended: stronglyRecommended)?.row
        LabeledContent {
            HStack(spacing: 8) {
                if let problem { StatusLabel(problem.text, problem.status, help: problem.help) }
                if launch.lastError == nil, p.notice == .awaitingApproval {
                    Button { launch.openSystemSettings() } label: {
                        Label("登录项…", systemImage: Icon.openApp).labelStyle(.titleAndIcon)
                    }
                }
                if launch.lastError == nil, p.notice == .recommended {
                    InfoButton(topic: String(appLocalized: "登录时启动"), lines: [LaunchAtLoginPolicy.recommendation])
                }
                Toggle(String(appLocalized: "登录时启动"), isOn: Binding(get: { p.isOn }, set: { launch.set($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!p.canToggle)
            }
        } label: {
            Label("登录时启动", systemImage: Icon.launchAtLogin)
        }
        .help(ifPresent: p.notice == .unsigned ? String(appLocalized: "未签名构建不可用") : nil)
    }
}

extension LaunchAtLogin {
    /// What the 登录时启动 row ends with, and the page hero's words for the same fact (§7.5).
    /// nil: nothing to do (also for an unsigned build, which only disables the switch).
    func problem(stronglyRecommended: Bool) -> (row: SettingsProblem, page: SettingsProblem)? {
        if let lastError {
            return (SettingsProblem(.failed, String(appLocalized: "未能更改"), help: lastError),
                    SettingsProblem(.failed, String(appLocalized: "登录时启动未能更改"), help: lastError))
        }
        switch presentation(stronglyRecommended: stronglyRecommended).notice {
        case .recommended?:
            let help = LaunchAtLoginPolicy.recommendation
            return (SettingsProblem(.warn, String(appLocalized: "建议开启"), help: help),
                    SettingsProblem(.warn, String(appLocalized: "建议开启登录时启动"), help: help))
        case .awaitingApproval?:
            let problem = SettingsProblem(.waiting, String(appLocalized: "待系统允许"),
                                          help: String(appLocalized: "在系统设置的登录项中允许 TalkTalk"))
            return (problem, problem)
        case .unsigned?, nil:
            return nil
        }
    }

    /// 建议开启 alone, for 音频's status-only row (§7.6): the other notices and the switch are
    /// 通用's. nil unless the switch is off while it is recommended.
    func recommendedProblem(stronglyRecommended: Bool) -> SettingsProblem? {
        guard lastError == nil, presentation(stronglyRecommended: stronglyRecommended).notice == .recommended else { return nil }
        return problem(stronglyRecommended: stronglyRecommended)?.row
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
