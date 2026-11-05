import AppKit
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSession
import TalkTalkDriverSupport

/// Meeting mode ↔ SystemInputSwitcher (sysinput, ARCHITECTURE.md §8.6, §16 decision 4): the
/// system default input goes to TalkTalk Mic while meeting mode runs and comes back afterwards;
/// with the call still on, by default only when it ends. This file is the wiring only: the
/// "通话还在" dialogs and their rules are app-ui's `SysInputDialogs` (Core `SysInputDialogPlan`),
/// the one-shot texts are PTTHUD / HUDModel's, the switch is `AppUIModels.shared.audio`'s.
/// The smoke run never creates one (the switcher reads and may write the real default input).
@MainActor
final class SystemInputController {
    let switcher: SystemInputSwitcher
    private let state: AppState
    private let hud: PTTHUD?
    private var subscription: MeetingSubscription?
    /// The switcher's status changed (menu bar icon, §8.6 yellow / red).
    var onStatusChange: (() -> Void)?
    var onFactsChange: (() -> Void)?
    private let waitForFeed: Bool
    private var ownsMeetingMode = false
    private var pendingAppID: String?
    private var pendingResume = false
    private var onboardingUpdate: (@MainActor (MeetingMicGuardPlan.State) -> Void)?
    private var inactiveWatch: Task<Void, Never>?
    private(set) var micReadWhileInactive = false
    /// MeetingMicGuard (§8.6) and OutputRouteProbe (§3.7), running during meeting mode. Their
    /// states are the facts PassthroughPolicy (`micGuard`, `awaitingAudioConfirmation`,
    /// `speakerMode`) and push to talk (`allowsPushToTalk`) read; SPEAK wires those consumers.
    let micGuard: MeetingMicGuard
    let route: OutputRouteProbe
    /// The guard's cue in the headphones (MonitorOutput, never the Feed; §8.6, §3.8 "提示音").
    /// nil until SPEAK's MonitorOutput is in the app: then only the HUD line shows.
    var playGuardCue: (@MainActor () async -> Bool)?
    private var cueOwed = false
    private var cueTask: Task<Void, Never>?
    private var headphoneObserver: NSObjectProtocol?
    private var confirmingHeadphones = false

