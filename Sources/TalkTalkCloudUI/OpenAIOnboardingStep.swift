import SwiftUI
import TalkTalkCore

/// First-run onboarding step 5 (ARCHITECTURE.md §11): what goes to OpenAI, a separate “同意”,
/// then paste the key and verify; recommends a separate project with a budget cap. Optional:
/// without a key both directions can use Apple local text translation.
///
/// Uses the same `TranslationSettingsModel` as Settings › 翻译, so consent, key and verification
/// are one piece of state. The onboarding controller (M1) owns the step index:
///
///     OpenAIOnboardingStep(model: m, onContinue: { next() }, onSkip: { next() })
public struct OpenAIOnboardingStep: View {
    @Bindable var model: TranslationSettingsModel
    let onContinue: () -> Void
    let onSkip: () -> Void

    public init(model: TranslationSettingsModel, onContinue: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.model = model
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    /// Continue is offered once the key passed both checks (`GET /v1/models` and the probe).
    public var canContinue: Bool {
        if case .ok = model.verification { return true }
        return false
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "character.bubble").font(.title2)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenAI 文本翻译").font(.title2.bold())
                    Text("可选的云端翻译服务，也可以稍后设置。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            dataPath
            consent
            if model.preferences.cloudConsentGiven { credentials }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Apple 本地文本翻译也可使用", systemImage: "desktopcomputer")
                    .font(.callout.weight(.medium))
                Text("未配置 OpenAI key 时，两个方向都使用 Apple 本地文本翻译。以后可在 设置 › 模型 › 文本翻译 中配置。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("稍后设置") { onSkip() }
                    Spacer()
                    Button("继续") { onContinue() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(canContinue ? .defaultAction : nil)
                        .disabled(!canContinue)
                }
            }
        }
    }

    private var dataPath: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                pathStep(String(localized: "本机声音"), symbol: "waveform")
                pathArrow
                pathStep(String(localized: "原文文字"), symbol: "text.bubble")
                pathArrow
                pathStep(String(localized: "OpenAI 翻译"), symbol: "cloud")
                pathArrow
                pathStep(String(localized: "译文"), symbol: "character.bubble")
            }
            Label("仅文字发送到云端，音频留在这台 Mac。", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func pathStep(_ title: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.callout).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var pathArrow: some View {
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
    }

    private var consent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(TranslationSettingsText.cloudNotice).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if model.preferences.cloudConsentGiven {
                    Label("已同意", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("同意以上说明") { model.giveConsent() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("云端授权", systemImage: "cloud") }
    }

    private var credentials: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if case .saved(let masked) = model.keyState {
                    LabeledContent("当前 key") { Text(masked).monospaced() }
                }
                SecureField(model.hasKey ? "粘贴新的 key 以替换" : "粘贴 OpenAI API key（sk-…）", text: $model.pasteField)
                    .textContentType(.password)
                    .onSubmit { Task { await model.saveAndVerify() } }
                HStack {
                    Button("保存并验证") { Task { await model.saveAndVerify() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.pasteField.isEmpty)
                    if model.hasKey && model.pasteField.isEmpty {
                        Button("验证现有 key") { Task { await model.verify() } }
                    }
                }
                if let p = model.pasteProblem { Text(p).foregroundStyle(.red).font(.callout) }
                if let h = model.savedHint { Text(h).foregroundStyle(.secondary).font(.callout) }
                status
                Text(TranslationSettingsText.keyAdvice).font(.footnote).foregroundStyle(.secondary)
                Link("OpenAI key 页面", destination: TranslationSettingsText.keyPageURL).font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("API key 与验证", systemImage: "key") }
    }

    @ViewBuilder private var status: some View {
        switch model.verification {
        case .idle: EmptyView()
        case .running(let s): HStack { ProgressView().controlSize(.small); Text(s).font(.callout) }
        case .ok(let s): Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failed(let s): Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
        }
    }
}
