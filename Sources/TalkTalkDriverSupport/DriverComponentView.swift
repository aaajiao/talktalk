// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSettingsUI

// Settings › 组件 › 虚拟麦克风 (settings visual system §7.12; ARCHITECTURE.md §11): the driver's
// flow (`FlowGrid.driver`, shared with onboarding step 3) and its 驱动 section rows. The model
// holds every state; the views hold none.

private typealias Icon = SubtitleTokens.SettingsIcon
private typealias Ladder = SubtitleTokens.SettingsIcon.Size

extension DriverComponentModel {
    /// TalkTalk Mic's state in the settings vocabulary (§7.12): one source for the flow node's
    /// badge, the 虚拟麦克风 card and the section's status row. The full sentence is the help.
    public var status: SettingsProblem {
        switch state {
        case .loaded(let version):
            SettingsProblem(.ok, String(appLocalized: "已安装 \(version)"))
        case .notInstalled:
            carriesDriver ? SettingsProblem(.pending, String(appLocalized: "未安装"))
                : SettingsProblem(.pending, String(appLocalized: "此版本未带驱动"), help: statusText)
        case .onDiskNotLoaded:
            SettingsProblem(.warn, String(appLocalized: "需重启音频服务"), help: statusText)
        case let .outdated(installed, bundled):
            SettingsProblem(.warn, String(appLocalized: "可更新 \(installed) → \(bundled)"), help: statusText)
        case .damaged(let reason):
            SettingsProblem(.failed, String(appLocalized: "有问题"), help: reason)
        case .selfTestFailed:
            SettingsProblem(.warn, String(appLocalized: "自检未通过"), help: statusText)
        }
    }

    /// An install, uninstall or audio restart's outcome in its shortest words (§7.12). After an
    /// uninstall the meeting apps fall back to the physical microphone: that is the risk line.
    static func result(_ phase: DriverInstaller.Phase) -> SettingsProblem? {
        switch phase {
        case .finished(.installed(let version)): SettingsProblem(.ok, String(appLocalized: "已安装 \(version)"))
        case .finished(.uninstalled): SettingsProblem(.risk, String(appLocalized: "已卸载 · 会议改用实体麦（对方听到原声）"))
        case .finished(.restarted): SettingsProblem(.ok, String(appLocalized: "音频服务已重启"))
        case .finished(.needsLogout): SettingsProblem(.warn, String(appLocalized: "需注销或重启 Mac 后生效"))
        case .blocked(let pre): SettingsProblem(.warn, sentence: pre.blockers.map(\.text).joined(separator: "\n"))
        case .failed(let message): SettingsProblem(.failed, String(appLocalized: "未成功"), help: message)
        case .cancelled: SettingsProblem(.pending, String(appLocalized: "已取消"))
        case .idle, .staging, .waitingForAuthorization, .waitingForDevices: nil
        }
    }
}

/// 我 → 麦克风 (原声 · 译音) → TalkTalk Mic → 会议应用 (§7.12), one lane at the scene pages'
/// columns. TalkTalk Mic's badge is the driver's state (ok with its version); `talkTalkMic`
/// leads to the 驱动 section. 会议应用 shows up to three of the apps reading TalkTalk Mic now.
/// `model` nil: the driver has not been read yet.
@MainActor
extension FlowGrid {
    public static func driver(_ model: DriverComponentModel?, talkTalkMic link: NodeLink? = nil) -> FlowGrid {
        let original = VoiceState.resolve(audio: .original, scene: .meeting, phoneInputConfirmed: true)
        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
        let voices = [original.title, translating.title].joined(separator: String(appLocalized: "、"))
        let status = model?.status
        let users = model?.users ?? []
        let microphone = FlowNode(String(appLocalized: "麦克风"), glyph: .symbol(Icon.physicalMic), accessory: .display {
            HStack(spacing: 4) {
                VoiceCapsule(state: original)
                VoiceCapsule(state: translating)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: voices))
        }, help: String(appLocalized: "TalkTalk 用实体麦收音"))
        let device = FlowNode("TalkTalk Mic", glyph: .symbol(Icon.talkTalkMic), badge: status?.status,
                              badgeReason: status?.text, link: link, help: status?.help)
        let apps = FlowNode(String(appLocalized: "会议应用"), glyph: .symbol(Icon.meetingApps),
                            accessory: .display { DriverUsersView(users: users) },
                            help: String(appLocalized: "在会议应用里选 TalkTalk Mic"))
        return FlowGrid(String(appLocalized: "虚拟麦克风声音路径"), lanes: [
            FlowLane(String(appLocalized: "我"), gutter: .symbol(Icon.me),
                     cells: [.node(microphone), .node(device), .node(apps), .empty])
        ])
    }
}

/// The apps reading TalkTalk Mic: up to three real icons at 13 pt and "+N", "—" when none.
/// Their names are the tooltip; VoiceOver reads "使用中：A、B".
private struct DriverUsersView: View {
    let users: [DriverUser]