    init(state: AppState, events: MeetingEvents, hud: PTTHUD?, switcher: SystemInputSwitcher = SystemInputSwitcher(),
         micGuard: MeetingMicGuard = MeetingMicGuard(), waitForFeed: Bool = false,
         monitorUID: @escaping @MainActor () -> String? = { nil }) {
        self.state = state
        self.hud = hud
        self.switcher = switcher
        self.micGuard = micGuard
        self.waitForFeed = waitForFeed
        route = OutputRouteProbe(confirmedHeadphones: { HeadphoneAnswers.confirmed() },
                                 monitorUID: monitorUID)
        micGuard.onEvent = { [weak self] e in self?.guardEvent(e) }
        micGuard.onState = { [weak self] s in
            AppUIModels.shared.audio.meetingMic = Self.check(s)
            self?.onStatusChange?()
            self?.onFactsChange?()
            self?.onboardingUpdate?(s)
        }
        route.onState = { [weak self] _ in
            self?.onStatusChange?()
            self?.onFactsChange?()
            self?.retryGuardCue()
            Task { @MainActor [weak self] in self?.confirmHeadphonesIfNeeded() }
        }
        headphoneObserver = NotificationCenter.default.addObserver(forName: HeadphoneAnswers.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.route.refresh() }
        }
        switcher.onStatus = { [weak self] s in
            self?.state.systemInput = Self.text(s)
            self?.onStatusChange?()
            self?.onFactsChange?()
        }
        switcher.onNotice = { [weak hud] n in hud?.sysInput(n) }
        switcher.onLog = { NSLog("sysinput: %@", $0) }
        subscription = events.subscribe { [weak self] e in self?.handle(e) }
        SysInputDialogs.installPowerOffObserver()
    }

    isolated deinit { if let headphoneObserver { NotificationCenter.default.removeObserver(headphoneObserver) } }

    private func confirmHeadphonesIfNeeded() {
        guard route.isRunning, !confirmingHeadphones else { return }
        confirmingHeadphones = true
        defer { confirmingHeadphones = false }
        let candidates = (route.state.meetingOutputs ?? []) + (route.state.defaultOutput.map { [$0] } ?? [])
        for device in candidates where [.bluetooth, .bluetoothLE, .usb].contains(device.transport) {
            guard route.isRunning else { break }
            HeadphoneAnswers.askIfNeeded(uid: device.uid, name: device.name)
        }
        AppUIModels.shared.audio.reload()
        route.refresh()
    }

    /// App launch starts listeners. With SPEAK, takeover waits for the output owner's Feed.
    func start() {
        switcher.start()
        if !waitForFeed { switcher.beginLaunchTakeover() }
        state.systemInput = Self.text(switcher.status)
        inactiveWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                guard let self else { break }
                let reading = !state.meetingActive && CoreAudioDriverHAL().device(uid: DriverIdentity.micUID)?.isRunningSomewhere == true
                if reading != micReadWhileInactive { micReadWhileInactive = reading; onStatusChange?() }
            }
        }
    }

    func startOnboardingCheck(_ update: @escaping @MainActor (MeetingMicGuardPlan.State) -> Void) {
        onboardingUpdate = update
        if !state.meetingActive { micGuard.start(scope: []) }
        update(micGuard.state)
    }
    func stopOnboardingCheck() {
        onboardingUpdate = nil
        if !state.meetingActive { micGuard.stop() }
    }

    private func handle(_ e: MeetingEvent) {
        if case let .started(_, _, _, mode) = e {
            ownsMeetingMode = mode == .meeting
        }
        guard ownsMeetingMode else { return }
        switch e {
        case let .started(appID, _, _, _):
            pendingAppID = appID
            pendingResume = false
            let r: SystemInputSwitcher.EntryResult = waitForFeed ? .unchanged
                : switcher.enterMeetingMode(meetingApps: [appID], switchDefaultInput: AppUIModels.shared.audio.switchDefaultInput)
            if !waitForFeed { entry(r) }
            // The route first: the guard's first red asks it whether a cue may play (review of a5b2b6b #3).
            route.start(scope: [appID])
            micGuard.start(scope: [appID], justSwitchedDefaultInput: r == .switched)
        case .suspended:
            switcher.meetingSuspended()
        case .resumed:
            pendingResume = waitForFeed
            if !waitForFeed { switcher.meetingResumed() }
            route.refresh()             // before the guard: its red after wake reads the route now
            micGuard.audioRestarted()   // wake: confirm again before push to talk (§3.6)
        case .ended(.user):
            // `confirmUserEnd` already ended the switcher's part, with your answer
            stopWatching()
        case .ended:
            // Auto end, end after sleep / lock, failure: wait for the call to end (§8.6).
            _ = switcher.endMeetingMode(decision: .whenCallEnds)
            stopWatching()
        case .audioServiceRestarted:
            // The guard's own ServiceRestarted listener does this too; the session's event may
            // come first. The switcher's own HAL listeners follow TalkTalk Mic.
            micGuard.audioRestarted()
        case .state, .hint, .translation:
            break
        }
    }

    private func stopWatching() {
        ownsMeetingMode = false
        pendingAppID = nil
        pendingResume = false
        cueOwed = false
        if onboardingUpdate != nil { micGuard.start(scope: []) } else { micGuard.stop() }
        route.stop()
    }

    func feedBecameReady() {
        guard let app = pendingAppID, state.meetingActive else { return }
        if pendingResume {
            pendingResume = false
            switcher.meetingResumed()
        } else {
            let result = switcher.enterMeetingMode(meetingApps: [app],
                                                   switchDefaultInput: AppUIModels.shared.audio.switchDefaultInput)
            entry(result)
        }
        micGuard.audioRestarted()
        onFactsChange?()
    }

    func retryGuardCue() {
        guard cueOwed, cueTask == nil, AppUIModels.shared.audio.cuesEnabled,
              route.state.cueAllowed, let playGuardCue else { return }
        cueTask = Task { [weak self] in
            let queued = await playGuardCue()
            guard let self else { return }
            if queued { cueOwed = false }
            cueTask = nil
        }
    }

    /// Red: "对方会听到你的原声" until it is not red; the cue only on headphones (§8.6).
    private func guardEvent(_ e: MeetingMicGuardPlan.Event) {
        guard state.meetingActive else { return }
        switch e {
        case .turnedRed:
            cueOwed = true
            hud?.post(.remoteHearsYourVoice)
            // Read the default output now, not a state cached before a wake or another listener's
            // turn: a cue on the built-in speaker goes into the meeting (§3.4).
            route.refresh()
            retryGuardCue()
        case .clearedRed:
            cueOwed = false
            hud?.clear(.remoteHearsYourVoice)
        case .confirmed:
            break
        }
    }

    /// Settings › 音频's meeting-app line (app-ui's MeetingMicCheck).
    static func check(_ s: MeetingMicGuardPlan.State) -> MeetingMicCheck {
        switch s.verdict {
        case nil: .notChecked
        case let .green(_, app)?: .green(app: app)
        case let .physicalMic(_, app, _)?: .physicalMic(app: app, detail: s.verdict?.detail)
        case .noReader?: .nobodyReads
        }
    }

    /// Before the user ends meeting mode ("结束会议模式"): asks while the call is on, then ends the
    /// switcher's part. false: you cancelled, meeting mode goes on.
    func confirmUserEnd() -> Bool {
        SysInputDialogs.endMeeting(switcher: switcher, hud: hud)
    }

    /// `applicationShouldTerminate` (logout / restart / shutdown: restore now, no dialog).
    /// SIGTERM and friends never get here, and call nothing (§8.6).
    func quit() -> NSApplication.TerminateReply {
        SysInputDialogs.quit(switcher: switcher)
    }

    // MARK: menu

    var showsSwitchBack: Bool {
        switch switcher.status {
        case .overridden, .switchBackFailed: true
        default: false
        }
    }

    var showsRestoreNow: Bool {
        switch switcher.status {
        case .deferred, .pendingFromLastRun, .deferredOnPhysical: true
        default: false
        }
    }

    var showsResumeFromRecord: Bool {
        switch switcher.status {
        case .pendingFromLastRun, .deferredOnPhysical(_, _, true): return true
        default: return false
        }
    }

    func switchBack() {
        let r = switcher.switchBackToMic()
        // The switcher's own .switchBackFailed notice already says it, with the device: one line.
        if r == .writeFailed, case .switchBackFailed = switcher.status { return }
        entry(r)
    }

    func restoreNow() { SysInputDialogs.report(switcher.restoreNow(), status: switcher.status, hud: hud) }

    /// Entry and switch-back failures: HUD yellow per §8.6 (app-ui's texts).
    private func entry(_ r: SystemInputSwitcher.EntryResult) { hud?.sysInputEntry(r) }

    // MARK: menu status line

    static func text(_ s: SystemInputSwitcher.Status) -> String? {
        switch s {
        case .idle: nil
        case .otherInstanceManages: "另一个 TalkTalk 正在管系统默认输入"
        case .holding: "系统默认输入：TalkTalk Mic"
        case .waitingForMic: "⚠︎ TalkTalk Mic 不见了，回来后切回"
        case let .overridden(by): "⚠︎ 系统默认输入被改成了 \(by)"
        case let .switchBackFailed(current, retrying):
            retrying ? "⚠︎ 没能切回 TalkTalk Mic，系统默认输入是 \(current)，正在重试"
                     : "⚠︎ 没能切回 TalkTalk Mic，系统默认输入是 \(current)"
        case .suspended: "系统默认输入：TalkTalk Mic（会议模式已挂起）"
        case .deferred: "⚠︎ 默认输入仍是 TalkTalk Mic，通话结束后还原"
        case let .deferredOnPhysical(current, micAbsent, fromLastRun):
            (fromLastRun ? "⛔︎ " : "⚠︎ ") + SysInputDialogPlan.deferredOnPhysicalStatus(device: current, micAbsent: micAbsent)
        case let .pendingFromLastRun(original): "⛔︎ 上次的默认输入还没还原（原来是 \(original)）"
        case .noRestoreTarget: "⛔︎ 没有可以还原到的实体麦克风"
        }
    }
}
