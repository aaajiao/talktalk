// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSession

/// The push-to-talk HUD (ARCHITECTURE.md §11): a non-activating panel on every
/// Space, above the subtitle panel, excluded from screen sharing. It draws `HUDModel.lines`,
/// at most twice a second (RefreshLimiter), without blur or animation, and is shown whenever it
/// has a line, also while the subtitle panel is hidden.
@MainActor
final class PTTHUD {
    static let width: CGFloat = 760
    static let rowHeight: CGFloat = 24

    private(set) var model = HUDModel()
    private var limiter = RefreshLimiter()
    private var redrawTimer: Timer?
    private var expiryTimer: Timer?
    private let panel: NSPanel
    private let stack = NSStackView()
    private var subtitlesVisible = true
    private var listenHint: HUDModel.Warning?
    private var cloudReminder: (apple: () -> Void, copy: () -> Void)?
    private var reminderActions: [HUDButtonAction] = []
    private var shownTranscript: SpeakTranscript?
    private var transcriptScroll: NSScrollView?
    /// Where the subtitle panel is (its frame); nil: its saved / default origin is used.
    var anchor: (() -> NSRect?)?
    /// Monotonic seconds; replaceable for a smoke run.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    init() {
        panel = SpeakHUDWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.title = "TalkTalk"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let content = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    // MARK: inputs

    func meetingStarted() { change { $0.meetingStarted() } }

    func meetingEnded() {
        listenHint = nil
        cloudReminder = nil
        change { $0.meetingEnded() }
        render(model.lines(now: clock()), force: true)
    }

    func showCloudReminder(useApple: @escaping () -> Void, copyNotice: @escaping () -> Void) {
        cloudReminder = (useApple, copyNotice)
        render(model.lines(now: clock()), force: true)
    }

    private func closeCloudReminder() {
        cloudReminder = nil
        render(model.lines(now: clock()), force: true)
    }

    func post(_ w: HUDModel.Warning) {
        let now = clock()
        change { $0.post(w, now: now) }
    }

    func clear(_ w: HUDModel.Warning) { change { $0.clear(w) } }

    func pushToTalk(_ p: HUDModel.PushToTalk) { change { $0.pushToTalk = p } }

