// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSettingsUI

/// First-run onboarding step 5 (ARCHITECTURE.md §11, settings visual system §7.17): the sections
/// of 模型 › 文本翻译 for a grouped Form, without its flow and model sections. DataBoundary says
/// what stays on this Mac and what goes to OpenAI; `OpenAIKeySection` holds the consent, the key
/// and its verification; one chip says Apple translates without a key. Optional.
///
/// Uses the same `TranslationSettingsModel` as Settings › 模型, so consent, key and verification
/// are one piece of state; 删除 key confirms only in the window that asked (`host`). The
/// onboarding window owns the step and its footer buttons:
///
///     Form { OpenAIOnboardingStep(model: m) }.formStyle(.grouped).labelStyle(.settingsRow)
///     Button("继续") { next() }.disabled(!OpenAIOnboardingStep.canContinue(m))
public struct OpenAIOnboardingStep: View {
    @Bindable var model: TranslationSettingsModel

    private typealias Icon = SubtitleTokens.SettingsIcon

    public init(model: TranslationSettingsModel) {
        self.model = model
    }

    /// 继续 is offered once the key passed both checks (`GET /v1/models` and the probe).
    public static func canContinue(_ model: TranslationSettingsModel) -> Bool {
        if case .ok = model.verification { return true }
        return false
    }

    public var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                DataBoundary(cloudEnabled: model.flowFacts.cloudConnected, info: [TranslationSettingsText.cloudNotice])
                FactRow([FactChip(String(appLocalized: "不配也能用 Apple"), symbol: Icon.thisMac,
                                  help: String(appLocalized: "没有 key 时两个方向都用 Apple"),
                                  spoken: String(appLocalized: "未配置 OpenAI key 时，两个方向都使用 Apple 本地文本翻译；以后可在 设置 › 识别与翻译 › 文本翻译 中配置"))])
            }
            .padding(.vertical, 4)
        }
        OpenAIKeySection(model: model, host: .onboarding)
    }
}