    var body: some View {
        let names = users.map(\.name).joined(separator: String(appLocalized: "、"))
        HStack(spacing: 3) {
            if users.isEmpty {
                Text(verbatim: "—").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(users.prefix(3), id: \.self) { user in icon(user) }
                if users.count > 3 {
                    Text(verbatim: "+\(users.count - 3)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .help(users.isEmpty ? String(appLocalized: "没有应用在用") : names)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: users.isEmpty ? String(appLocalized: "没有应用在用")
                                                          : String(appLocalized: "使用中：\(names)")))
    }

    @ViewBuilder private func icon(_ user: DriverUser) -> some View {
        if let id = user.bundleID, let image = AppIcon.image(id) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: Ladder.inline, height: Ladder.inline)
        } else {
            Image(systemName: Icon.unknownApp).font(.system(size: Ladder.inline)).foregroundStyle(.secondary)
        }
    }
}

/// The 驱动 section's rows (§7.12): the state with its one primary action (install, update,
/// reinstall or restart the audio service, each behind the administrator's password), progress,
/// 自检 with the maintenance menu, the last outcome and the self-test 详情. Several rows: put them
/// in a Form Section (or a VStack) and attach `driverComponentLifecycle` once to the container.
public struct DriverComponentRows: View {
    @Bindable var model: DriverComponentModel

    public init(model: DriverComponentModel) { self.model = model }

    public var body: some View {
        statusRow
        progressRow
        selfTestRow
        resultRow
        detailsRow
    }

    // MARK: state and the primary action

    private var statusRow: some View {
        let status = model.status
        return HStack(spacing: 8) {
            StatusLabel(status.text, status.status, help: status.help)
            Spacer(minLength: 8)
            primaryButton
        }
        .padding(.leading, Ladder.rowTextInset)
    }

    @ViewBuilder private var primaryButton: some View {
        let busy = model.isBusy
        switch model.state {
        case .notInstalled:
            adminButton(String(appLocalized: "安装")) { model.requestInstall() }.disabled(busy || !model.carriesDriver)
        case .outdated:
            adminButton(String(appLocalized: "更新")) { model.requestInstall() }.disabled(busy)
        case .damaged:
            adminButton(String(appLocalized: "重新安装")) { model.requestInstall() }.disabled(busy || !model.carriesDriver)
        case .onDiskNotLoaded:
            adminButton(String(appLocalized: "重启音频服务")) { model.requestRestartAudio() }.disabled(busy)
        case .loaded, .selfTestFailed:
            EmptyView()
        }
    }

    /// Every driver change asks for the administrator's password: `lock.fill` 9 pt in the button.
    private func adminButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(verbatim: title)
                Image(systemName: Icon.locked).font(.system(size: Ladder.micro, weight: .semibold))
            }
        }
        .buttonStyle(.borderedProminent)
        .help(String(appLocalized: "需管理员授权"))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(String(appLocalized: "需管理员授权")))
    }

    // MARK: progress

    @ViewBuilder private var progressRow: some View {
        switch model.installer.phase {
        case .staging:
            progress(String(appLocalized: "校验驱动…"))
        case .waitingForAuthorization:
            progress(String(appLocalized: "等待授权…"), symbol: Icon.locked)
        case .waitingForDevices(let attempt):
            progress(String(appLocalized: "音频服务重启中 \(attempt)/30"), symbol: Icon.audioRestart)
        default:
            if model.selfTestRunning { progress(String(appLocalized: "自检中 ~20 秒")) }
        }
    }

    private func progress(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            StatusGlyph(.busy)
            if let symbol {
                Image(systemName: symbol).font(.system(size: Ladder.inline)).foregroundStyle(.secondary)
            }
            Text(verbatim: text).foregroundStyle(.secondary)
        }
        .padding(.leading, Ladder.rowTextInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }

    // MARK: 自检 and 维护

    private var selfTestRow: some View {
        let busy = model.isBusy
        let canTest = model.state.isUsable || model.state.isLoadedButOutdated
        return HStack(spacing: 8) {
            Button { Task { await model.runSelfTest() } } label: {
                // A disabled plain button dims its label itself.
                Label("自检", systemImage: Icon.verify).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy || !canTest)
            .help(canTest ? String(appLocalized: "约 20 秒，不向会议送声") : String(appLocalized: "先安装 TalkTalk Mic"))
            Spacer(minLength: 8)
            IconMenuButton(help: String(appLocalized: "维护"), items: maintenance)
                .disabled(busy)
        }
    }

    private var maintenance: [IconMenuItem] {
        var items = [IconMenuItem(String(appLocalized: "刷新"), symbol: Icon.refresh) { model.refresh() }]
        if model.state.isUsable {
            items.append(IconMenuItem(String(appLocalized: "重新安装"), symbol: Icon.download,
                                      isEnabled: model.carriesDriver) { model.requestInstall() })
        }
        if model.state != .notInstalled {
            items.append(.separator)
            items.append(IconMenuItem(String(appLocalized: "卸载 TalkTalk Mic…"), symbol: Icon.delete,
                                      isDestructive: true) { model.requestUninstall() })
        }
        return items
    }

    // MARK: outcome and 详情

    @ViewBuilder private var resultRow: some View {
        if let result = model.result {
            HStack(spacing: 8) {
                StatusLabel(result.text, result.status, help: result.help ?? model.notice)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                IconButton(Icon.close, help: String(appLocalized: "知道了"),
                           accessibilityLabel: String(appLocalized: "关闭结果")) { model.dismissNotice() }
            }
            .padding(.leading, Ladder.rowTextInset)
        }
    }

    /// This run's self-test check by check, then the last stored result with its date (data,
    /// not explanations: §2).
    @ViewBuilder private var detailsRow: some View {
        let stored = model.record?.selfTest
        if model.selfTest != nil || stored != nil {
            DisclosureGroup {
                if let report = model.selfTest {
                    ForEach(report.checks, id: \.name) { check in
                        let status: SettingsStatus = check.passed.map { $0 ? .ok : .failed } ?? .pending
                        let word = check.passed.map { $0 ? String(appLocalized: "通过") : String(appLocalized: "没通过") }
                            ?? String(appLocalized: "跳过")
                        let title = check.name.title
                        HStack(spacing: 6) {
                            StatusGlyph(status)
                            Text(verbatim: title)
                        }
                        .padding(.leading, Ladder.rowTextInset)
                        .help(check.detail.isEmpty ? word : "\(word) · \(check.detail)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(String(appLocalized: "\(title)，\(word)")))
                    }
                }
                if let stored {
                    let word = stored.passed ? String(appLocalized: "通过") : String(appLocalized: "没通过")
                    let date = stored.at.formatted(date: .abbreviated, time: .shortened)
                    HStack(spacing: 6) {
                        StatusGlyph(stored.passed ? .ok : .failed)
                        Text(verbatim: date).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.leading, Ladder.rowTextInset)
                    .help(stored.failed.isEmpty ? word : DriverSelfTestReport.Check.Name.shortTitles(stored.failed))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(String(appLocalized: "上次自检\(word)，\(date)")))
                }
            } label: {
                Label("详情", systemImage: Icon.results)
            }
        }
    }
}

