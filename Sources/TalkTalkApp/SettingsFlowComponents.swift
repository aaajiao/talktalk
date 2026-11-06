// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

// Shared pieces of the scenario pages and onboarding (redesign §7): flow node cards and the two
// speaking lanes with the subtitle window's own capsule and keycap. The capsule, keycap, ⓘ,
// ReturnPill and the status vocabulary live in TalkTalkSettingsUI.

/// A link under a flow node ("模型设置 ›").
struct FlowLink {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// The single flow-node card: radius 10, quaternary fill, secondary icon, min height 44; a link
/// sits at the card's lower edge as a callout link button.
struct FlowNodeCard<Leading: View>: View {
    let symbol: String?
    let title: String
    var link: FlowLink?
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        VStack(spacing: 5) {
            leading()
            if let symbol {
                Image(systemName: symbol).font(.title3).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(title).font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let link {
                Button(action: link.action) {
                    HStack(spacing: 2) {
                        Text(link.title)
                        Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
                .accessibilityLabel(String(localized: "\(title)，\(link.title)"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(RoundedRectangle(cornerRadius: SubtitleTokens.Radius.settingsCard).fill(.quaternary))
        .accessibilityElement(children: .contain)
    }
}

extension FlowNodeCard where Leading == EmptyView {
    init(symbol: String?, title: String, link: FlowLink? = nil) {
        self.init(symbol: symbol, title: title, link: link, leading: { EmptyView() })
    }
}

/// The arrow between flow nodes.
struct FlowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right").font(.body.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// A short, accessible diagram made from system symbols rather than decorative artwork.
struct SpeechFlow: View {
    typealias Link = FlowLink
    let steps: [(symbol: String, title: String)]
    var links: [Int: FlowLink] = [:]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(steps.indices, id: \.self) { index in
                if index > 0 { FlowArrow() }
                FlowNodeCard(symbol: steps[index].symbol, title: steps[index].title, link: links[index])
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: links.isEmpty ? .ignore : .contain)
        .accessibilityLabel(links.isEmpty ? steps.map(\.title).joined(separator: String(localized: "，然后")) : String(localized: "声音处理流程"))
    }
}

/// "我说话" as two lanes (§7): the default original-voice lane and the 右⌥ translation lane,
/// with the loop note between them. Capsules and keycap are the subtitle window's components.
struct SpeakingLanes: View {
    let mode: MeetingMode
    /// Opens another settings page and offers ReturnPill back there. nil (onboarding): the
    /// lanes show without links.
    let open: ((SettingsSection, SettingsSubpage?) -> Void)?

    /// A flow link to a settings page; none without settings navigation.
    private func link(_ title: String, _ section: SettingsSection, _ subpage: SettingsSubpage? = nil) -> FlowLink? {
        guard let open else { return nil }
        return FlowLink(title) { open(section, subpage) }
    }

    private var phone: Bool { mode == .phone }
    private var remoteSymbol: String {
        phone ? SubtitleTokens.ConversationIcon.phoneRemote : SubtitleTokens.SettingsIcon.remote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我说话").font(.subheadline.weight(.semibold))
            laneHeader(VoiceState.resolve(audio: .original, scene: mode.scene, phoneInputConfirmed: true),
                       title: String(localized: "默认 · 原声"))
            HStack(spacing: 8) {
                FlowNodeCard(symbol: SubtitleTokens.SettingsIcon.physicalMic, title: String(localized: "麦克风"),
                             link: link(String(localized: "麦克风设置"), .audio))
                FlowArrow()
                FlowNodeCard(symbol: SubtitleTokens.SettingsIcon.talkTalkMic, title: "TalkTalk Mic")
                FlowArrow()
                FlowNodeCard(symbol: remoteSymbol,
                             title: phone ? String(localized: "通话对方听到原声") : String(localized: "对方听到原声"))
            }
            // The keycap's own end glyph; arrow.triangle.2.circlepath means reconnecting/restarting.
            Label(String(localized: "再点按 右⌥ 结束 · 译音播完后回到原声"), systemImage: SubtitleTokens.VoiceIcon.stopTranslation)
                .font(.caption).foregroundStyle(.secondary)
            laneHeader(VoiceState.resolve(audio: .translating, scene: mode.scene, phoneInputConfirmed: true),
                       title: String(localized: "点按 右⌥ · 翻译"))
            HStack(spacing: 8) {
                FlowNodeCard(symbol: nil, title: String(localized: "说中文，可夹英语")) {
                    Keycap(key: TitlebarKey(action: String(localized: "开始翻译"), style: .idle))
                }
                FlowArrow()
                FlowNodeCard(symbol: "character.bubble", title: String(localized: "识别与翻译"),
                             link: link(String(localized: "翻译设置"), .translation, .model(.translation)))
                FlowArrow()
                FlowNodeCard(symbol: SubtitleTokens.SettingsIcon.myVoice, title: String(localized: "我的声音"),
                             link: link(String(localized: "声音与试听"), .voice))
                FlowArrow()
                // The same audience as the original lane: the lane headers say what it hears.
                FlowNodeCard(symbol: remoteSymbol, title: String(localized: "对方听英语／德语"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func laneHeader(_ voice: VoiceState, title: String) -> some View {
        HStack(spacing: 8) {
            VoiceCapsule(state: voice).accessibilityLabel(voice.title)
            Text(title).font(.callout.weight(.medium))
        }
    }
}

/// The checklist's 24 pt status circle: the system's numbered circle, a progress ring, or a
/// green check (§7 电话页). Both glyphs share one font size, so their weights match.
struct ChecklistStatusCircle: View {
    let number: Int
    let status: PhoneChecklist.Status

    var body: some View {
        ZStack {
            switch status {
            case .pending:
                Image(systemName: "\(number).circle").font(.system(size: 22)).foregroundStyle(.secondary)
            case .inProgress:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: SubtitleTokens.SettingsIcon.statusOK).font(.system(size: 22))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
