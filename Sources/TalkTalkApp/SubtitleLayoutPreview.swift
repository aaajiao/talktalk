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
    private let remoteHeading = NSTextField(labelWithString: String(localized: "对方"))
    private let localHeading = NSTextField(labelWithString: String(localized: "我的发言"))
    private let phoneFooter = PhoneSubtitleFooterView()
    private var presentation: SubtitlePanel.Presentation = .meeting
    private var video: Bool { presentation == .video }
    private var fontSize = 22.0
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        for view in [remote, local, remoteHeading, localHeading, phoneFooter] { addSubview(view) }
        phoneFooter.setContext(String(localized: "示例通话 · 电话由 Phone 管理"))
        phoneFooter.setActionsEnabled(false)
        phoneFooter.isHidden = true
        for heading in [remoteHeading, localHeading] {
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            heading.textColor = .secondaryLabelColor
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(presentation: SubtitlePanel.Presentation, fontSize: Double) {
        self.presentation = presentation
        self.fontSize = fontSize
        remote.style = video ? .subtitles : .columns
        local.isHidden = video
        remoteHeading.isHidden = video
        localHeading.isHidden = video
        remoteHeading.stringValue = presentation == .phone ? String(localized: "电话对方") : String(localized: "对方")
        phoneFooter.isHidden = presentation != .phone
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if video {
            remote.frame = bounds
        } else {
            let phoneSpace = presentation == .phone ? PhoneSubtitleFooterView.height + 12 : 0
            let rowHeight = max(30, (bounds.height - 52 - phoneSpace) / 2)
            remoteHeading.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
            remote.frame = NSRect(x: 0, y: 22, width: bounds.width, height: rowHeight)
            localHeading.frame = NSRect(x: 0, y: rowHeight + 30, width: bounds.width, height: 18)
            local.frame = NSRect(x: 0, y: rowHeight + 52, width: bounds.width, height: rowHeight)
            if presentation == .phone {
                phoneFooter.frame = NSRect(x: 0, y: bounds.height - PhoneSubtitleFooterView.height,
                                           width: bounds.width, height: PhoneSubtitleFooterView.height)
                phoneFooter.layoutSubtreeIfNeeded()
            }
        }
        let targetSize = max(14, fontSize * bounds.width / (video ? 960 : 760))
        func attributed(_ value: String, source: Bool) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = video ? .center : .left
            paragraph.paragraphSpacing = 10
            return NSAttributedString(string: value, attributes: [
                .font: NSFont.systemFont(ofSize: source ? max(11, targetSize * 0.7) : targetSize),
                .foregroundColor: source ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        }
        if presentation == .phone {
            remote.setText(
                source: attributed("Hello, I'm calling to confirm your appointment. Would Tuesday at ten in the morning work for you?\n\nPlease bring your booking confirmation. If you need to change the time, you can call us on this number.", source: true),
                translation: attributed(String(localized: "您好，我打电话来确认您的预约。周二上午十点方便吗？\n\n请带上预约确认单。如果需要改时间，可以拨打这个号码联系我们。"), source: false))
            local.setText(
                source: attributed(String(localized: "周二上午十点可以，谢谢。请再告诉我一下具体地址。\n\n我会带上预约确认单，到达后在前台登记。"), source: true),
                translation: attributed("Tuesday at ten works for me, thank you. Could you give me the address again?\n\nI'll bring the booking confirmation and check in at reception when I arrive.", source: false))
        } else {
            remote.setText(
                source: attributed("Let's review the plan for next week. First, we need to confirm the meeting time and agree on the budget. Then we can assign the remaining tasks and prepare the presentation.\n\nPlease keep the original wording available so everyone can check the details. A longer source sentence should never hide its translation.\n\nFinally, let's confirm the next meeting time.", source: true),
                translation: attributed(String(localized: "我们来看看下周的计划。先确认会议时间和预算，再分配任务、准备演示。\n\n请保留原文，方便核对细节。长原文也不会挡住译文。\n\n最后，确认下次会议时间。"), source: false))
            local.setText(
                source: attributed(String(localized: "我建议先完成产品演示，再核对预算。我们可以把需要讨论的问题列出来，逐项确认负责人和时间。\n\n如果原文比较长，可以在左边滚动查看；右边的译文仍然保持可见。\n\n最后一项：确认下次会议时间。"), source: true),
                translation: attributed("I suggest finishing the product demo first, then reviewing the budget. We can list the open questions and agree on an owner and deadline for each one.\n\nA long original can scroll on the left while the translation remains visible on the right.\n\nFinally, let's confirm the next meeting time.", source: false))
        }
    }
}
