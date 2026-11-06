// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore
import TalkTalkSession

// Shared pieces of the scenario pages and onboarding (redesign §7): flow node cards, the two
// speaking lanes with the subtitle window's own capsule and keycap, ⓘ popovers and the
// "‹ 返回" pill.

/// The subtitle window's voice capsule, read-only (no chevron, no details popover). In light
/// mode the token colours use their light-surface values.
struct VoiceCapsule: NSViewRepresentable {
    let state: VoiceState
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: NSViewRepresentableContext<Self>) -> VoiceCapsuleView {
        let view = VoiceCapsuleView(large: false)
        view.showsChevron = false
        return view
    }

    func updateNSView(_ view: VoiceCapsuleView, context: NSViewRepresentableContext<Self>) {
        view.lightSurface = colorScheme == .light
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.apply(state, full: true) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: VoiceCapsuleView,
                      context: NSViewRepresentableContext<Self>) -> CGSize? {
        CGSize(width: VoiceCapsuleView.width(for: state, full: true, large: false, chevron: false),
               height: SubtitleTokens.Size.controlHeight)
    }
}

/// The subtitle window's 右⌥ keycap with its action text.
struct Keycap: NSViewRepresentable {
    let key: TitlebarKey
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: NSViewRepresentableContext<Self>) -> KeycapActionView { KeycapActionView() }

    func updateNSView(_ view: KeycapActionView, context: NSViewRepresentableContext<Self>) {
        view.lightSurface = colorScheme == .light
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.apply(key, showsAction: true) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KeycapActionView,
                      context: NSViewRepresentableContext<Self>) -> CGSize? {
        CGSize(width: KeycapActionView.width(for: key, showsAction: true), height: SubtitleTokens.Size.controlHeight)
    }
}

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
    /// Opens another settings page and offers "‹ 返回 <场景>" there. nil (onboarding): the
    /// lanes show without links.
    let follow: ((_ open: @escaping () -> Void) -> Void)?
    let navigation: SettingsNavigation?

    /// A flow link that opens `page` in settings; none without settings navigation.
    private func link(_ title: String, _ page: @escaping (SettingsNavigation) -> Void) -> FlowLink? {
        guard let follow, let navigation else { return nil }
        return FlowLink(title) { follow { page(navigation) } }
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
                             link: link(String(localized: "麦克风设置")) { $0.selection = .audio })
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
                             link: link(String(localized: "翻译设置")) { $0.openModel(.translation) })
                FlowArrow()
                FlowNodeCard(symbol: SubtitleTokens.SettingsIcon.myVoice, title: String(localized: "我的声音"),
                             link: link(String(localized: "声音与试听")) { $0.selection = .voice })
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

/// ⓘ: operating hints live in a popover instead of the page (§7 文案). AppKit-backed: the CLT
/// toolchain has no SwiftUIMacros plugin, so the popover state lives in the coordinator, not in
/// `@State`.
struct InfoButton: NSViewRepresentable {
    /// What the popover explains ("会议同传"): several ⓘ on one page stay distinguishable.
    let topic: String
    let lines: [String]

    @MainActor final class Coordinator: NSObject {
        var lines: [String] = []
        let popover = NSPopover()

        override init() {
            super.init()
            popover.behavior = .transient
            popover.animates = false
        }

        @objc func toggle(_ sender: NSButton) {
            if popover.isShown { popover.performClose(sender); return }
            let content = VStack(alignment: .leading, spacing: 8) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            popover.contentViewController = NSHostingController(rootView: content)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        return button
    }

    func updateNSView(_ button: NSButton, context: NSViewRepresentableContext<Self>) {
        context.coordinator.lines = lines
        let name = String(localized: "\(topic)说明")
        button.toolTip = name
        button.setAccessibilityLabel(name)
        button.setAccessibilityHelp(lines.joined(separator: "\n"))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton,
                      context: NSViewRepresentableContext<Self>) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// "‹ 返回 会议同传" at the top of a page reached from a scenario's flow link (§7).
struct ReturnToScenePill: View {
    let mode: MeetingMode
    let back: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Label(String(localized: "返回 \(mode.scene.title)"), systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            Button(action: dismiss) {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "关闭"))
            .accessibilityLabel(String(localized: "关闭返回提示"))
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(.quaternary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
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

/// One status vocabulary across Settings (shape first, then colour, then words): passed, needs
/// action, blocks speech (the other party hears the original voice), failed, a neutral note,
/// not yet checked, and waiting. `risk` draws the titlebar's risk glyph (mic with a warning
/// badge, the menu bar and onboarding use it too); `symbol` is its plain fallback.
enum SettingsStatus {
    case ok, warn, risk, failed, info, pending, waiting

    /// The state's glyph in its colour, at the surrounding font size.
    @MainActor @ViewBuilder var icon: some View {
        if self == .risk, let risk = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.originalRisk,
                                                          size: NSFont.systemFontSize, weight: .regular) {
            Image(nsImage: SubtitleStyle.tinted(risk, .systemRed))
        } else {
            Image(systemName: symbol)
        }
    }

    var symbol: String {
        typealias I = SubtitleTokens.SettingsIcon
        return switch self {
        case .ok: I.statusOK
        case .warn, .risk: I.statusWarn
        case .failed: I.statusFailed
        case .info: I.statusInfo
        case .pending: I.statusPending
        case .waiting: I.statusWaiting
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .risk, .failed: .red
        case .info, .pending, .waiting: .secondary
        }
    }
}

/// A status row: the state's glyph and colour with its (unchanged) text.
struct SettingsStatusLabel: View {
    let text: String
    let status: SettingsStatus
    init(_ text: String, _ status: SettingsStatus) {
        self.text = text
        self.status = status
    }

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            status.icon.accessibilityHidden(true)
        }
        .foregroundStyle(status.color)
    }
}
