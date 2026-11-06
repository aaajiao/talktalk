// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore

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

struct StepTitle: View {
    let number: Int
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: OnboardingStep.allCases.first { $0.number == number }?.guideSymbol ?? "checkmark")
                .font(.title2).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(title).font(.title2.bold())
        }
    }
}

/// A native group shared only by the onboarding pages, matching settings' content hierarchy.
struct OnboardingCard<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        } label: {
            Label(title, systemImage: symbol).font(.headline)
        }
    }
}
