import SwiftUI

/// Settings › 组件 › 虚拟麦克风 (ARCHITECTURE.md §11): status, install / update, self-test,
/// uninstall, restart the audio service, and who is using TalkTalk Mic. Holds no state of its own.
/// One self-contained group, shared by the components page and onboarding. Keep lifecycle
/// modifiers on this container so refresh and confirmation occur only once.
///
///     VStack(alignment: .leading) {
///         // engine rows …
///         DriverComponentSection(model: driver)
///         FullUninstallSection(model: driver)
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
            Label(model.statusText, systemImage: statusSymbol)
                .font(.callout).foregroundStyle(color(model.statusTone)).fixedSize(horizontal: false, vertical: true)
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
                            Text(c.passed == nil ? "跳过" : (c.passed! ? "通过" : "没通过")).font(.callout)
                                .foregroundStyle(c.passed == nil ? Color.secondary : (c.passed! ? Color.green : Color.red))
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 6)
            }
        } else if let t = model.record?.selfTest {
            Text("上次自检：\(t.passed ? "通过" : "没通过") · \(t.at.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout).foregroundStyle(.secondary)
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

    private func color(_ t: DriverComponentModel.Tone) -> Color {
        switch t {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }

    private var statusSymbol: String {
        switch model.statusTone {
        case .ok: "checkmark.circle.fill"
        case .warning, .error: "exclamationmark.triangle.fill"
        case .neutral: "info.circle"
        }
    }
}

/// The 完全卸载 TalkTalk row (§8.4). Separate so the components page can put it last. After a run
/// it shows `FullUninstallSummary` as it is: what was not removed one per line, a refusal's or
/// failure's reason unchanged, and what was already done when a run stopped early.
public struct FullUninstallSection: View {
    // No @State: the CLT toolchain has no SwiftUIMacros plugin (§11 工具链); the flag lives in the model.
    @Bindable var model: DriverComponentModel

    public init(model: DriverComponentModel) { self.model = model }

    static let explanation = """
        先把系统默认输入还原成原来的麦克风（如果它还是 TalkTalk Mic），再删除：虚拟麦克风（要输入一次\
        管理员密码，所有 App 的声音中断约 1 秒）、引擎和模型、我的声音、术语表、日志、缓存、TalkTalk 的设置和登录项、\
        钥匙串里 TalkTalk 存的 OpenAI key，并重置 TalkTalk 的麦克风等权限。正在通话时不能卸载；会议模式开着时，\
        还原默认输入以后会停在卸载虚拟麦克风这一步，先结束会议模式再点一次。做完后请退出 TalkTalk，把它拖进废纸篓。
        """

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("完全卸载 TalkTalk").font(.headline)
                    Text("移除组件及本机的声音档案、设置和数据。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let p = model.fullUninstaller?.phase, case .running(let step) = p {
                    ProgressView().controlSize(.small)
                    Text(step.title).font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("完全卸载…", role: .destructive) { model.requestFullUninstall() }
                        .disabled(model.fullUninstallBlocked)
                }
            }
            if model.fullUninstaller?.isEngineBusy == true, model.fullUninstaller?.phase.isRunning != true {
                Text(FullUninstaller.engineBusyText).font(.callout).foregroundStyle(.secondary)
            }
            if let summary = model.fullUninstallSummary { FullUninstallResultView(summary: summary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("完全卸载 TalkTalk？", isPresented: $model.confirmingFullUninstall) {
            Button("全部删除", role: .destructive) { Task { await model.confirm(.fullUninstall) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.explanation)
        }
    }
}

/// One run's result, every line selectable (paths can be copied into Finder's 前往文件夹).
struct FullUninstallResultView: View {
    let summary: FullUninstallSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.headline).font(.callout)
                .foregroundStyle(summary.outcome == .complete ? Color.primary : Color.orange)
            if let reason = summary.reason {
                Text(reason).font(.callout)
            }
            if !summary.notRemoved.isEmpty {
                Text("没有删除或没有做成的：").font(.callout)
                ForEach(Array(summary.notRemoved.enumerated()), id: \.offset) { _, line in
                    Text("• " + line).font(.callout)
                }
            }
            if !summary.done.isEmpty {
                if summary.outcome == .stopped {
                    ForEach(Array(summary.done.enumerated()), id: \.offset) { _, line in
                        Text("✓ " + line).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    DisclosureGroup("已删除的（\(summary.done.count) 项）") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(summary.done.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}
