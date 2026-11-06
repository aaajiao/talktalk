// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI

/// Settings previews use the real scrolling text view, with fixed examples and no audio work.
struct SubtitleLayoutPreview: NSViewRepresentable {
    let presentation: SubtitlePanel.Presentation
    let fontSize: Double

    func makeNSView(context: Context) -> SubtitlePreviewCanvas { SubtitlePreviewCanvas() }
    func updateNSView(_ view: SubtitlePreviewCanvas, context: Context) {
        view.configure(presentation: presentation, fontSize: fontSize)
    }
}

final class SubtitlePreviewCanvas: NSView {
    private let remote = ConversationColumnsView()
    private let local = ConversationColumnsView()
    private let videoCaption = VideoSubtitleView()
    private let rowDivider = NSBox()
    private var presentation: SubtitlePanel.Presentation = .meeting
    private var pendingReset = true
    private var video: Bool { presentation == .video }
    private var fontSize = 22.0
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        rowDivider.boxType = .separator
        for view in [remote, local, videoCaption, rowDivider] { addSubview(view) }
        videoCaption.isHidden = true
        remote.setHeadings(source: String(localized: "对方 · 英语"), sourceSymbol: "person", translation: String(localized: "中文"))
        local.setHeadings(source: String(localized: "我 · 中文"), sourceSymbol: "mic", translation: String(localized: "英语"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(presentation: SubtitlePanel.Presentation, fontSize: Double) {
        if self.presentation != presentation { pendingReset = true }
        self.presentation = presentation
        self.fontSize = fontSize
        remote.style = video ? .subtitles : .columns
        remote.isHidden = video
        videoCaption.isHidden = !video
        local.isHidden = video
        rowDivider.isHidden = video
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let resetScroll = pendingReset
        if video {
            videoCaption.frame = bounds
        } else {
            let rowGap: CGFloat = 20
            let rowHeight = max(0, (bounds.height - rowGap) / 2)
            remote.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight)
            rowDivider.frame = NSRect(x: 0, y: rowHeight + rowGap / 2, width: bounds.width, height: 1)
            local.frame = NSRect(x: 0, y: rowHeight + rowGap, width: bounds.width, height: rowHeight)
        }
        let targetSize = max(14, fontSize * bounds.width / (video ? 960 : 760))
        func attributed(_ value: String, source: Bool) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = video ? .center : .left
            paragraph.paragraphSpacing = 10
            return NSAttributedString(string: value, attributes: [
                .font: NSFont.systemFont(ofSize: source ? max(11, targetSize * 0.78) : targetSize),
                .foregroundColor: source ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        }
        if video {
            videoCaption.setCaption(
                source: attributed("The simplest ideas often begin with a different way of looking.", source: true),
                translation: attributed(String(localized: "最简单的想法，往往始于一种不同的观看方式。"), source: false),
                sentence: 1, isFinal: true, at: 0)
        } else if presentation == .phone {
            remote.setText(
                source: attributed("I'm calling to confirm your appointment. Would Tuesday morning work for you?", source: true),
                translation: attributed(String(localized: "我打电话来确认您的预约。周二上午您方便吗？"), source: false),
                resetScroll: resetScroll)
            local.setText(
                source: attributed(String(localized: "周二上午可以，谢谢。请再告诉我一下具体地址。"), source: true),
                translation: attributed("Tuesday morning works for me. Could you give me the address again?", source: false),
                resetScroll: resetScroll)
        } else {
            remote.setText(
                source: attributed("Let's confirm the plan for next week. Would Tuesday morning work for you?", source: true),
                translation: attributed(String(localized: "我们确认一下下周的安排。周二上午你方便吗？"), source: false),
                resetScroll: resetScroll)
            local.setText(
                source: attributed(String(localized: "周二上午可以。我们可以先看演示，再讨论接下来的安排。"), source: true),
                translation: attributed("Tuesday morning works for me.", source: false),
                resetScroll: resetScroll)
        }
        pendingReset = false
        // Fixed example only: the preview never starts audio or an animation timer.
        local.setInputPreviewActivity(video ? nil : 0.04)
        local.setOutputActivity(symbol: video ? nil : "ellipsis", label: nil)
    }
}
