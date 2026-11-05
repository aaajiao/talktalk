// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSession

/// The local speech section of the shared conversation panel. Its state and refresh cadence
/// remain independent of remote subtitles, but it never creates another floating window.
@MainActor
final class PTTHUD {
    static let rowHeight: CGFloat = 24

    private(set) var model = HUDModel()
    private var limiter = RefreshLimiter()
    private var redrawTimer: Timer?
    private var expiryTimer: Timer?
    private let panel: SubtitlePanel
    private let content = ConversationContentView()
    private var width: CGFloat { panel.contentWidth - 8 }
    var onOpenSettings: ((HUDLine.SettingsDestination) -> Void)?
    private let statusRow = NSView()
    private let statusIcon = NSImageView()
    private let statusLabel = ConversationLabel(labelWithString: "")
    private let detailsButton = NSButton()
    private let detailsPopover = NSPopover()
    private var statusAction: HUDButtonAction?
    private var shownStatus: HUDStatusPresentation?
    private var subtitlesVisible = true
    private var listenHint: HUDModel.Warning?
    private var subtitleIssue: HUDLine?
    private var cloudReminder: (apple: () -> Void, copy: () -> Void)?
    private var reminderActions: [HUDButtonAction] = []
    private var shownTranscript: SpeakTranscript?
    private var transcriptScroll: NSScrollView?
    /// Monotonic seconds; replaceable for a smoke run.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    init(panel: SubtitlePanel) {
        self.panel = panel
        statusRow.addSubview(statusIcon)
        statusRow.addSubview(statusLabel)
        statusRow.addSubview(detailsButton)
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.isScrollable = false
        detailsButton.title = String(localized: "详情")
        detailsButton.bezelStyle = .rounded
        detailsButton.controlSize = .small
        detailsButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        detailsButton.imagePosition = .imageLeading
        detailsButton.setAccessibilityLabel(String(localized: "查看状态详情"))
        statusAction = HUDButtonAction { [weak self] in self?.toggleDetails() }
        detailsButton.target = statusAction
        detailsButton.action = #selector(HUDButtonAction.run)
        detailsPopover.behavior = .transient
        detailsPopover.animates = false
        panel.onAppearanceChange = { [weak self] in
            guard let self else { return }
            render(force: true)
        }
        panel.onHintChange = { [weak self] message in
            guard let self else { return }
            let next = message.map {
                HUDLine(String(localized: "字幕需要检查"), .yellow, detail: $0, symbol: "captions.bubble")
            }
            guard subtitleIssue != next else { return }
            subtitleIssue = next
            requestRedraw()
        }
    }

    // MARK: inputs

    func meetingStarted() { change { $0.meetingStarted() } }

    func meetingEnded() {
        listenHint = nil
        subtitleIssue = nil
        cloudReminder = nil
        detailsPopover.close()
        change { $0.meetingEnded() }
        render()
    }

    func showCloudReminder(useApple: @escaping () -> Void, copyNotice: @escaping () -> Void) {
        cloudReminder = (useApple, copyNotice)
        render()
    }

    private func closeCloudReminder() {
        cloudReminder = nil
        detailsPopover.close()
        render()
    }

    func post(_ w: HUDModel.Warning) {
        let now = clock()
        change { $0.post(w, now: now) }
    }

    func clear(_ w: HUDModel.Warning) { change { $0.clear(w) } }

    func pushToTalk(_ p: HUDModel.PushToTalk) { change { $0.pushToTalk = p } }

    func transcript(_ value: SpeakTranscript) {
        // Raw-original capture must not surface a new recognition draft. A completed earlier
        // press still follows its existing reading lifetime after raw audio resumes.
        guard model.meetingAudio != .original || value.isFinal else { return }
        let now = clock()
        change { $0.receiveTranscript(value, now: now) }
    }

    func setSpeechWorkPending(_ busy: Bool) {
        guard model.speechWorkPending != busy else { return }
        let now = clock()
        change { $0.speechWorkPending = busy; $0.refreshTranscriptLifetime(now: now) }
    }

    /// The controller calls this from actual raw-gate / translation-tail state changes. A
    /// failed translation press keeps raw closed; it must report unavailable, not original.
    func meetingAudio(_ state: HUDModel.MeetingAudio?) {
        guard model.meetingAudio != state else { return }
        change { $0.meetingAudio = state }
    }

    /// SPEAK wires this on once push to talk works; until then no idle shortcut instruction.
    func setPushToTalkAvailable(_ on: Bool) { change { $0.pushToTalkAvailable = on } }

    func passthrough(_ e: HUDModel.PassthroughEvent) {
        let now = clock()
        change { $0.passthrough(e, now: now) }
    }

    /// LISTEN hints belong to the shared status section, never in the remote original text.
    func listen(_ hint: MeetingSession.Hint?) {
        let next = hint.map(Self.warning)
        guard listenHint != next else { return }
        listenHint = next
        applyListenHint()
    }

    func setSubtitlesVisible(_ on: Bool) {
        subtitlesVisible = on
        applyListenHint()
        render()
    }

    /// SystemInputSwitcher's one-shot notices (§8.6).
    func sysInput(_ n: SystemInputSwitcher.Notice) {
        switch n {
        case let .switchedBackAfterInsert(d): post(.switchedBackAfterInsert(device: d))
        case let .manualChange(d): post(.defaultInputChanged(to: d))
        case let .restored(d, note): post(Self.restored(d, note))
        case let .invariantRestored(d): post(.defaultInputRestored(to: d))
        case .switchedBackAfterMicReturned, .entryNote: break
        case let .switchBackFailed(d): post(.switchBackFailed(current: d))
        case .noRestoreTarget:
            if let m = SysInputDialogPlan.message(.noRestoreTarget) { show(m.text, m.style) }
        }
    }

    /// "默认输入已还原为 X", with the §8.6 note when it was not the original.
    static func restored(_ d: String, _ note: SystemInputPlan.RestoreTarget.Notice?) -> HUDModel.Warning {
        switch note {
        case nil: .defaultInputRestored(to: d)
        case let .originalWasVirtual(o)?: .defaultInputRestoredElsewhere(to: d, original: o, originalMissing: false)
        case let .originalMissing(o)?: .defaultInputRestoredElsewhere(to: d, original: o, originalMissing: true)
        }
    }

    /// `enterMeetingMode` / `switchBackToMic` results (§8.6): yellow when the default input was
    /// not switched.
    func sysInputEntry(_ r: SystemInputSwitcher.EntryResult) {
        if let issue = Self.entryIssue(r) { post(.defaultInputNotSwitched(issue)) }
    }

    static func entryIssue(_ r: SystemInputSwitcher.EntryResult) -> SysInputDialogPlan.EntryIssue? {
        switch r {
        case .micMissing: .micMissing
        case .noPhysicalInput: .noPhysicalInput
        case .writeFailed: .writeFailed
        case .recordWriteFailed: .recordWriteFailed
        case .guardLaunchFailed: .guardLaunchFailed
        case .micNotSelectable: .micNotSelectable
        // No default: a new EntryResult case must be decided here. The menu says
        // .otherInstanceManages.
        case .switched, .unchanged, .otherInstanceManages: nil
        }
    }

    static func warning(_ h: MeetingSession.Hint) -> HUDModel.Warning {
        switch h {
        case .meetingSilent: .meetingSilent
        case .audioRestarting: .audioRestarting
        case .meetingSeemsOver: .meetingSeemsOver
        case .tccUnconfirmed: .tccUnconfirmed
        }
    }

    private func applyListenHint() {
        for w in [HUDModel.Warning.meetingSilent, .audioRestarting, .meetingSeemsOver, .tccUnconfirmed] {
            model.clear(w)
        }
        if let w = listenHint { model.post(w, now: clock()) }
        requestRedraw()
    }

    /// A line outside the §11 table (SysInputDialogPlan.message: restore failed, no restore
    /// target, waiting for the call): shown for `noticeSeconds`.
    private var oneOff: (line: HUDLine, until: Double)?
    func show(_ text: String, _ style: HUDLine.Style) {
        let line = text.count > 100 || text.contains("\n")
            ? HUDLine(String(localized: "查看提示详情"), style, detail: text)
            : HUDLine(text, style)
        oneOff = (line, clock() + HUDModel.noticeSeconds)
        requestRedraw()
    }

    // MARK: drawing

    private func change(_ f: (inout HUDModel) -> Void) {
        f(&model)
        requestRedraw()
    }

    private func requestRedraw() {
        let now = clock()
        // A newly relevant failure must not wait behind ordinary transcript refreshes.
        if let summary = displayStatus(now: now)?.summary, summary != shownStatus?.summary,
           summary.style == .yellow || summary.style == .red || summary.style == .redBanner {
            redrawTimer?.invalidate(); redrawTimer = nil
            redraw()
            return
        }
        switch limiter.request(now: now) {
        case .now:
            redraw()
        case let .at(t):
            redrawTimer?.invalidate()
            redrawTimer = Self.commonModeTimer(after: max(0, t - now)) { [weak self] in self?.redraw() }
        case .merged:
            break
        }
    }

    private func displayStatus(now: Double) -> HUDStatusPresentation? {
        var presentation = model
        if presentation.meetingAudio == .original { presentation.pushToTalk = .idle }
        else if !subtitlesVisible, case let .holding(level, _, _, queued) = presentation.pushToTalk {
            presentation.pushToTalk = .holding(level: level, preview: "", committed: [], queued: queued)
        }
        var lines: [HUDLine] = []
        if let subtitleIssue { lines.append(subtitleIssue) }
        if let o = oneOff, o.until > now { lines.append(o.line) }
        if cloudReminder != nil {
            lines.append(HUDLine(String(localized: "云端翻译已开启"), .yellow,
                                 detail: String(localized: "会议文字会发送给 OpenAI。"), symbol: "network"))
        }
        return presentation.compactStatus(now: now, extraLines: lines)
    }

    private func redraw() {
        let now = clock()
        limiter.didRender(now: now)
        model.expireTranscript(at: now, reading: panel.speechIsVisible && panel.frame.contains(NSEvent.mouseLocation))
        if let o = oneOff, o.until <= now { oneOff = nil }
        render()
        scheduleExpiry(now: now)
    }

    private func scheduleExpiry(now: Double) {
        expiryTimer?.invalidate()
        var next = model.nextExpiry(after: now)
        if let o = oneOff, o.until > now { next = min(next ?? o.until, o.until) }
        guard let next else { return }
        expiryTimer = Self.commonModeTimer(after: max(0.01, next - now)) { [weak self] in self?.requestRedraw() }
    }

    /// Runs in the common modes, so the HUD keeps updating while a modal alert or a menu is open.
    private static func commonModeTimer(after s: TimeInterval, _ f: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: s, repeats: false) { _ in MainActor.assumeIsolated { f() } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private(set) var shownLines: [HUDLine] = []

    /// Keep the status strip and transcript independent. Meter ticks and queue changes must
    /// never reconstruct a reading view or reset its scroll position.
    private func render(force: Bool = false) {
        let now = clock()
        let status = displayStatus(now: now)
        let candidate = model.visibleTranscript(at: now)
        let transcript = !subtitlesVisible || (model.meetingAudio == .original && candidate?.isFinal == false) ? nil : candidate
        let oldStatus = shownStatus
        shownStatus = status
        shownLines = status.map { [$0.summary] } ?? []
        let summaryChanged = status?.summary != oldStatus?.summary
        let transcriptChanged = transcript != shownTranscript
        guard force || summaryChanged || transcriptChanged else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        statusRow.isHidden = status == nil
        if let line = status?.summary, force || summaryChanged {
            statusLabel.stringValue = line.text
            statusLabel.toolTip = line.text
            statusLabel.font = .systemFont(ofSize: 14, weight: line.style == .red || line.style == .redBanner ? .semibold : .regular)
            statusLabel.textColor = Self.color(for: line.style)
            statusIcon.image = NSImage(systemSymbolName: line.symbol ?? Self.symbol(for: line.style), accessibilityDescription: nil)
            statusIcon.contentTintColor = Self.color(for: line.style)
        }
        statusRow.frame.size = NSSize(width: width - 24, height: Self.rowHeight)
        statusIcon.frame = NSRect(x: 0, y: 3, width: 18, height: 18)
        detailsButton.frame = NSRect(x: statusRow.bounds.width - 62, y: 0, width: 62, height: Self.rowHeight)
        statusLabel.frame = NSRect(x: 26, y: 3, width: max(80, statusRow.bounds.width - 96), height: 19)

        if force || transcriptChanged {
            let samePress = transcript?.press == shownTranscript?.press
            let oldOffset = samePress ? transcriptScroll?.contentView.bounds.origin.y ?? 0 : 0
            let followTail = samePress && (transcriptScroll.map { ($0.documentView?.bounds.height ?? 0) - $0.documentVisibleRect.maxY < 20 } ?? true)
            transcriptScroll?.removeFromSuperview()
            transcriptScroll = nil
            shownTranscript = transcript
            if let transcript {
                let view = makeTranscript(transcript, oldOffset: oldOffset, followTail: followTail)
                transcriptScroll = view
                content.addSubview(view)
            }
        }
        var height: CGFloat = 6
        if let transcriptScroll {
            transcriptScroll.frame.origin = NSPoint(x: 12, y: height)
            height += transcriptScroll.frame.height
        }
        height = transcript == nil ? 0 : height + 6
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.setSpeechContent(content, height: height, hasLocalSpeech: transcript != nil)
        panel.setStatusContent(statusRow, height: status == nil ? 0 : Self.rowHeight)
        if status == nil { detailsPopover.close() }
    }

    private static func color(for style: HUDLine.Style) -> NSColor {
        switch style {
        case .normal: .labelColor
        case .secondary: .secondaryLabelColor
        case .check: .systemGreen
        case .yellow: .systemOrange
        case .red, .redBanner: .systemRed
        }
    }

    private static func symbol(for style: HUDLine.Style) -> String {
        switch style {
        case .normal: "waveform"
        case .secondary: "info.circle"
        case .check: "checkmark.circle"
        case .yellow: "exclamationmark.triangle"
        case .red, .redBanner: "exclamationmark.octagon"
        }
    }

    /// Details are a snapshot opened deliberately, never a stream of rows inside the captions.
    /// The live one-line summary remains outside and continues to show current problems.
    private func toggleDetails() {
        if detailsPopover.isShown { detailsPopover.close(); return }
        guard let status = displayStatus(now: clock()) else { return }
        reminderActions.removeAll()
        let document = HUDDetailsView()
        let detailWidth: CGFloat = min(420, max(300, width - 48))
        var y: CGFloat = 14
        func text(_ value: String, font: NSFont, color: NSColor = .labelColor) {
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = font
            label.textColor = color
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = detailWidth - 32
            let bounds = (value as NSString).boundingRect(
                with: NSSize(width: detailWidth - 32, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let height = ceil(bounds.height) + 4
            label.frame = NSRect(x: 16, y: y, width: detailWidth - 32, height: height)
            document.addSubview(label)
            y += height + 8
        }
        func button(_ title: String, action: @escaping () -> Void) {
            let target = HUDButtonAction(action)
            reminderActions.append(target)
            let button = NSButton(title: title, target: target, action: #selector(HUDButtonAction.run))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.sizeToFit()
            button.frame = NSRect(x: 16, y: y, width: min(detailWidth - 32, button.frame.width + 8), height: 26)
            document.addSubview(button)
            y += 32
        }
        text(String(localized: "状态详情"), font: .systemFont(ofSize: 14, weight: .semibold))
        for line in status.details {
            text(line.detail ?? line.text, font: .systemFont(ofSize: 13), color: Self.color(for: line.style))
        }
        var destinations: [HUDLine.SettingsDestination] = []
        for destination in status.details.compactMap(\.settingsDestination) where !destinations.contains(destination) {
            destinations.append(destination)
        }
        if let onOpenSettings {
            for destination in destinations {
                let title = switch destination {
                case .audio: String(localized: "音频设置")
                case .translation: String(localized: "翻译设置")
                case .permissions: String(localized: "权限设置")
                }
                button(title) { [weak self] in self?.detailsPopover.close(); onOpenSettings(destination) }
            }
        }
        if let reminder = cloudReminder {
            button(String(localized: "本场只用 Apple 翻译听到的话")) { [weak self] in
                reminder.apple(); self?.closeCloudReminder()
            }
            button(String(localized: "复制聊天说明")) { reminder.copy() }
            button(String(localized: "知道了")) { [weak self] in self?.closeCloudReminder() }
        }
        document.frame = NSRect(x: 0, y: 0, width: detailWidth, height: y + 6)
        let viewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: detailWidth, height: min(360, y + 6)))
        viewport.drawsBackground = false
        viewport.hasVerticalScroller = y + 6 > 360
        viewport.autohidesScrollers = true
        viewport.documentView = document
        let controller = NSViewController()
        controller.view = viewport
        detailsPopover.contentViewController = controller
        detailsPopover.contentSize = viewport.frame.size
        detailsPopover.show(relativeTo: detailsButton.bounds, of: detailsButton, preferredEdge: .minY)
        // The explanation may contain local source text or device details, just like the pane.
        controller.view.window?.sharingType = .none
    }

    private func makeTranscript(_ value: SpeakTranscript, oldOffset: CGFloat, followTail: Bool) -> NSScrollView {
        let width = self.width - 24
        let document = ConversationContentView()
        var y: CGFloat = 8
        func line(_ text: String, size: CGFloat, color: NSColor, heading: Bool = false) {
            guard !text.isEmpty else { return }
            let label = ConversationLabel(wrappingLabelWithString: text)
            let font = NSFont.systemFont(ofSize: size, weight: heading ? .semibold : .regular)
            label.font = font; label.textColor = color
            label.maximumNumberOfLines = 0; label.lineBreakMode = .byWordWrapping
            label.preferredMaxLayoutWidth = width - 20
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: width - 20, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let height = ceil(bounds.height) + 5
            label.frame = NSRect(x: 0, y: y, width: width - 20, height: height)
            document.addSubview(label); y += height + (heading ? 2 : 10)
        }
        line(String(localized: "原文"), size: 12, color: .secondaryLabelColor, heading: true)
        line(value.source, size: max(11, max(14, panel.baseFontSize * 0.8) * panel.textScale), color: .secondaryLabelColor)
        if !value.target.isEmpty {
            line(String(localized: "译文"), size: 12, color: .secondaryLabelColor, heading: true)
            line(value.target, size: panel.fontSize, color: .labelColor)
        }
        if !value.unsubmittedSource.isEmpty {
            line(String(localized: "未发送草稿"), size: 12, color: .systemOrange, heading: true)
            line(value.unsubmittedSource, size: max(11, max(14, panel.baseFontSize * 0.75) * panel.textScale), color: .secondaryLabelColor)
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
        let cap = min(280, ((panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) * 0.35)
        let height = min(y, max(120, cap))
        let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = y > height
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: followTail ? max(0, y - height) : min(oldOffset, max(0, y - height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        return scroll
    }

    // smoke / tests
    var isVisible: Bool { panel.isWindowVisible && (shownStatus != nil || panel.speechIsVisible) }
    var sharingTypeIsNone: Bool { panel.sharingTypeIsNone }
    var clickThrough: Bool { panel.clickThrough }
    var windowNumber: Int { panel.windowNumber }
    #if TALKTALK_DEV
    func renderForSmoke() {
        redrawTimer?.invalidate(); redrawTimer = nil
        redraw()
    }
    var transcriptSourceForSmoke: String? { shownTranscript?.source }
    #endif
}

@MainActor
private final class HUDButtonAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

private final class HUDDetailsView: NSView {
    override var isFlipped: Bool { true }
}
