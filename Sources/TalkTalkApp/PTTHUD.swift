// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSession

/// My side of the shared conversation panel. Its state and refresh cadence remain independent
/// of remote subtitles, but it never creates another floating window. The titlebar shows two
/// independent facts (redesign §3): the voice capsule (`voiceState`) and one issue slot
/// (`issueSlot`); neither replaces the other. The microphone dock (§4) reads the same voice
/// state; while I speak it shows my live turn, which then becomes a row of the timeline.
@MainActor
final class PTTHUD {
    private(set) var model = HUDModel()
    private var limiter = RefreshLimiter()
    private var redrawTimer: Timer?
    private var expiryTimer: Timer?
    private let panel: SubtitlePanel
    var onOpenSettings: ((HUDLine.SettingsDestination) -> Void)?
    var onEndSession: (() -> Void)?
    var phoneInputIsConfirmed: (() -> Bool)?
    /// The end button's popover text for the current scene; nil ends at once (video, demo).
    var endConfirmation: ((SubtitleScene) -> SessionEndConfirmation?)?
    /// The phone settings page shows the titlebar's own voice state, risk included (§7).
    var onPhoneVoiceChange: ((VoiceState?) -> Void)?
    /// The scenario page's running line dots the meeting's voice state, as the menu does.
    var onMeetingVoiceChange: ((VoiceState?) -> Void)?
    private let detailsPopover = NSPopover()
    private let endPopover = NSPopover()
    private var popoverActions: [HUDButtonAction] = []
    private var endActions: [HUDButtonAction] = []
    private var detailsAnchor: NSView?
    private var shownVoice: VoiceState?
    private var shownIssue: IssueSlot?
    private var shownKey: TitlebarKey?
    private var shownChips: [HUDChip] = []
    private var announcedGroup: Int?
    /// The first issue chip as last considered for VoiceOver.
    private var announcedChip: HUDChip?
    private var publishedPhoneVoice: VoiceState?
    private var publishedMeetingVoice: VoiceState?
    private var publishedPhoneInput = false
    private var subtitlesVisible = true
    private var listenHint: HUDModel.Warning?
    private var cloudReminder: (apple: () -> Void, copy: () -> Void)?
    private var cloudPopoverShown = false
    private var cloudPopoverScheduled = false
    /// Presses whose own translated audio is playing (SpeakUIEvent.outputPresses).
    private var playingPresses: Set<UInt64> = []
    /// The current press: shown in the dock while it is live, then committed as "我的行".
    private struct TurnTrack {
        var turn: ConversationTimeline.Turn
        var delivery = TurnDelivery()
        var committed: ConversationTimeline.Turn?
    }
    private var track: TurnTrack?
    private var speaking = SpeakingDockPhase()
    private var speakingTimer: Timer?
    private var shownDock: MicStatusDock.Content?
    private var shownLocalSpeech = false
    /// Monotonic seconds; replaceable for a smoke run.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    init(panel: SubtitlePanel) {
        self.panel = panel
        for popover in [detailsPopover, endPopover] {
            popover.behavior = .transient
            popover.animates = false
            popover.appearance = NSAppearance(named: .darkAqua)
        }
        let titlebar = panel.titlebar
        titlebar.onVoice = { [weak self] anchor in self?.toggleDetails(from: anchor) }
        titlebar.onIssue = { [weak self] anchor in self?.toggleDetails(from: anchor) }
        titlebar.onKey = { [weak self] anchor in self?.toggleDetails(from: anchor) }
        titlebar.onEnd = { [weak self] anchor in self?.endPressed(from: anchor) }
        panel.onAppearanceChange = { [weak self] in
            guard let self else { return }
            render(force: true)
        }
        panel.onDockAction = { [weak self] anchor in self?.toggleDetails(from: anchor) }
        panel.onStatusDotClick = { [weak self] anchor in self?.toggleDetails(from: anchor) }
        // Video captions more than 5 s behind: a warning chip in the hover bar, yellow dot (§6).
        panel.onVideoLagChange = { [weak self] lag in
            guard let self else { return }
            model.setExternalIssue(.videoLag, lag.map(VideoStatusDot.lagChip(seconds:)))
            requestRedraw()
        }
        panel.onPlaceholderClick = { [weak self] anchor in self?.toggleDetails(from: anchor) }
        panel.onTitlebarShown = { [weak self] in
            guard let self else { return }
            showCloudPopoverOnce(issue: model.issueSlot(now: clock()))
        }
        panel.onHintChange = { [weak self] message in
            guard let self else { return }
            let next = message.map {
                HUDChip(titlebarLabel("字幕需要检查"), symbol: "captions.bubble", tone: .warn, detail: $0)
            }
            model.setExternalIssue(.subtitles, next)
            requestRedraw()
        }
    }

    // MARK: inputs

    func meetingStarted() {
        panel.prepareForNewSession()
        announcedGroup = nil
        cloudPopoverShown = false
        playingPresses = []
        resetTurn()
        change { $0.meetingStarted() }
    }

    func meetingEnded() {
        inputActivity(nil)
        playingPresses = []
        resetTurn()
        listenHint = nil
        panel.setRemoteSilent(false)
        cloudReminder = nil
        detailsPopover.close()
        endPopover.close()
        change { $0.meetingEnded() }
        render()
    }

    func showCloudReminder(useApple: @escaping () -> Void, copyNotice: @escaping () -> Void) {
        cloudReminder = (useApple, copyNotice)
        model.cloudPrivacyPending = true
        render()
    }

    private func closeCloudReminder() {
        cloudReminder = nil
        model.cloudPrivacyPending = false
        detailsPopover.close()
        render()
    }

    func post(_ w: HUDModel.Warning) {
        let now = clock()
        change { $0.post(w, now: now) }
    }

    func clear(_ w: HUDModel.Warning) { change { $0.clear(w) } }

    func pushToTalk(_ p: HUDModel.PushToTalk) { change { $0.pushToTalk = p } }

    /// Meter updates bypass the text/status limiter and never reconstruct a reading view; only
    /// the dock curve redraws. nil means capture is closed or its last valid input is older than
    /// 250 ms, so the curve goes at once.
    func inputActivity(_ level: Float?) {
        guard let level, subtitlesVisible, model.meetingActive, panel.presentation != .video else {
            panel.stopInputLevel()
            return
        }
        panel.setInputLevel(level)
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
        guard model.outputPlaying != playing else { return }
        model.outputPlaying = playing
        render()
    }

    /// Which presses' audio is playing; a turn's delivery counts only its own playback.
    func setOutputPresses(_ presses: Set<UInt64>) {
        guard playingPresses != presses else { return }
        playingPresses = presses
        render()
    }

    /// A Phone operation failure (MeetingController). Its label is a titlebar short label.
    func setSceneIssue(_ chip: HUDChip?) {
        model.setExternalIssue(.scene, chip)
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
        panel.setRemoteSilent(next == .meetingSilent)
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
            if let m = SysInputDialogPlan.message(.noRestoreTarget) {
                show(m.text, m.style, label: titlebarLabel("系统麦克风未还原"))
            }
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

    /// A message outside the §11 table (SysInputDialogPlan.message: restore failed, no restore
    /// target, waiting for the call): the short `label` sits in the titlebar for
    /// `noticeSeconds`; the complete text is its detail, whatever its length.
    func show(_ text: String, _ style: HUDLine.Style, label: String) {
        let tone: HUDChip.Tone = switch style {
        case .red, .redBanner: .risk
        case .yellow: .warn
        case .normal, .secondary, .check: .notice
        }
        let symbol = tone == .notice ? "info.circle" : "exclamationmark.triangle"
        let chip = HUDChip(label, symbol: symbol, tone: tone, detail: text,
                           settingsDestination: tone == .notice ? nil : .audio)
        let now = clock()
        change { $0.show(chip, now: now) }
    }

    // MARK: drawing

    private func change(_ f: (inout HUDModel) -> Void) {
        f(&model)
        requestRedraw()
    }

    /// Facts the titlebar reads directly; synchronised before every presentation decision.
    private func syncFacts() {
        model.scene = panel.scene
        model.phoneInputConfirmed = panel.presentation == .phone && phoneInputIsConfirmed?() == true
    }

    private func requestRedraw() {
        let now = clock()
        syncFacts()
        // Speaking-mode changes and newly relevant problems never wait behind ordinary
        // transcript refreshes.
        let problem = model.issueSlot(now: now)?.chip.flatMap { $0.isProblem ? $0 : nil }
        if model.voiceState != shownVoice || (problem != nil && problem != shownIssue?.chip) {
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

    private func redraw() {
        let now = clock()
        limiter.didRender(now: now)
        // A finished turn is already a timeline row; the model's copy only feeds late results.
        model.expireTranscript(at: now)
        render()
        scheduleExpiry(now: now)
    }

    private func scheduleExpiry(now: Double) {
        expiryTimer?.invalidate()
        guard let next = model.nextExpiry(after: now) else { return }
        expiryTimer = Self.commonModeTimer(after: max(0.01, next - now)) { [weak self] in self?.requestRedraw() }
    }

    /// Runs in the common modes, so the HUD keeps updating while a modal alert or a menu is open.
    private static func commonModeTimer(after s: TimeInterval, _ f: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: s, repeats: false) { _ in MainActor.assumeIsolated { f() } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private(set) var shownLines: [HUDLine] = []

    /// Keep titlebar status, the dock and the timeline independent. Meter ticks and queue
    /// changes must never reconstruct a reading view or reset its scroll position.
    private func render(force: Bool = false) {
        syncFacts()
        let now = clock()
        let voice = model.voiceState
        let issue = model.issueSlot(now: now)
        let key = model.titlebarKey
        let chips = model.issueChips(now: now)
        let audio = model.meetingActive ? model.meetingAudio : nil
        let phoneAudio = panel.presentation == .phone ? audio : nil
        publishedPhoneInput = phoneAudio != nil && model.phoneInputConfirmed
        // The same value as the capsule, so a raw-audio risk reaches the settings page too.
        let phoneVoice = panel.presentation == .phone && model.meetingActive
            && (phoneAudio != nil || voice?.kind == .remoteHearsOriginal) ? voice : nil
        if phoneVoice != publishedPhoneVoice {
            publishedPhoneVoice = phoneVoice
            onPhoneVoiceChange?(phoneVoice)
        }
        let meetingVoice = panel.presentation == .meeting && model.meetingActive ? voice : nil
        if meetingVoice != publishedMeetingVoice {
            publishedMeetingVoice = meetingVoice
            onMeetingVoiceChange?(meetingVoice)
        }
        let showSpeech = subtitlesVisible && model.meetingActive && panel.presentation != .video
        let expanded = updateTurn(voice: voice, now: now)
        let dock = showSpeech ? dockContent(voice: voice, key: key, expanded: expanded) : nil
        let statusChanged = voice != shownVoice || issue != shownIssue || key != shownKey || chips != shownChips
        shownLines = (voice.map { [HUDLine($0.title)] } ?? []) + chips.map { HUDLine($0.label, detail: $0.detail) }
        let voiceAnnounced = announce(voice)
        announce(chips.first, voiceAnnounced: voiceAnnounced)
        guard force || statusChanged || dock != shownDock || showSpeech != shownLocalSpeech else { return }
        shownVoice = voice
        shownIssue = issue
        shownKey = key
        shownChips = chips
        shownDock = dock
        shownLocalSpeech = showSpeech

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        panel.setSessionActions(active: model.meetingActive)
        panel.setTitlebarStatus(voice: voice, issue: issue, key: key)
        panel.setLocalSpeechVisible(showSpeech)
        panel.setDock(dock)
        if !showSpeech { panel.stopInputLevel() }
        if voice == nil, issue == nil { detailsPopover.close(); endPopover.close() }
        else if detailsPopover.isShown, statusChanged { updateDetails() }
        if !model.meetingActive { endPopover.close() }
        showCloudPopoverOnce(issue: issue)
    }

    /// The dock (§4, §5): the same voice state as the capsule, the keycap, and my live turn
    /// while the dock is expanded.
    private func dockContent(voice: VoiceState?, key: TitlebarKey?, expanded: Bool) -> MicStatusDock.Content? {
        guard let voice else { return nil }
        let presentation = MicDockPresentation.make(voice, scene: panel.scene)
        let live = track.flatMap { $0.committed == nil ? $0.turn : nil }
        return MicStatusDock.Content(presentation: presentation, key: key, turn: expanded ? live : nil,
                                     expanded: expanded, showsStartHint: presentation.allowsStartHint && key != nil)
    }

    /// Follows my current press: the speaking phase (translation latch until pending work has
    /// ended plus 3 s), what was actually delivered, and the commit into the timeline. Returns
    /// whether the dock is expanded.
    private func updateTurn(voice: VoiceState?, now: Double) -> Bool {
        guard model.meetingActive, panel.presentation != .video else {
            resetTurn()
            return false
        }
        let wasExpanded = speaking.isExpanded
        let active = SpeakingDockPhase.isActive(audio: model.meetingAudio, pushToTalk: model.pushToTalk,
                                                workPending: model.speechWorkPending, expanded: wasExpanded)
        let expanded = speaking.update(active: active, now: now)
        scheduleSpeakingChange(now: now)
        // A new round of my own speech ends a frozen reading position at once.
        if expanded, !wasExpanded { panel.followLatest() }

        // Original mode hides drafts: a volatile turn it hides is discarded, never committed.
        let candidate = model.visibleTranscript(at: now)
        let transcript = model.meetingAudio == .original && candidate?.isFinal == false ? nil : candidate
        if let transcript {
            if track?.turn.press != transcript.press {
                if let previous = track, previous.committed == nil { commit(previous) }
                track = TurnTrack(turn: .init(transcript, startedAt: HostClock.now()))
                panel.followLatest()
            } else if let startedAt = track?.turn.startedAt {
                track?.turn = .init(transcript, startedAt: startedAt)
            }
        } else if let current = track, current.committed == nil {
            if current.turn.isFinal { commit(current) } else { track = nil }
        }
        guard var current = track else { return expanded }
        // Only this press's own playback counts, and only a live turn can be aborted.
        let ownPlayback = playingPresses.contains(current.turn.press)
        let live = !current.turn.isFinal || model.speechWorkPending || ownPlayback
        current.delivery.observe(voice: voice?.kind, playing: ownPlayback,
                                 hasTranslation: !current.turn.translation.isEmpty, live: live,
                                 isolated: model.meetingAudio == nil)
        track = current
        if current.committed != nil || !expanded {
            // Collapsed: the turn is a row. A late final or delivery change updates that row.
            commit(current)
        }
        return expanded
    }

    private func commit(_ value: TurnTrack) {
        var turn = value.turn
        turn.delivery = value.delivery.label(scene: panel.scene, hasTranslation: !turn.translation.isEmpty)
        guard value.committed != turn else { return }
        panel.commitMyTurn(turn)
        if track?.turn.press == value.turn.press { track?.committed = turn }
    }

    private func resetTurn() {
        track = nil
        speaking.reset()
        speakingTimer?.invalidate(); speakingTimer = nil
    }

    /// The 3 s linger ends by itself; nothing else may be pending then.
    private func scheduleSpeakingChange(now: Double) {
        speakingTimer?.invalidate(); speakingTimer = nil
        guard let next = speaking.nextChange else { return }
        speakingTimer = Self.commonModeTimer(after: max(0.01, next - now)) { [weak self] in self?.render() }
    }

    /// VoiceOver hears one short sentence when the speaking mode changes (§3).
    @discardableResult
    private func announce(_ voice: VoiceState?) -> Bool {
        guard let voice else { announcedGroup = nil; return false }
        let group = voice.announcementGroup
        defer { announcedGroup = group }
        guard let previous = announcedGroup, previous != group, let text = voice.announcement,
              panel.isWindowVisible else { return false }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        return true
    }

    /// A new first problem or notification chip is spoken once with its full sentence, so a
    /// 4-second notice is not lost to VoiceOver. Information chips stay silent; a risk chip or
    /// "Phone 未接收" that arrives with a capsule change the voice announcement already said.
    private func announce(_ chip: HUDChip?, voiceAnnounced: Bool) {
        let previous = announcedChip
        announcedChip = chip
        guard let chip, chip.tone != .info, panel.isWindowVisible,
              previous?.label != chip.label || previous?.detail != chip.detail else { return }
        if voiceAnnounced, chip.tone == .risk || chip == .phoneNotReceiving { return }
        let priority: NSAccessibilityPriorityLevel = switch chip.tone {
        case .risk: .high
        case .warn: .medium
        case .notice, .info: .low
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: chip.detail,
            .priority: priority.rawValue,
        ])
    }

    /// The cloud privacy note opens once per session as a transient popover; it never makes
    /// the panel key. In video the titlebar is hover-only: the note waits until the bar is
    /// shown (the panel calls back), and it counts as shown only once it actually appeared.
    private func showCloudPopoverOnce(issue: IssueSlot?) {
        guard cloudReminder != nil, !cloudPopoverShown, !cloudPopoverScheduled, model.meetingActive,
              !detailsPopover.isShown, let anchor = cloudPopoverAnchor(issue: issue) else { return }
        cloudPopoverScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            cloudPopoverScheduled = false
            guard cloudReminder != nil, !cloudPopoverShown, model.meetingActive, !detailsPopover.isShown,
                  cloudPopoverAnchor(issue: model.issueSlot(now: clock())) === anchor else { return }
            showDetails(from: anchor)
            cloudPopoverShown = detailsPopover.isShown
        }
    }

    private func cloudPopoverAnchor(issue: IssueSlot?) -> NSView? {
        guard panel.isWindowVisible, panel.titlebarIsShown else { return nil }
        let anchor: NSView = issue == .cloudPrivacy ? panel.titlebar.cloud : panel.titlebar.capsule
        guard !anchor.isHiddenOrHasHiddenAncestor, anchor.window != nil else { return nil }
        return anchor
    }

    // MARK: end

    private func endPressed(from anchor: NSView) {
        if endPopover.isShown { endPopover.close(); return }
        guard model.meetingActive, let confirmation = endConfirmation?(panel.scene) else {
            onEndSession?()
            return
        }
        detailsPopover.close()
        endActions.removeAll()
        let width = SubtitleTokens.Size.endConfirmationWidth
        let document = HUDDetailsView()
        var y: CGFloat = 16
        func label(_ value: String, font: NSFont, color: NSColor) {
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = font
            field.textColor = color
            let height = ceil((value as NSString).boundingRect(
                with: NSSize(width: width - 32, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 4
            field.frame = NSRect(x: 16, y: y, width: width - 32, height: height)
            document.addSubview(field)
            y += height + 6
        }
        label(confirmation.title, font: .systemFont(ofSize: 13, weight: .semibold), color: SubtitleStyle.white(0.92))
        label(confirmation.message, font: .systemFont(ofSize: 12), color: SubtitleStyle.white(0.72))
        y += 6
        let cancelAction = HUDButtonAction { [weak self] in self?.endPopover.close() }
        let confirmAction = HUDButtonAction { [weak self] in
            self?.endPopover.close()
            self?.onEndSession?()
        }
        endActions = [cancelAction, confirmAction]
        let confirm = NSButton(title: confirmation.confirm, target: confirmAction, action: #selector(HUDButtonAction.run))
        confirm.bezelStyle = .push
        confirm.bezelColor = .systemRed
        confirm.hasDestructiveAction = true
        confirm.controlSize = .regular
        confirm.sizeToFit()
        let cancel = NSButton(title: confirmation.cancel, target: cancelAction, action: #selector(HUDButtonAction.run))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        cancel.sizeToFit()
        // Native push-button heights; both share the taller one and sit on one baseline.
        let buttonHeight = max(confirm.fittingSize.height, cancel.fittingSize.height)
        confirm.frame = NSRect(x: width - 16 - confirm.frame.width, y: y, width: confirm.frame.width, height: buttonHeight)
        cancel.frame = NSRect(x: confirm.frame.minX - 8 - cancel.frame.width, y: y, width: cancel.frame.width,
                              height: buttonHeight)
        document.addSubview(cancel)
        document.addSubview(confirm)
        y += buttonHeight + 16
        document.frame = NSRect(x: 0, y: 0, width: width, height: y)
        let controller = NSViewController()
        controller.view = document
        endPopover.contentViewController = controller
        endPopover.contentSize = document.frame.size
        endPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        endPopover.contentViewController?.view.window?.sharingType = .none
    }

    // MARK: details

    /// Details are a snapshot opened deliberately, never a stream of rows inside the captions.
    /// The live titlebar state remains outside and continues to show current problems.
    private func toggleDetails(from anchor: NSView) {
        if detailsPopover.isShown { detailsPopover.close(); return }
        showDetails(from: anchor)
    }

    private func showDetails(from anchor: NSView) {
        endPopover.close()
        detailsAnchor = anchor
        updateDetails()
        detailsPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        detailsPopover.contentViewController?.view.window?.sharingType = .none
    }

    // swiftlint:disable:next function_body_length
    private func updateDetails() {
        let now = clock()
        guard model.voiceState != nil || model.issueSlot(now: now) != nil else { return }
        let previousScroll = (detailsPopover.contentViewController?.view as? NSScrollView)?
            .contentView.bounds.origin.y ?? 0
        let focusedControl = (detailsPopover.contentViewController?.view.window?.firstResponder as? NSButton)?.identifier
        popoverActions.removeAll()
        let document = HUDDetailsView()
        let detailWidth = SubtitleTokens.Size.detailsPopoverWidth
        var y: CGFloat = 14
        @discardableResult
        func text(_ value: String, font: NSFont, color: NSColor = SubtitleStyle.white(0.85), x: CGFloat = 16,
                  symbol: String? = nil, symbolColor: NSColor? = nil) -> CGFloat {
            let indent: CGFloat = symbol == nil ? 0 : 20
            let width = detailWidth - x - 16 - indent
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = font
            label.textColor = color
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = width
            let bounds = (value as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let height = ceil(bounds.height) + 4
            label.frame = NSRect(x: x + indent, y: y, width: width, height: height)
            document.addSubview(label)
            if let symbol {
                let icon = NSImageView(frame: NSRect(x: x, y: y + 1, width: 14, height: 14))
                icon.image = SubtitleStyle.symbol(symbol, size: 11, weight: .semibold)
                icon.contentTintColor = symbolColor ?? color
                icon.setAccessibilityElement(false)
                document.addSubview(icon)
            }
            y += height + 8
            return height
        }
        func button(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
            let target = HUDButtonAction(action)
            popoverActions.append(target)
            let button = NSButton(title: title, target: target, action: #selector(HUDButtonAction.run))
            button.identifier = NSUserInterfaceItemIdentifier(title)
            button.bezelStyle = .rounded
            button.controlSize = .small
            if let symbol {
                button.image = SubtitleStyle.symbol(symbol, size: 11, weight: .medium)
                button.imagePosition = .imageLeading
            }
            button.sizeToFit()
            button.frame = NSRect(x: 16, y: y, width: min(detailWidth - 32, button.frame.width + 8), height: 26)
            document.addSubview(button)
            y += 32
        }
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                             target: nil, action: nil)
        close.isBordered = false
        close.identifier = NSUserInterfaceItemIdentifier("close-status-details")
        close.setAccessibilityLabel(String(localized: "关闭详情"))
        close.toolTip = String(localized: "关闭详情")
        close.keyEquivalent = "\u{1b}"
        let closeAction = HUDButtonAction { [weak self] in self?.detailsPopover.close() }
        popoverActions.append(closeAction)
        close.target = closeAction; close.action = #selector(HUDButtonAction.run)
        close.frame = NSRect(x: detailWidth - 36, y: 10, width: 24, height: 24)
        document.addSubview(close)

        // Top row: a 24 pt capsule and its consequence in one sentence.
        if let voice = model.voiceState {
            let capsule = VoiceCapsuleView(large: true)
            capsule.showsChevron = false
            capsule.apply(voice, full: true)
            let capsuleWidth = VoiceCapsuleView.width(for: voice, full: true, large: true, chevron: false)
            capsule.frame = NSRect(x: 16, y: y, width: capsuleWidth, height: SubtitleTokens.Size.detailsCapsuleHeight)
            document.addSubview(capsule)
            y += SubtitleTokens.Size.detailsCapsuleHeight + 8
            text(voice.consequence, font: .systemFont(ofSize: 13, weight: .medium), color: SubtitleStyle.white(0.92))
            if voice.detail != voice.consequence {
                text(voice.detail, font: .systemFont(ofSize: 12), color: SubtitleStyle.white(0.6))
            }
        }
        // Second row: 右⌥ → action.
        if let key = model.titlebarKey, let action = key.action {
            let keycap = KeycapActionView()
            keycap.apply(TitlebarKey(key: key.key, action: nil, style: key.style), showsAction: false)
            let keyWidth = KeycapActionView.keyWidth(key)
            keycap.frame = NSRect(x: 16, y: y, width: keyWidth, height: SubtitleTokens.Size.controlHeight)
            keycap.onClick = nil
            // Not a control here: the row reads as one line of text.
            keycap.setAccessibilityElement(false)
            document.addSubview(keycap)
            let arrow = NSTextField(labelWithString: "→ " + action)
            arrow.font = .systemFont(ofSize: 13, weight: .medium)
            arrow.textColor = SubtitleStyle.white(0.85)
            arrow.setAccessibilityElement(true)
            arrow.setAccessibilityLabel(String(localized: "右侧 Option 键：\(action)"))
            arrow.frame = NSRect(x: 16 + keyWidth + 8, y: y + 1, width: detailWidth - keyWidth - 40, height: 18)
            document.addSubview(arrow)
            y += SubtitleTokens.Size.controlHeight + 6
            text(String(localized: "点按右侧 Option 键开始翻译，再点按结束；译音播完后回到原声。"),
                 font: .systemFont(ofSize: 12), color: SubtitleStyle.white(0.6))
        }
        // Problems and notifications, complete sentences.
        let chips = model.issueChips(now: now)
        for chip in chips {
            let colors = IssueChipView.color(chip.tone, display: .current)
            text(chip.detail, font: .systemFont(ofSize: 13),
                 color: chip.isProblem ? colors.text : SubtitleStyle.white(0.85),
                 symbol: chip.symbol, symbolColor: colors.text)
        }
        for line in model.activityDetails(now: now) {
            text(line.detail ?? line.text, font: .systemFont(ofSize: 12), color: SubtitleStyle.white(0.6))
        }
        if let reminder = cloudReminder {
            text(String(localized: "云端翻译已开启：会议文字会发送给 OpenAI。"), font: .systemFont(ofSize: 13),
                 symbol: SubtitleTokens.VoiceIcon.cloud, symbolColor: SubtitleStyle.color(.voiceTranslate))
            button(String(localized: "本场只用 Apple 翻译听到的话")) { [weak self] in
                reminder.apple(); self?.closeCloudReminder()
            }
            button(String(localized: "复制聊天说明"), symbol: SubtitleTokens.ActionIcon.copy) { reminder.copy() }
            button(String(localized: "本场不再提示"), symbol: SubtitleTokens.ActionIcon.dismissReminder) { [weak self] in
                self?.closeCloudReminder()
            }
        }
        var destinations: [HUDLine.SettingsDestination] = []
        if model.voiceState?.kind == .unavailable || model.voiceState?.kind == .remoteHearsOriginal {
            destinations.append(.audio)
        }
        for destination in chips.compactMap(\.settingsDestination) where !destinations.contains(destination) {
            destinations.append(destination)
        }
        if let onOpenSettings {
            if destinations.isEmpty, model.meetingActive {
                button(String(localized: "打开设置…"), symbol: SubtitleTokens.ActionIcon.settings) { [weak self] in
                    self?.detailsPopover.close(); onOpenSettings(.audio)
                }
            }
            for destination in destinations {
                // These open the Settings window: a trailing ellipsis (HIG) and the menu's gearshape.
                let title = switch destination {
                case .audio: String(localized: "音频设置…")
                case .translation: String(localized: "翻译设置…")
                case .permissions: String(localized: "权限设置…")
                }
                button(title, symbol: SubtitleTokens.ActionIcon.settings) { [weak self] in
                    self?.detailsPopover.close(); onOpenSettings(destination)
                }
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: detailWidth, height: y + 6)
        let height = min(420, y + 6)
        let viewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: detailWidth, height: height))
        viewport.drawsBackground = false
        viewport.hasVerticalScroller = y + 6 > 420
        viewport.autohidesScrollers = true
        viewport.documentView = document
        viewport.autoresizingMask = [.width, .height]
        // The popover's own darkAqua material, as the end confirmation: no nested hudWindow.
        let controller = NSViewController()
        controller.view = viewport
        detailsPopover.contentViewController = controller
        detailsPopover.contentSize = viewport.frame.size
        viewport.tile()
        viewport.contentView.scroll(to: NSPoint(x: 0, y: min(previousScroll,
            max(0, document.frame.height - viewport.contentView.bounds.height))))
        viewport.reflectScrolledClipView(viewport.contentView)
        if let focusedControl, let button = document.subviews.first(where: { $0.identifier == focusedControl }) {
            controller.view.window?.makeFirstResponder(button)
        }
        controller.view.window?.sharingType = .none
    }

    // smoke / tests
    var isVisible: Bool { panel.isWindowVisible && (shownVoice != nil || shownIssue != nil || panel.speechIsVisible) }
    var sharingTypeIsNone: Bool { panel.sharingTypeIsNone }
    var clickThrough: Bool { panel.clickThrough }
    var windowNumber: Int { panel.windowNumber }
    #if TALKTALK_DEV
    func renderForSmoke() {
        redrawTimer?.invalidate(); redrawTimer = nil
        redraw()
    }
    /// My live turn as handed to the dock (or, below 140 pt, to the timeline's last row).
    var transcriptSourceForSmoke: String? { shownDock?.expanded == true ? shownDock?.turn?.source : nil }
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
