// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSettingsUI

/// Settings › 通用's last, destructive section (settings visual system §7.5 Z4; ARCHITECTURE.md
/// §8.4): a native "完全卸载…" button and, after a run, its result rows. Put it alone in a Form
/// Section. The row's end shows the running step, or waiting "引擎安装中" with a maintenance link
/// while the engine installer runs. The confirmation lists what goes in one line. After a run:
/// "已删除 N 项" (the full sentence with what to do next in help), what was not removed one per
/// line behind a failure glyph, and when a run stopped early, what it had already done.
public struct FullUninstallSection: View {
    // No @State: the CLT toolchain has no SwiftUIMacros plugin (§11 工具链); the flag lives in the model.
    private let model: DriverComponentModel?
    private let unavailable: String?
    private let openComponents: (() -> Void)?

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    /// `model` nil: this run cannot uninstall (a binary without a bundle id, the smoke run); the
    /// row stays, disabled, with `unavailable` as its help. `openComponents`: the maintenance link
    /// shown while the engine installer runs.
    public init(model: DriverComponentModel?, unavailable: String? = nil, openComponents: (() -> Void)? = nil) {
        self.model = model
        self.unavailable = unavailable
        self.openComponents = openComponents
    }

    /// The confirmation's one line: what is deleted, what it costs, when it cannot run, and what
    /// is left to the user.
    static var explanation: String { String(appLocalized: "将删除：虚拟麦克风 · 引擎与模型 · 我的声音 · 术语表 · 日志缓存 · 设置与登录项 · 钥匙串中的 OpenAI key，并重置隐私权限。需管理员密码，声音中断约 1 秒；通话中不可卸载。完成后退出并移到废纸篓。") }

    public var body: some View {
        if let model {
            ModelRows(model: model, openComponents: openComponents)
        } else {
            Self.row(enabled: false) { EmptyView() }
                .help(ifPresent: unavailable)
        }
    }

    /// A neutral label with a separate native destructive button; progress stays alongside it.
    static func row(enabled: Bool, action: @escaping () -> Void = {},
                    @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Label("TalkTalk 与本机数据", systemImage: Icon.delete)
                .labelStyle(.settingsRow)
            Spacer(minLength: 8)
            trailing()
            SettingsDestructiveButton(String(appLocalized: "完全卸载…"), help: explanation,
                                      accessibilityLabel: String(appLocalized: "完全卸载 TalkTalk"), action: action)
                .disabled(!enabled)
                .accessibilityHint(Text(explanation))
        }
    }

    /// The rows for a model that can run 完全卸载.
    private struct ModelRows: View {
        @Bindable var model: DriverComponentModel
        let openComponents: (() -> Void)?

        var body: some View {
            FullUninstallSection.row(enabled: !model.fullUninstallBlocked, action: { model.requestFullUninstall() }) {
                trailing
            }
            .alert("完全卸载 TalkTalk？", isPresented: $model.confirmingFullUninstall) {
                Button("取消", role: .cancel) {}
                Button("卸载并删除本机数据") { Task { await model.confirm(.fullUninstall) } }
            } message: {
                Text(FullUninstallSection.explanation)
            }
            if let summary = model.fullUninstallSummary { ResultRows(summary: summary) }
        }

        @ViewBuilder private var trailing: some View {
            if case .running(let step)? = model.fullUninstaller?.phase {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(Text(verbatim: step.title))
                Text(verbatim: step.title).foregroundStyle(.secondary).accessibilityHidden(true)
            } else if model.fullUninstaller?.isEngineBusy == true {
                StatusLabel(String(appLocalized: "引擎安装中"), .waiting, help: FullUninstaller.engineBusyText)
                if let openComponents {
                    Button("安装与维护 ›", action: openComponents)
                        .buttonStyle(.link)
                        .help("打开安装与维护页")
                }
            }
        }
    }

    /// One run's result, indented to the row text (+30); paths stay selectable for Finder's
    /// 前往文件夹.
    private struct ResultRows: View {
        let summary: FullUninstallSummary

        var body: some View {
            StatusLabel(summary.short, status, help: help)
                .padding(.leading, Ladder.rowTextInset)
            if !summary.notRemoved.isEmpty {
                lines(String(appLocalized: "未删除："), summary.notRemoved, glyph: .failed)
            }
            // A run that stopped early names what it had already done (the default input may be
            // restored before the driver step refuses).
            if summary.outcome == .stopped, !summary.done.isEmpty {
                lines(nil, summary.done, glyph: .ok)
            }
        }

        private var status: SettingsStatus {
            switch summary.outcome {
            case .complete: .ok
            case .incomplete: .warn
            case .stopped: summary.failed ? .failed : summary.reason == nil ? .pending : .warn
            }
        }

        private var help: String {
            [summary.reason, summary.headline].compactMap { $0 }.joined(separator: "\n")
        }

        private func lines(_ title: String?, _ items: [String], glyph: SettingsStatus) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(verbatim: title).foregroundStyle(.secondary) }
                ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        StatusGlyph(glyph).accessibilityHidden(true)
                        Text(verbatim: line)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, Ladder.rowTextInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
