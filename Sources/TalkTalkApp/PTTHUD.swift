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
    private let transcriptColumns = ConversationColumnsView()
    private var width: CGFloat { panel.contentWidth - 8 }
    var onOpenSettings: ((HUDLine.SettingsDestination) -> Void)?
    var phoneInputIsConfirmed: (() -> Bool)?
    var onPhoneSpeechModeChange: ((HUDModel.MeetingAudio?, Bool) -> Void)?
    private let statusRow = NSView()
    private let modeBadge = NSView()
    private let modeIcon = NSImageView()
    private let modeLabel = ConversationLabel(labelWithString: "")
    private let phoneActionLabel = ConversationLabel(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = ConversationLabel(labelWithString: "")
    private let detailsButton = NSButton()
    private let detailsPopover = NSPopover()
    private var statusAction: HUDButtonAction?
    private var shownStatus: HUDStatusPresentation?
    private var shownMode: HUDLine?
    private var shownPhonePresentation: PhoneSpeechPresentation?
    private var publishedPhoneMode: HUDModel.MeetingAudio?
    private var publishedPhoneInput = false
    private var subtitlesVisible = true
    private var listenHint: HUDModel.Warning?
    private var subtitleIssue: HUDLine?
    private var cloudReminder: (apple: () -> Void, copy: () -> Void)?
    private var reminderActions: [HUDButtonAction] = []
    private var shownTranscript: SpeakTranscript?
    private var shownSpeechArea = false
    /// Monotonic seconds; replaceable for a smoke run.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    init(panel: SubtitlePanel) {
        self.panel = panel
        statusRow.addSubview(modeBadge)
        modeBadge.addSubview(modeIcon)
        modeBadge.addSubview(modeLabel)
        modeBadge.wantsLayer = true
        modeBadge.layer?.cornerRadius = 5
        modeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        modeLabel.maximumNumberOfLines = 1
        modeLabel.cell?.isScrollable = false
        statusRow.addSubview(phoneActionLabel)
        phoneActionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        phoneActionLabel.maximumNumberOfLines = 1
        phoneActionLabel.lineBreakMode = .byTruncatingTail
        phoneActionLabel.isHidden = true
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
        let inputChanged = panel.presentation == .phone
            && (phoneInputIsConfirmed?() == true) != publishedPhoneInput
        guard model.meetingAudio != state || inputChanged else { return }
        if panel.presentation == .phone {
            // A stopped raw gate or lost Phone reader must not leave a green sending badge
            // behind the transcript's refresh limiter. Only mode/confirmation changes get this.
            model.meetingAudio = state
            redrawTimer?.invalidate(); redrawTimer = nil
            redraw()
        } else { change { $0.meetingAudio = state } }
    }

    /// SPEAK wires this on once push to talk works; until then no idle shortcut instruction.
    func setPushToTalkAvailable(_ on: Bool) {
        change { $0.pushToTalkAvailable = on }
    }

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
        model.expireTranscript(at: now, reading: panel.speechIsVisible
            && (transcriptColumns.isReadingHistory || panel.frame.contains(NSEvent.mouseLocation)))
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
        let audio = model.meetingActive ? model.meetingAudio : nil
        let phoneAudio = panel.presentation == .phone ? audio : nil
        let phoneInput = phoneAudio != nil && phoneInputIsConfirmed?() == true
        if phoneAudio != publishedPhoneMode || phoneInput != publishedPhoneInput {
            publishedPhoneMode = phoneAudio; publishedPhoneInput = phoneInput
            onPhoneSpeechModeChange?(phoneAudio, phoneInput)
        }
        let phonePresentation = phoneAudio?.phonePresentation(inputConfirmed: phoneInput)
        let mode = audio?.modeBadge
        let modeChanged = mode != shownMode || phonePresentation != shownPhonePresentation
        shownStatus = status
        shownLines = status.map { [$0.summary] } ?? []
        let summaryChanged = status?.summary != oldStatus?.summary
        let transcriptChanged = transcript != shownTranscript
        let showSpeech = subtitlesVisible && model.meetingActive && panel.presentation != .video
        guard force || summaryChanged || modeChanged || transcriptChanged || showSpeech != shownSpeechArea else { return }
        shownMode = mode
        shownPhonePresentation = phonePresentation
        shownSpeechArea = showSpeech

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        statusRow.isHidden = status == nil
        modeBadge.isHidden = mode == nil
        phoneActionLabel.isHidden = phonePresentation == nil
        let rowHeight: CGFloat = phonePresentation == nil ? Self.rowHeight : 72
        statusRow.frame.size = NSSize(width: width - 24, height: rowHeight)
        if let phonePresentation {
            renderPhoneStatus(phonePresentation, summary: status?.summary, audio: audio)
        } else {
        modeBadge.layer?.borderWidth = 0
        modeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        if let mode, force || modeChanged {
            let color = mode.style == .normal ? NSColor.controlAccentColor : Self.color(for: mode.style)
            modeLabel.stringValue = mode.text
            modeLabel.textColor = color
            modeBadge.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
            modeIcon.image = NSImage(systemSymbolName: mode.symbol ?? "waveform", accessibilityDescription: nil)
            modeIcon.contentTintColor = color
        }
        // Use typed mode hints only when the normal mode itself won. A warning keeps its full
        // short consequence here while the separate badge continues to identify the audio mode.
        let operationHint = status?.summary.style == .normal && status?.summary.text == audio?.text
            ? audio?.operationHint : nil
        if let line = status?.summary, force || summaryChanged || modeChanged {
            statusLabel.stringValue = operationHint ?? line.text
            statusLabel.toolTip = line.text
            statusLabel.font = .systemFont(ofSize: 14, weight: line.style == .red || line.style == .redBanner ? .semibold : .regular)
            statusLabel.textColor = Self.color(for: line.style)
            statusIcon.image = NSImage(systemSymbolName: line.symbol ?? Self.symbol(for: line.style), accessibilityDescription: nil)
            statusIcon.contentTintColor = Self.color(for: line.style)
        }
        statusRow.frame.size = NSSize(width: width - 24, height: Self.rowHeight)
        let badgeWidth: CGFloat = mode == nil ? 0 : 92
        modeBadge.frame = NSRect(x: 0, y: 1, width: badgeWidth, height: Self.rowHeight - 2)
        modeIcon.frame = NSRect(x: 5, y: 4, width: 14, height: 14)
        modeLabel.frame = NSRect(x: 23, y: 3, width: max(0, badgeWidth - 27), height: 16)
        let summaryStart = badgeWidth > 0 ? badgeWidth + 8 : 0
        statusIcon.isHidden = operationHint != nil
        statusIcon.frame = NSRect(x: summaryStart, y: 3, width: 18, height: 18)
        detailsButton.frame = NSRect(x: statusRow.bounds.width - 62, y: 0, width: 62, height: Self.rowHeight)
        let textStart = summaryStart + (statusIcon.isHidden ? 0 : 26)
        statusLabel.frame = NSRect(x: textStart, y: 3, width: max(0, detailsButton.frame.minX - 8 - textStart), height: 19)
        }

        if force || transcriptChanged {
            let newPress = transcript?.press != shownTranscript?.press
            shownTranscript = transcript
            let text = transcriptText(transcript)
            transcriptColumns.setText(source: text.source, translation: text.translation, resetScroll: newPress)
        }
        // The parent owns the row viewport. Each language scrolls directly in its own column;
        // there is no outer speech scroll view that can swallow wheel events or clip a column.
        panel.setSpeechContent(transcriptColumns, height: showSpeech ? 180 : 0, hasLocalSpeech: showSpeech)
        panel.setStatusContent(statusRow, height: status == nil ? 0 : rowHeight)
        if status == nil { detailsPopover.close() }
    }

    private func renderPhoneStatus(_ presentation: PhoneSpeechPresentation,
                                   summary: HUDLine?, audio: HUDModel.MeetingAudio?) {
        let color: NSColor = switch presentation.tone {
        case .original: .systemGreen
        case .translation: .systemBlue
        case .ready, .progress: .secondaryLabelColor
        case .unavailable: .systemOrange
        }
        modeLabel.stringValue = presentation.title
        modeLabel.font = .systemFont(ofSize: 14, weight: .bold)
        modeLabel.textColor = color
        modeBadge.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        modeBadge.layer?.borderWidth = 1
        modeBadge.layer?.borderColor = color.withAlphaComponent(0.45).cgColor
        modeIcon.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil)
        modeIcon.contentTintColor = color
        phoneActionLabel.stringValue = presentation.action
        phoneActionLabel.toolTip = presentation.action
        phoneActionLabel.textColor = .labelColor
        let warning = summary.flatMap { line in
            line.style == .normal && line.text == audio?.text ? nil : line
        }
        statusLabel.stringValue = warning?.text ?? presentation.detail
        statusLabel.toolTip = warning?.detail ?? warning?.text ?? presentation.detail
        statusLabel.font = .systemFont(ofSize: 12, weight: warning == nil ? .regular : .semibold)
        statusLabel.textColor = warning.map { Self.color(for: $0.style) } ?? .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusIcon.isHidden = warning == nil
        statusIcon.image = warning.flatMap { NSImage(systemSymbolName: $0.symbol ?? Self.symbol(for: $0.style), accessibilityDescription: nil) }
        statusIcon.contentTintColor = warning.map { Self.color(for: $0.style) }
        modeBadge.frame = NSRect(x: 0, y: 38, width: 176, height: 30)
        modeIcon.frame = NSRect(x: 8, y: 6, width: 18, height: 18)
        modeLabel.frame = NSRect(x: 32, y: 5, width: 138, height: 20)
        phoneActionLabel.frame = NSRect(x: 188, y: 44, width: max(0, statusRow.bounds.width - 188), height: 20)
        detailsButton.frame = NSRect(x: statusRow.bounds.width - 62, y: 6, width: 62, height: 24)
        statusIcon.frame = NSRect(x: 0, y: 12, width: 18, height: 18)
        let textStart: CGFloat = warning == nil ? 0 : 26
        statusLabel.frame = NSRect(x: textStart, y: 4, width: max(0, detailsButton.frame.minX - 8 - textStart), height: 30)
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

    private func transcriptText(_ value: SpeakTranscript?) -> (source: NSAttributedString, translation: NSAttributedString) {
        guard let value else { return (NSAttributedString(string: ""), NSAttributedString(string: "")) }
        let source = NSMutableAttributedString(string: "")
        func append(_ text: String, size: CGFloat, color: NSColor) {
            guard !text.isEmpty else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.paragraphSpacing = 10
            source.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph
            ]))
        }
        append(value.source, size: max(11, max(14, panel.baseFontSize * 0.8) * panel.textScale), color: .secondaryLabelColor)
        if !value.unsubmittedSource.isEmpty {
            append(String(localized: "未发送草稿"), size: 12, color: .systemOrange)
            append(value.unsubmittedSource, size: max(11, max(14, panel.baseFontSize * 0.75) * panel.textScale), color: .secondaryLabelColor)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let translation = NSAttributedString(string: value.target, attributes: [
            .font: NSFont.systemFont(ofSize: panel.fontSize), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        return (source, translation)
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
