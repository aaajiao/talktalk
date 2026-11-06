// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSession

/// The local speech section of the shared conversation panel. Its state and refresh cadence
/// remain independent of remote subtitles, but it never creates another floating window.
@MainActor
final class PTTHUD {
    static let rowHeight: CGFloat = 30

    private(set) var model = HUDModel()
    private var limiter = RefreshLimiter()
    private var redrawTimer: Timer?
    private var expiryTimer: Timer?
    private let panel: SubtitlePanel
    private let transcriptColumns = ConversationColumnsView()
    private var width: CGFloat { panel.contentWidth - 8 }
    var onOpenSettings: ((HUDLine.SettingsDestination) -> Void)?
    var onEndSession: (() -> Void)?
    var phoneInputIsConfirmed: (() -> Bool)?
    var onPhoneSpeechModeChange: ((HUDModel.MeetingAudio?, Bool, Bool) -> Void)?
    private let statusRow = NSView()
    private let modeBadge = NSView()
    private let modeIcon = NSImageView()
    private let modeLabel = ConversationLabel(labelWithString: "")
    private let shortcutLabel = ConversationLabel(labelWithString: "")
    private let shortcutKey = ConversationLabel(labelWithString: String(localized: "右⌥"))
    private let endButton = NSButton()
    private var endAction: HUDButtonAction?
    private let statusIcon = NSImageView()
    private let statusLabel = ConversationLabel(labelWithString: "")
    private let detailsButton = NSButton()
    private let detailsPopover = NSPopover()
    private var statusAction: HUDButtonAction?
    private var shownStatus: HUDStatusPresentation?
    private var shownMode: SpeechStatusPresentation?
    private var publishedPhoneMode: HUDModel.MeetingAudio?
    private var publishedPhoneInput = false
    private var publishedPhonePlaying = false
    private var outputPlaying = false
    private var subtitlesVisible = true
    private var listenHint: HUDModel.Warning?
    private var subtitleIssue: HUDLine?
    private var sceneIssue: HUDLine?
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
        statusRow.addSubview(shortcutLabel)
        statusRow.addSubview(shortcutKey)
        shortcutKey.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        shortcutKey.alignment = .center
        shortcutKey.textColor = .secondaryLabelColor
        shortcutKey.wantsLayer = true
        shortcutKey.layer?.cornerRadius = 4
        shortcutKey.layer?.borderWidth = 0.5
        shortcutKey.layer?.borderColor = NSColor.separatorColor.cgColor
        shortcutLabel.font = .systemFont(ofSize: 11, weight: .medium)
        shortcutLabel.maximumNumberOfLines = 1
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.isHidden = true
        statusRow.addSubview(statusIcon)
        statusRow.addSubview(statusLabel)
        statusRow.addSubview(endButton)
        endButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        endButton.imagePosition = .imageOnly
        endButton.isBordered = false
        endButton.contentTintColor = .secondaryLabelColor
        endAction = HUDButtonAction { [weak self] in self?.onEndSession?() }
        endButton.target = endAction
        endButton.action = #selector(HUDButtonAction.run)
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.isScrollable = false
        detailsButton.title = ""
        detailsButton.bezelStyle = .rounded
        detailsButton.controlSize = .small
        detailsButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        detailsButton.imagePosition = .imageOnly
        detailsButton.setAccessibilityLabel(String(localized: "状态与提示"))
        detailsButton.toolTip = String(localized: "状态与提示")
        statusAction = HUDButtonAction { [weak self] in self?.toggleDetails() }
        detailsButton.target = statusAction
        detailsButton.action = #selector(HUDButtonAction.run)
        panel.setDetailsAction(button: detailsButton)
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
        setTargetLanguage(.en)
    }

    // MARK: inputs

    func meetingStarted() { panel.prepareForNewSession(); change { $0.meetingStarted() } }

    func meetingEnded() {
        outputPlaying = false
        inputActivity(nil)
        listenHint = nil
        subtitleIssue = nil
        sceneIssue = nil
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

    /// Meter updates bypass the text/status limiter and never reconstruct a reading view.
    func inputActivity(_ level: Float?) {
        transcriptColumns.setInputActivity(subtitlesVisible && model.meetingActive
            && panel.presentation != .video ? level : nil)
    }

    func setTargetLanguage(_ language: Lang) {
        let title: String = switch language {
        case .zh: String(localized: "中文")
        case .en: String(localized: "英语")
        case .de: String(localized: "德语")
        }
        transcriptColumns.setHeadings(source: String(localized: "我 · 中文"), sourceSymbol: "mic", translation: title)
    }

    func transcript(_ value: SpeakTranscript) {
        let now = clock()
        change { $0.receiveTranscript(value, now: now) }
    }

    func setSpeechWorkPending(_ busy: Bool) {
        guard model.speechWorkPending != busy else { return }
        let now = clock()
        change { $0.speechWorkPending = busy; $0.refreshTranscriptLifetime(now: now) }
    }

    func setOutputPlaying(_ playing: Bool) {
        guard outputPlaying != playing else { return }
        outputPlaying = playing
        render()
    }

    func setSceneIssue(_ line: HUDLine?) {
        guard sceneIssue != line else { return }
        sceneIssue = line
        requestRedraw()
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
        if !on { inputActivity(nil) }
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
        else if case let .holding(_, _, _, queued) = presentation.pushToTalk {
            presentation.pushToTalk = .holding(level: 0, preview: "", committed: [], queued: queued)
        }
        var lines: [HUDLine] = []
        if let subtitleIssue { lines.append(subtitleIssue) }
        if let sceneIssue { lines.append(sceneIssue) }
        if let o = oneOff, o.until > now { lines.append(o.line) }
        if cloudReminder != nil {
            lines.append(HUDLine(String(localized: "云端翻译已开启"), .secondary,
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
        let playing = outputPlaying
        let phoneAudio = panel.presentation == .phone ? audio : nil
        let phoneInput = phoneAudio != nil && phoneInputIsConfirmed?() == true
        let phonePlaying = phoneAudio != nil && playing
        if phoneAudio != publishedPhoneMode || phoneInput != publishedPhoneInput || phonePlaying != publishedPhonePlaying {
            publishedPhoneMode = phoneAudio; publishedPhoneInput = phoneInput; publishedPhonePlaying = phonePlaying
            onPhoneSpeechModeChange?(phoneAudio, phoneInput, phonePlaying)
        }
        var mode = model.meetingActive ? SpeechStatusPresentation(audio: audio,
            phoneInputConfirmed: panel.presentation == .phone ? phoneInput : nil, playing: playing) : nil
        // Isolated practice has no original gate; it still reports its actual capture/output.
        if audio == nil, panel.presentation != .video, model.meetingActive {
            switch model.pushToTalk {
            case .holding: mode = SpeechStatusPresentation(audio: .translating)
            case .playing: mode = SpeechStatusPresentation(audio: .draining, playing: true)
            case .idle: break
            }
        }
        let outputVisible = subtitlesVisible && model.meetingActive && panel.presentation != .video
        transcriptColumns.setOutputActivity(
            symbol: !outputVisible ? nil : playing ? "speaker.wave.2.fill" : model.speechWorkPending ? "ellipsis.circle" : nil,
            label: !outputVisible ? nil : playing ? String(localized: "播放") : model.speechWorkPending ? String(localized: "处理") : nil)
        let modeChanged = mode != shownMode
        shownStatus = status
        shownLines = status.map { [$0.summary] } ?? []
        let statusChanged = status != oldStatus
        let transcriptChanged = transcript != shownTranscript
        let showSpeech = subtitlesVisible && model.meetingActive && panel.presentation != .video
        guard force || statusChanged || modeChanged || transcriptChanged || showSpeech != shownSpeechArea else { return }
        shownMode = mode
        shownSpeechArea = showSpeech

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        statusRow.isHidden = status == nil
        modeBadge.isHidden = mode == nil
        let rowWidth = max(0, width - 24)
        statusRow.frame.size = NSSize(width: rowWidth, height: Self.rowHeight)
        let modeWidth: CGFloat = mode == nil ? 0 : 110
        if let mode {
            let color = Self.color(for: mode.tone)
            modeLabel.stringValue = mode.title
            modeLabel.font = .systemFont(ofSize: 12, weight: .medium)
            modeLabel.textColor = color
            modeBadge.layer?.backgroundColor = NSColor.clear.cgColor
            modeBadge.toolTip = mode.detail
            modeIcon.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title)
            modeIcon.contentTintColor = color
        }
        modeBadge.frame = NSRect(x: 0, y: 3, width: modeWidth, height: 24)
        modeIcon.frame = NSRect(x: 6, y: 4, width: 16, height: 16)
        modeLabel.frame = NSRect(x: 28, y: 3, width: max(0, modeWidth - 32), height: 18)

        let notice = status.flatMap { $0.kind == .activity && mode != nil ? nil : $0.summary }
        detailsButton.isHidden = status == nil
        panel.setSessionActions(active: model.meetingActive)
        endButton.isHidden = !model.meetingActive
        endButton.frame = NSRect(x: rowWidth - 28, y: 1, width: 28, height: 28)
        let endTitle = panel.presentation == .video ? String(localized: "结束字幕") : String(localized: "结束同传")
        endButton.setAccessibilityLabel(endTitle)
        endButton.toolTip = endTitle
        let hasProblem = status?.kind == .problem || mode?.tone == .unavailable
        detailsButton.image = NSImage(systemSymbolName: hasProblem ? "exclamationmark.circle" : "info.circle", accessibilityDescription: nil)
        detailsButton.contentTintColor = hasProblem ? Self.color(for: status?.summary.style ?? .yellow) : .secondaryLabelColor
        detailsButton.toolTip = notice.map { String(localized: "状态与提示：\($0.text)") } ?? String(localized: "状态与提示")
        let shortcut = mode?.shortcut
        let shortcutWidth: CGFloat = shortcut == nil ? 0 : 118
        shortcutLabel.isHidden = shortcut == nil
        shortcutKey.isHidden = shortcut == nil
        shortcutLabel.stringValue = mode?.keyAction ?? ""
        shortcutLabel.setAccessibilityLabel(shortcut)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.toolTip = mode?.detail
        let actionsEnd = model.meetingActive ? endButton.frame.minX - 10 : rowWidth
        let shortcutStart = max(modeWidth, actionsEnd - shortcutWidth)
        shortcutKey.frame = NSRect(x: shortcutStart, y: 6, width: 34, height: 18)
        shortcutLabel.frame = NSRect(x: shortcutStart + 42, y: 6, width: shortcutWidth - 42, height: 18)
        statusLabel.isHidden = notice == nil
        statusIcon.isHidden = notice == nil
        if let notice {
            statusLabel.stringValue = notice.text
            statusLabel.toolTip = notice.text
            statusLabel.font = .systemFont(ofSize: 12, weight: hasProblem ? .medium : .regular)
            statusLabel.textColor = Self.color(for: notice.style)
            statusIcon.image = NSImage(systemSymbolName: notice.symbol ?? Self.symbol(for: notice.style), accessibilityDescription: nil)
            statusIcon.contentTintColor = Self.color(for: notice.style)
        }
        let noticeStart = modeWidth > 0 ? modeWidth + 10 : 0
        let noticeEnd = shortcut == nil ? actionsEnd : shortcutStart - 8
        statusIcon.frame = NSRect(x: noticeStart, y: 7, width: 16, height: 16)
        statusLabel.frame = NSRect(x: noticeStart + 22, y: 6, width: max(0, noticeEnd - noticeStart - 22), height: 18)
        // At the narrowest window, consequential text gets the space; the action remains
        // available through the mode tooltip and accessible shortcut label.
        if let notice, (notice.text as NSString).size(withAttributes: [.font: statusLabel.font!]).width > statusLabel.frame.width {
            shortcutLabel.isHidden = true
            shortcutKey.isHidden = true
            statusLabel.frame.size.width = max(0, actionsEnd - statusLabel.frame.minX)
        }

        if force || transcriptChanged {
            let newPress = transcript?.press != shownTranscript?.press
            shownTranscript = transcript
            let text = transcriptText(transcript)
            transcriptColumns.setText(source: text.source, translation: text.translation, resetScroll: newPress)
        }
        panel.setSpeechContent(transcriptColumns, height: showSpeech ? 180 : 0, hasLocalSpeech: showSpeech)
        panel.setStatusContent(statusRow, height: status == nil ? 0 : Self.rowHeight)
        if !showSpeech { inputActivity(nil) }
        if status == nil { detailsPopover.close() }
        else if detailsPopover.isShown, statusChanged || modeChanged { updateDetails() }
    }

    private static func color(for tone: PhoneSpeechPresentation.Tone) -> NSColor {
        switch tone {
        case .original: .systemGreen
        case .translation: .controlAccentColor
        case .ready, .progress: .secondaryLabelColor
        case .unavailable: .systemOrange
        }
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
        updateDetails()
        detailsPopover.show(relativeTo: detailsButton.bounds, of: detailsButton, preferredEdge: .minY)
        detailsPopover.contentViewController?.view.window?.sharingType = .none
    }

    private func updateDetails() {
        guard let status = displayStatus(now: clock()) else { return }
        let previousScroll = (detailsPopover.contentViewController?.view as? NSScrollView)?.contentView.bounds.origin.y ?? 0
        let focusedControl = (detailsPopover.contentViewController?.view.window?.firstResponder as? NSButton)?.identifier
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
            button.identifier = NSUserInterfaceItemIdentifier(title)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.sizeToFit()
            button.frame = NSRect(x: 16, y: y, width: min(detailWidth - 32, button.frame.width + 8), height: 26)
            document.addSubview(button)
            y += 32
        }
        text(String(localized: "状态与提示"), font: .systemFont(ofSize: 14, weight: .semibold))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                             target: nil, action: nil)
        close.isBordered = false
        close.identifier = NSUserInterfaceItemIdentifier("close-status-details")
        close.setAccessibilityLabel(String(localized: "关闭详情"))
        close.toolTip = String(localized: "关闭详情")
        close.keyEquivalent = "\u{1b}"
        let closeAction = HUDButtonAction { [weak self] in self?.detailsPopover.close() }
        reminderActions.append(closeAction)
        close.target = closeAction; close.action = #selector(HUDButtonAction.run)
        close.frame = NSRect(x: detailWidth - 40, y: 10, width: 24, height: 24)
        document.addSubview(close)
        if let mode = shownMode {
            text(mode.detail, font: .systemFont(ofSize: 13))
        }
        for line in status.details where line.text != model.meetingAudio?.text {
            text(line.detail ?? line.text, font: .systemFont(ofSize: 13), color: Self.color(for: line.style))
        }
        var destinations: [HUDLine.SettingsDestination] = []
        if shownMode?.tone == .unavailable { destinations.append(.audio) }
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
            button(String(localized: "本场不再提示")) { [weak self] in self?.closeCloudReminder() }
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
        viewport.tile()
        viewport.contentView.scroll(to: NSPoint(x: 0, y: min(previousScroll, max(0, document.frame.height - viewport.contentView.bounds.height))))
        viewport.reflectScrolledClipView(viewport.contentView)
        if let focusedControl, let button = document.subviews.first(where: { $0.identifier == focusedControl }) {
            controller.view.window?.makeFirstResponder(button)
        }
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
