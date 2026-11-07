import SwiftUI
import TalkTalkSettingsUI

/// Settings › 组件 › 虚拟麦克风 (ARCHITECTURE.md §11): status, install / update, self-test,
/// uninstall, restart the audio service, and who is using TalkTalk Mic. Holds no state of its own.
/// One self-contained group, shared by the components page and onboarding. Keep lifecycle
/// modifiers on this container so refresh and confirmation occur only once. 完全卸载 is
/// `FullUninstallSection`, on Settings › 通用.
///
///     VStack(alignment: .leading) {
///         // engine rows …
///         DriverComponentSection(model: driver)
///     }
public struct DriverComponentSection: View {
    @Bindable var model: DriverComponentModel

    public init(model: DriverComponentModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mic.fill").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TalkTalk Mic · 虚拟麦克风").font(.headline)
                    Text("把原声或译音送进会议，请在会议 App 中选择 TalkTalk Mic。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            StatusLabel(model.statusText, status(model.statusTone)).fixedSize(horizontal: false, vertical: true)
            if !model.users.isEmpty {
                Label("正在使用：\(model.users.joined(separator: "、"))", systemImage: "app").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            progress
            actions
            selfTestRows
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("好") { model.dismissNotice() }.buttonStyle(.borderless)
                }
            }
            Text("TalkTalk Mic 仅在 TalkTalk 运行时出现。安装或维护需要管理员授权，系统声音会短暂中断。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.refresh() }
        .alert(item: $model.confirmation) { c in alert(c) }
    }

    @ViewBuilder private var progress: some View {
        switch model.installer.phase {
        case .staging:
            ProgressView("正在校验随 App 带的驱动…").controlSize(.small)
        case .waitingForAuthorization:
            ProgressView("等待管理员授权…").controlSize(.small)
        case .waitingForDevices(let n):
            ProgressView("音频服务重启中，等待设备出现（\(n)/30）…").controlSize(.small)
        default:
            if model.selfTestRunning { ProgressView("自检中（约 20 秒）…").controlSize(.small) }
        }
    }

    @ViewBuilder private var actions: some View {
        let busy = model.isBusy
        HStack {
            switch model.state {
            case .notInstalled:
                Button("安装虚拟麦克风") { model.requestInstall() }
                    .buttonStyle(.borderedProminent).disabled(busy || !model.carriesDriver)
            case .outdated:
                Button("更新虚拟麦克风") { model.requestInstall() }.buttonStyle(.borderedProminent).disabled(busy)
            case .onDiskNotLoaded:
                Button("重启音频服务") { model.requestRestartAudio() }.buttonStyle(.borderedProminent).disabled(busy)
            case .damaged:
                Button("重新安装") { model.requestInstall() }.buttonStyle(.borderedProminent).disabled(busy || !model.carriesDriver)
            case .loaded, .selfTestFailed:
                Button { Task { await model.runSelfTest() } } label: { Label("运行自检", systemImage: "checkmark.shield") }
                    .disabled(busy)
            }
            Spacer()
            Menu("维护") {
                Button("刷新状态") { model.refresh() }
                switch model.state {
                case .loaded, .selfTestFailed:
                    Button("重新安装") { model.requestInstall() }
                default: EmptyView()
                }
                if model.state != .notInstalled {
                    Divider()
                    Button("卸载虚拟麦克风…", role: .destructive) { model.requestUninstall() }
                }
            }
            .fixedSize().disabled(busy)
        }
    }

    @ViewBuilder private var selfTestRows: some View {
        if let report = model.selfTest {
            DisclosureGroup("自检详情") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.checks, id: \.name) { c in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DriverComponentModel.checkTitle(c.name)).font(.callout)
                                if !c.detail.isEmpty {
                                    Text(c.detail).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            StatusLabel(c.passed.map { $0 ? String(localized: "通过") : String(localized: "没通过") } ?? String(localized: "跳过"),
                                        c.passed.map { $0 ? .ok : .failed } ?? .pending)
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 6)
            }
        } else if let t = model.record?.selfTest {
            StatusLabel(String(localized: "上次自检：\(t.passed ? "通过" : "没通过") · \(t.at.formatted(date: .abbreviated, time: .shortened))"),
                        t.passed ? .ok : .failed)
        }
    }

    private func alert(_ c: DriverComponentModel.Confirmation) -> Alert {
        func warn(_ w: [DriverPreflight.Warning]) -> String { w.map(\.text).joined(separator: "\n") }
        switch c {
        case .install(let w, let update):
            return Alert(title: Text(update ? "重新安装虚拟麦克风？" : "安装虚拟麦克风？"),
                         message: Text(["要输入一次管理员密码，系统音频会重启（声音中断约 1 秒）。", warn(w)]
                             .filter { !$0.isEmpty }.joined(separator: "\n\n")),
                         primaryButton: .default(Text(update ? "重新安装" : "安装")) { Task { await model.confirm(c) } },
                         secondaryButton: .cancel(Text("取消")))
        case .uninstall(let w):
            return Alert(title: Text("卸载虚拟麦克风？"),
                         message: Text(["卸载后，会议 App 会切回实体麦克风。", warn(w)].filter { !$0.isEmpty }
                             .joined(separator: "\n\n")),
                         primaryButton: .destructive(Text("卸载")) { Task { await model.confirm(c) } },
                         secondaryButton: .cancel(Text("取消")))
        case .restartAudio(let w):
            return Alert(title: Text("重启音频服务？"),
                         message: Text(["要输入一次管理员密码。", warn(w)].filter { !$0.isEmpty }.joined(separator: "\n\n")),
                         primaryButton: .default(Text("重启")) { Task { await model.confirm(c) } },
                         secondaryButton: .cancel(Text("取消")))
        case .fullUninstall:
            return Alert(title: Text("完全卸载 TalkTalk？"),
                         message: Text(FullUninstallSection.explanation),
                         primaryButton: .destructive(Text("全部删除")) { Task { await model.confirm(c) } },
                         secondaryButton: .cancel(Text("取消")))
        }
    }

    /// The driver state in the settings status vocabulary (§3.7): not installed is "not yet",
    /// damaged or a failed self-test is a failure, not a warning.
    private func status(_ t: DriverComponentModel.Tone) -> SettingsStatus {
        switch t {
        case .ok: .ok
        case .warning: .warn
        case .error: .failed
        case .neutral: .pending
        }
    }
}