extension View {
    /// The driver section's refresh on appear and its confirmations (texts as they were: what the
    /// administrator's password and the audio restart cost). Attach it once, to the Form or the
    /// VStack that holds `DriverComponentRows`.
    public func driverComponentLifecycle(_ model: DriverComponentModel) -> some View {
        modifier(DriverComponentLifecycle(model: model))
    }
}

private struct DriverComponentLifecycle: ViewModifier {
    @Bindable var model: DriverComponentModel

    func body(content: Content) -> some View {
        content
            .onAppear { model.refresh() }
            .alert(item: $model.confirmation) { alert($0) }
    }

    private func alert(_ c: DriverComponentModel.Confirmation) -> Alert {
        func warn(_ w: [DriverPreflight.Warning]) -> String { w.map(\.text).joined(separator: "\n") }
        switch c {
        case .install(let w, let update):
            return Alert(title: Text(update ? String(appLocalized: "重新安装虚拟麦克风？") : String(appLocalized: "安装虚拟麦克风？")),
                         message: Text([String(appLocalized: "要输入一次管理员密码，系统音频会重启（声音中断约 1 秒）。"), warn(w)]
                             .filter { !$0.isEmpty }.joined(separator: "\n\n")),
                         primaryButton: .default(Text(update ? String(appLocalized: "重新安装") : String(appLocalized: "安装"))) { Task { await model.confirm(c) } },
                         secondaryButton: .cancel(Text("取消")))
        case .uninstall(let w):
            return Alert(title: Text("卸载 TalkTalk Mic？"),
                         message: Text([String(appLocalized: "卸载后，会议 App 会切回实体麦克风。"), warn(w)].filter { !$0.isEmpty }
                             .joined(separator: "\n\n")),
                         primaryButton: .default(Text("卸载 TalkTalk Mic")) { Task { await model.confirm(c) } },
                         secondaryButton: .cancel(Text("取消")))
        case .restartAudio(let w):
            return Alert(title: Text("重启音频服务？"),
                         message: Text([String(appLocalized: "要输入一次管理员密码。"), warn(w)].filter { !$0.isEmpty }
                             .joined(separator: "\n\n")),
                         primaryButton: .default(Text("重启")) { Task { await model.confirm(c) } },
                         secondaryButton: .cancel(Text("取消")))
        case .fullUninstall:
            return Alert(title: Text("完全卸载 TalkTalk？"),
                         message: Text(FullUninstallSection.explanation),
                         primaryButton: .default(Text("卸载并删除本机数据")) { Task { await model.confirm(c) } },
                         secondaryButton: .cancel(Text("取消")))
        }
    }
}
