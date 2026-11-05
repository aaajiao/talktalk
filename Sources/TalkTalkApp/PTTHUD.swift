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
    private var expandedDetails: Set<String> = []
    var onOpenSettings: ((HUDLine.SettingsDestination) -> Void)?
    private let stack = NSStackView()
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
        panel.onAppearanceChange = { [weak self] in
            guard let self else { return }
            render(displayLines(now: clock()), force: true)
        }
        panel.onHintChange = { [weak self] message in
            guard let self else { return }
            subtitleIssue = message.map {
                HUDLine(String(localized: "字幕需要检查"), .yellow, detail: $0, symbol: "captions.bubble")
            }
            render(displayLines(now: clock()), force: true)
        }
    }

    // MARK: inputs

    func meetingStarted() { change { $0.meetingStarted() } }

    func meetingEnded() {
        listenHint = nil
        subtitleIssue = nil
        cloudReminder = nil
        expandedDetails.removeAll()
        change { $0.meetingEnded() }
        render(displayLines(now: clock()), force: true)
    }

    func showCloudReminder(useApple: @escaping () -> Void, copyNotice: @escaping () -> Void) {
        cloudReminder = (useApple, copyNotice)
        render(displayLines(now: clock()), force: true)
    }

    private func closeCloudReminder() {
        cloudReminder = nil
        render(displayLines(now: clock()), force: true)
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
        listenHint = hint.map(Self.warning)
        applyListenHint()
    }

    func setSubtitlesVisible(_ on: Bool) {
        subtitlesVisible = on
        applyListenHint()
        render(displayLines(now: clock()), force: true)
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

    private func displayLines(now: Double) -> [HUDLine] {
        var presentation = model
        if presentation.meetingAudio == .original { presentation.pushToTalk = .idle }
        else if !subtitlesVisible, case let .holding(level, _, _, queued) = presentation.pushToTalk {
            presentation.pushToTalk = .holding(level: level, preview: "", committed: [], queued: queued)
        }
        var lines = presentation.lines(now: now)
        if let subtitleIssue { lines.append(subtitleIssue) }
        if let o = oneOff, o.until > now { lines.append(o.line) }
        return lines
    }

    private func redraw() {
        let now = clock()
        limiter.didRender(now: now)
        model.expireTranscript(at: now, reading: panel.speechIsVisible && panel.frame.contains(NSEvent.mouseLocation))
        if let o = oneOff, o.until <= now { oneOff = nil }
        render(displayLines(now: now))
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
        expandedDetails.formIntersection(lines.compactMap { line in
            line.detail.map { line.text + "\n" + $0 }
        })
        let candidate = model.visibleTranscript(at: clock())
        let transcript = !subtitlesVisible || (model.meetingAudio == .original && candidate?.isFinal == false) ? nil : candidate
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
        guard !lines.isEmpty || cloudReminder != nil || transcript != nil else {
            panel.setSpeechContent(content, height: 0)
            return
        }
        var height: CGFloat = 12
        for line in lines {
            let row = makeRow(line)
            stack.addArrangedSubview(row.view); height += row.height + stack.spacing
        }
        if let destination = lines.compactMap(\.settingsDestination).first, let onOpenSettings {
            let title = switch destination {
            case .audio: String(localized: "音频设置")
            case .translation: String(localized: "翻译设置")
            case .permissions: String(localized: "权限设置")
            }
            let target = HUDButtonAction { onOpenSettings(destination) }
            reminderActions.append(target)
            let button = NSButton(title: title, target: target, action: #selector(HUDButtonAction.run))
            button.bezelStyle = .rounded; button.controlSize = .small
            button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            stack.addArrangedSubview(button); height += Self.rowHeight + stack.spacing
        }
        if let transcript {
            let view = makeTranscript(transcript, oldOffset: oldOffset, followTail: followTail)
            transcriptScroll = view
            stack.addArrangedSubview(view); height += view.frame.height + stack.spacing
        }
        if let reminder = cloudReminder {
            let notice = HUDLine(String(localized: "云端翻译已开启：会议文字会发送给 OpenAI。"), .yellow)
            let noticeRow = makeRow(notice)
            stack.addArrangedSubview(noticeRow.view); height += noticeRow.height + stack.spacing
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
        let size = NSSize(width: width, height: max(12, height - stack.spacing))
        content.frame = NSRect(origin: .zero, size: size)
        let hasPress = model.meetingActive && model.pushToTalkAvailable && model.meetingAudio != .original && model.pushToTalk != .idle
        panel.setSpeechContent(content, height: size.height, hasLocalSpeech: transcript != nil || hasPress)
    }

    private func makeRow(_ line: HUDLine) -> (view: NSView, height: CGFloat) {
        let font = NSFont.systemFont(ofSize: 14, weight: line.style == .red || line.style == .redBanner ? .semibold : .regular)
        let color: NSColor = switch line.style {
        case .normal: .labelColor
        case .secondary: .secondaryLabelColor
        case .check: .systemGreen
        case .yellow: .systemOrange
        case .red, .redBanner: .systemRed
        }
        let fallbackSymbol: String = switch line.style {
        case .normal: "waveform"
        case .secondary: "info.circle"
        case .check: "checkmark.circle"
        case .yellow: "exclamationmark.triangle"
        case .red, .redBanner: "exclamationmark.octagon"
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: line.symbol ?? fallbackSymbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let textWidth = max(100, width - 24 - 26 - (line.level == nil ? 0 : 128) - (line.detail == nil ? 0 : 80))
        let label = ConversationLabel(wrappingLabelWithString: line.text)
        label.font = font; label.textColor = color
        label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = textWidth
        let bounds = (line.text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        var height = max(Self.rowHeight, ceil(bounds.height) + 4)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        if let level = line.level {
            let meter = NSLevelIndicator()
            meter.levelIndicatorStyle = .continuousCapacity
            meter.minValue = 0; meter.maxValue = 1
            meter.doubleValue = Double(max(0, min(1, level)))
            meter.widthAnchor.constraint(equalToConstant: 120).isActive = true
            row.addArrangedSubview(meter)
        }
        let group = NSStackView(views: [row])
        group.orientation = .vertical; group.alignment = .leading; group.spacing = 4
        if let detail = line.detail {
            let key = line.text + "\n" + detail
            let expanded = expandedDetails.contains(key)
            let action = HUDButtonAction { [weak self] in
                guard let self else { return }
                if expanded { expandedDetails.remove(key) } else { expandedDetails.insert(key) }
                render(displayLines(now: clock()), force: true)
            }
            reminderActions.append(action)
            let button = NSButton(title: expanded ? String(localized: "收起详情") : String(localized: "详情"),
                                  target: action, action: #selector(HUDButtonAction.run))
            button.bezelStyle = .rounded; button.controlSize = .small
            button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            row.addArrangedSubview(button)
            if expanded {
                let detailLabel = ConversationLabel(wrappingLabelWithString: detail)
                let detailFont = NSFont.systemFont(ofSize: 13)
                detailLabel.font = detailFont; detailLabel.textColor = .secondaryLabelColor
                detailLabel.maximumNumberOfLines = 0; detailLabel.lineBreakMode = .byWordWrapping
                detailLabel.preferredMaxLayoutWidth = width - 24
                let detailBounds = (detail as NSString).boundingRect(
                    with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: detailFont])
                let detailHeight = ceil(detailBounds.height) + 4
                detailLabel.heightAnchor.constraint(equalToConstant: detailHeight).isActive = true
                group.addArrangedSubview(detailLabel)
                height += detailHeight + group.spacing
            }
        }
        group.heightAnchor.constraint(equalToConstant: height).isActive = true
        group.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
        return (group, height)
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
        line(value.isFinal ? String(localized: "本次发言 · 中文") : String(localized: "识别中 · 文字可能修订"),
             size: 12, color: .secondaryLabelColor, heading: true)
        line(value.source, size: max(11, max(14, panel.baseFontSize * 0.8) * panel.textScale), color: value.isFinal ? .labelColor : .secondaryLabelColor)
        if !value.target.isEmpty {
            line(String(localized: "译文"), size: 12, color: .secondaryLabelColor, heading: true)
            line(value.target, size: panel.fontSize, color: .labelColor)
        }
        if !value.unsubmittedSource.isEmpty {
            line(String(localized: "识别草稿（未提交翻译）"), size: 12, color: .systemOrange, heading: true)
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
    var isVisible: Bool { panel.speechIsVisible }
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
