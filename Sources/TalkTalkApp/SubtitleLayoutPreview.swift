// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore
import TalkTalkSession

/// Settings previews use each scene's real reading view, with fixed examples and no audio work.
struct SubtitleLayoutPreview: NSViewRepresentable {
    let presentation: SubtitlePanel.Presentation
    let fontSize: Double

    func makeNSView(context: NSViewRepresentableContext<Self>) -> SubtitlePreviewCanvas { SubtitlePreviewCanvas() }
    func updateNSView(_ view: SubtitlePreviewCanvas, context: NSViewRepresentableContext<Self>) {
        view.configure(presentation: presentation, fontSize: fontSize)
    }
}

/// Meeting and phone show the conversation timeline (one remote pair, one of my rows) above
/// the microphone dock with a static example curve; video shows its caption view.
final class SubtitlePreviewCanvas: NSView {
    private let timeline = ConversationTimelineView()
    private let dock = MicStatusDock()
    private let videoCaption = VideoSubtitleView()
    private var presentation: SubtitlePanel.Presentation = .meeting
    private var video: Bool { presentation == .video }
    private var fontSize = 22.0
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        for view in [timeline, dock, videoCaption] as [NSView] { addSubview(view) }
        videoCaption.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(presentation: SubtitlePanel.Presentation, fontSize: Double) {
        self.presentation = presentation
        self.fontSize = fontSize
        timeline.isHidden = video
        dock.isHidden = video
        videoCaption.isHidden = !video
        needsLayout = true
    }

    private var scene: SubtitleScene {
        switch presentation {
        case .meeting: .meeting
        case .phone: .phone
        case .video: .video
        }
    }

    private func row(_ id: ConversationTimeline.RowID, _ speaker: ConversationTimeline.Speaker, source: String,
                     translation: String, delivery: ConversationTimeline.Delivery? = nil, order: UInt64) -> ConversationTimeline.Row {
        .init(id: id, speaker: speaker, source: source, sourceIsLive: false, translation: translation, translationIsFinal: true,
              fallback: false, unsentSource: "", delivery: delivery, arrivedAt: HostTime(order), settledAt: HostTime(order), order: order)
    }

    override func layout() {
        super.layout()
        if video {
            videoCaption.frame = bounds
            let targetSize = max(14, fontSize * bounds.width / 960)
            func attributed(_ value: String, source: Bool) -> NSAttributedString {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.alignment = .center
                return NSAttributedString(string: value, attributes: [
                    .font: NSFont.systemFont(ofSize: source ? max(11, targetSize * 0.78) : targetSize),
                    .foregroundColor: source ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ])
            }
            videoCaption.setCaption(
                source: attributed("The simplest ideas often begin with a different way of looking.", source: true),
                translation: attributed(String(localized: "最简单的想法，往往始于一种不同的观看方式。"), source: false),
                sentence: 1, isFinal: true, at: 0)
            return
        }
        // The preview is narrower than a real window: scale the base size like the old preview.
        let scale = bounds.width / 760
        let typography = ConversationTypography(base: max(1, fontSize * scale), width: ConversationTypography.referenceWidth)
        let style = ConversationStyle(typography: typography, opacity: 0.85, display: .current, scene: scene, stacked: false)
        let phone = presentation == .phone
        let rows: [ConversationTimeline.Row] = phone ? [
            row(.remote(1), .remote, source: "I'm calling to confirm your appointment. Would Tuesday morning work for you?",
                translation: String(localized: "我打电话来确认您的预约。周二上午您方便吗？"), order: 1),
            row(.me(1), .me, source: String(localized: "周二上午可以，谢谢。请再告诉我一下具体地址。"),
                translation: "Tuesday morning works for me. Could you give me the address again?", delivery: .phoneSent, order: 2),
        ] : [
            row(.remote(1), .remote, source: "Let's confirm the plan for next week. Would Tuesday morning work for you?",
                translation: String(localized: "我们确认一下下周的安排。周二上午你方便吗？"), order: 1),
            row(.me(1), .me, source: String(localized: "周二上午可以。我们可以先看演示，再讨论接下来的安排。"),
                translation: "Tuesday morning works for me.", delivery: .sent, order: 2),
        ]
        timeline.setHeader(source: phone ? String(localized: "通话对方 · 英语") : String(localized: "原文 · 英语"),
                           translation: String(localized: "译文 · 中文"))
        timeline.apply(rows: rows, style: style, lastRowOnly: false, showsHeader: true)
        let voice = VoiceState.resolve(audio: .original, scene: scene, phoneInputConfirmed: true)
        let key = TitlebarKey.make(SpeechStatusPresentation(audio: .original, phoneInputConfirmed: phone ? true : nil),
                                   voice: voice)
        dock.apply(.init(presentation: MicDockPresentation.make(voice, scene: scene), key: key, turn: nil,
                         expanded: false, showsStartHint: false), style: style, compact: false)
        let dockHeight = CGFloat(SubtitleTokens.Size.statusBandIdleHeight)
        timeline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - dockHeight))
        dock.frame = NSRect(x: 0, y: max(0, bounds.height - dockHeight), width: bounds.width, height: dockHeight)
        // Fixed example only: the preview never starts audio or an animation timer.
        dock.setPreviewLevel(0.04)
    }
}