    func transcript(_ value: SpeakTranscript) {
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

    /// LISTEN's MeetingSession.Hint. The subtitle panel shows it in its source line; the HUD
    /// shows it only while the subtitle panel is hidden, so it is visible exactly once.
    func listen(_ hint: MeetingSession.Hint?) {
        listenHint = hint.map(Self.warning)
        applyListenHint()
    }

    func setSubtitlesVisible(_ on: Bool) {
        subtitlesVisible = on
        applyListenHint()
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
        if let w = listenHint, !subtitlesVisible { model.post(w, now: clock()) }
        requestRedraw()
    }

    /// A line outside the §11 table (SysInputDialogPlan.message: restore failed, no restore
    /// target, waiting for the call): shown for `noticeSeconds`.
    private var oneOff: (line: HUDLine, until: Double)?
    func show(_ text: String, _ style: HUDLine.Style) {
        oneOff = (HUDLine(text, style), clock() + HUDModel.noticeSeconds)
        requestRedraw()
    }

    // MARK: drawing

    private func change(_ f: (inout HUDModel) -> Void) {
        f(&model)
        requestRedraw()
    }

    private func requestRedraw() {
        let now = clock()
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

    private func redraw() {
        let now = clock()
        limiter.didRender(now: now)
        model.expireTranscript(at: now, reading: panel.isVisible && panel.frame.contains(NSEvent.mouseLocation))
        var lines = model.lines(now: now)
        if let o = oneOff {
            if o.until > now { lines.append(o.line) } else { oneOff = nil }
        }
        render(lines)
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

    private func render(_ lines: [HUDLine], force: Bool = false) {
        let transcript = model.visibleTranscript(at: clock())
        guard force || lines != shownLines || transcript != shownTranscript else { return }
        let samePress = transcript?.press == shownTranscript?.press
        let oldOffset = samePress ? transcriptScroll?.contentView.bounds.origin.y ?? 0 : 0
        let followTail = samePress && (transcriptScroll.map { ($0.documentView?.bounds.height ?? 0) - $0.documentVisibleRect.maxY < 20 } ?? true)
        shownTranscript = transcript
        shownLines = lines
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        transcriptScroll = nil
        reminderActions.removeAll()
        panel.ignoresMouseEvents = cloudReminder == nil && transcript == nil
        panel.title = transcript == nil ? "TalkTalk" : String(localized: "我说的话")
        guard !lines.isEmpty || cloudReminder != nil || transcript != nil else { panel.orderOut(nil); return }
        var height: CGFloat = 12
        for line in lines {
            stack.addArrangedSubview(Self.row(line)); height += Self.height(for: line) + stack.spacing
        }
        if let transcript {
            let view = makeTranscript(transcript, oldOffset: oldOffset, followTail: followTail)
            transcriptScroll = view
            stack.addArrangedSubview(view); height += view.frame.height + stack.spacing
        }
        if let reminder = cloudReminder {
            let notice = HUDLine(String(localized: "云端翻译已开启：会议文字会发送给 OpenAI。"), .yellow)
            stack.addArrangedSubview(Self.row(notice)); height += Self.height(for: notice) + stack.spacing
            let actions: [(String, () -> Void)] = [
                (String(localized: "本场 LISTEN 只用 Apple"), { [weak self] in reminder.apple(); self?.closeCloudReminder() }),
                (String(localized: "复制聊天说明"), { reminder.copy() }),
                (String(localized: "知道了"), { [weak self] in self?.closeCloudReminder() }),
            ]
            let row = NSStackView()
            row.orientation = .horizontal; row.spacing = 10
            for (title, action) in actions {
                let target = HUDButtonAction(action)
                reminderActions.append(target)
                let button = NSButton(title: title, target: target, action: #selector(HUDButtonAction.run))
                button.bezelStyle = .rounded
                row.addArrangedSubview(button)
            }
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            stack.addArrangedSubview(row)
            height += Self.rowHeight + stack.spacing
        }
        let wasVisible = panel.isVisible
        panel.setContentSize(NSSize(width: Self.width, height: max(12, height - stack.spacing)))
        if wasVisible { keepOnScreen() } else { place() }
        panel.orderFrontRegardless()
    }

    private static func row(_ l: HUDLine) -> NSView {
        let label = NSTextField(wrappingLabelWithString: l.text)
        label.font = .systemFont(ofSize: 15, weight: l.style == .redBanner ? .semibold : .regular)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width - 24 - (l.level == nil ? 0 : 128)
        label.textColor = switch l.style {
        case .normal, .redBanner: .white
        case .secondary: NSColor(white: 0.62, alpha: 1)
        case .check: NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.55, alpha: 1)
        case .yellow: .systemOrange
        case .red: NSColor(calibratedRed: 1, green: 0.42, blue: 0.4, alpha: 1)
        }
        var views: [NSView] = [label]
        if let level = l.level {
            let meter = NSLevelIndicator()
            meter.levelIndicatorStyle = .continuousCapacity
            meter.minValue = 0
            meter.maxValue = 1
            meter.doubleValue = Double(max(0, min(1, level)))
            meter.widthAnchor.constraint(equalToConstant: 120).isActive = true
            views.append(meter)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: height(for: l)).isActive = true
        if l.style == .redBanner {
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.systemRed.cgColor
            row.layer?.cornerRadius = 4
            row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        }
        return row
    }

    private static func height(for line: HUDLine) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 15, weight: line.style == .redBanner ? .semibold : .regular)
        let bounds = (line.text as NSString).boundingRect(
            with: NSSize(width: width - 24 - (line.level == nil ? 0 : 128), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return max(rowHeight, ceil(bounds.height) + 4)
    }

    private func makeTranscript(_ value: SpeakTranscript, oldOffset: CGFloat, followTail: Bool) -> NSScrollView {
        let width = Self.width - 24
        let document = SpeakTranscriptDocument()
        var y: CGFloat = 8
        func line(_ text: String, size: CGFloat, color: NSColor, heading: Bool = false) {
            guard !text.isEmpty else { return }
            let label = NSTextField(wrappingLabelWithString: text)
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
        line(value.isFinal ? String(localized: "本次发言 · 中文") : String(localized: "识别中 · 文字可能修订"),
             size: 12, color: .secondaryLabelColor, heading: true)
        line(value.source, size: 18, color: value.isFinal ? .labelColor : .secondaryLabelColor)
        if !value.target.isEmpty {
            line(String(localized: "译文"), size: 12, color: .secondaryLabelColor, heading: true)
            line(value.target, size: 18, color: .labelColor)
        }
        if !value.unsubmittedSource.isEmpty {
            line(String(localized: "识别草稿（未提交翻译）"), size: 12, color: .systemOrange, heading: true)
            line(value.unsubmittedSource, size: 16, color: .secondaryLabelColor)
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
        let cap = min(280, ((panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) * 0.35)
        let height = min(y, max(120, cap))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = y > height
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: followTail ? max(0, y - height) : min(oldOffset, max(0, y - height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        return scroll
    }

    /// Just above the subtitle panel: its frame when known, else its saved origin on the main
    /// screen (SubtitlePanel's `ui.subtitleOrigin.<screen>`), else its default place.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let sub: NSRect = anchor?() ?? {
            let size = NSSize(width: 760, height: 132)
            let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if let s = UserDefaults.standard.string(forKey: "ui.subtitleOrigin.\(n?.stringValue ?? "main")") {
                let p = NSPointFromString(s)
                if screen.visibleFrame.insetBy(dx: -40, dy: -40).contains(p) { return NSRect(origin: p, size: size) }
            }
            let f = screen.visibleFrame
            return NSRect(x: f.midX - size.width / 2, y: f.minY + 80, width: size.width, height: size.height)
        }()
        var y = sub.maxY + 8
        let vis = screen.visibleFrame
        if y + panel.frame.height > vis.maxY { y = max(vis.minY, sub.minY - 8 - panel.frame.height) }
        panel.setFrameOrigin(NSPoint(x: sub.midX - Self.width / 2, y: y))
        keepOnScreen()
    }

    /// Preserve a user's drag across live transcript updates, but keep the changing panel in
    /// view. The initial position still follows the remote subtitle panel's anchor.
    private func keepOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame, frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
                                     y: min(max(frame.minY, visible.minY), visible.maxY - frame.height)))
    }

    // smoke / tests
    var isVisible: Bool { panel.isVisible }
    var sharingTypeIsNone: Bool { panel.sharingType == .none }
    var clickThrough: Bool { panel.ignoresMouseEvents }
}

private final class SpeakHUDWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class SpeakTranscriptDocument: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class HUDButtonAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
