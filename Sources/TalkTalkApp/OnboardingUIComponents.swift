// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSettingsUI

extension OnboardingStep {
    var guideTitle: String {
        switch self {
        case .permissions: String(localized: "权限")
        case .speechAssets: String(localized: "语言资源")
        case .driver: String(localized: "虚拟麦")
        case .engine: String(localized: "语音引擎")
        case .openAI: String(localized: "文本翻译")
        case .voice: String(localized: "我的声音")
        case .meetingMic: String(localized: "连接会议")
        case .tryIt: String(localized: "试一试")
        }
    }
}

enum OnboardingLayout {
    /// The leading inset of the step title, the window's header and its footer: the grouped
    /// Form's own, so they line up with the sections.
    static let inset: Double = 20
}

/// A step's title (settings visual system §7.17): its glyph at L1 22 pt in the accent colour,
/// then the title in title2 bold. Every step uses it, OpenAI's too; the done page passes its own
/// glyph. `title` is already localized.
struct StepTitle: View {
    let symbol: String
    let title: String

    init(_ step: OnboardingStep, _ title: String) {
        symbol = step.guideSymbol
        self.title = title
    }

    init(symbol: String, title: String) {
        self.symbol = symbol
        self.title = title
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: SubtitleTokens.SettingsIcon.Size.card, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, OnboardingLayout.inset)
        .padding(.top, 16)
    }
}

/// One step's page (§7.17): the StepTitle pinned above a grouped Form whose sections are the
/// settings pages' own (the main graphic first, no header; `.settingsRow` at the root). Only the
/// Form scrolls; the window's header and footer stay put.
struct OnboardingPage<Content: View>: View {
    let title: StepTitle
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            Form(content: content)
                .formStyle(.grouped)
                .labelStyle(.settingsRow)
        }
    }
}
