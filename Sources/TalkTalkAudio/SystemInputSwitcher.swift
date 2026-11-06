import Darwin
import Foundation
import TalkTalkCore

/// Switches the system default input to TalkTalk Mic for meeting mode and reliably puts it back
/// (ARCHITECTURE.md §8.6, §3.6, §16 decision 4). The rules are `SystemInputPlan`; this class
/// reads the HAL, owns the record, the lock and the guard, and carries the rules out. The default
/// output is never written.
///
/// Layers (§8.6): 1 normal restore (here); 2 the guard (`SysInputGuard`); 3 the driver removing
/// TalkTalk Mic — helpful, but not independently sufficient with stable selectability
/// (`Config.driverLayerCounts`); 4 the next launch (`beginLaunchTakeover`). Plus the no-record
/// invariant, run here.
///
/// How MeetingSession (listen) drives it:
///   - app launch: `start()`; once the Feed is attached (or right away without a driver):
///     `beginLaunchTakeover()`.
///   - meeting mode on: `enterMeetingMode(meetingApps:switchDefaultInput:)`.
///   - every completed meeting session: `endMeetingMode(decision: .restoreNow)` with no choice
///     dialog. Restore still respects record ownership and a manually changed input.
///   - sleep / lock / fast user switch away: `meetingSuspended()`; wake back into meeting mode:
///     `meetingResumed()`.
///   - normal quit and logout/shutdown: `prepareForQuit(decision: .restoreNow)`.
///     SIGTERM / SIGINT / SIGHUP: call nothing, just exit
///     (the guard restores after the call, as after a crash). This class installs no signal handlers.
///   - menu: "切回 TalkTalk Mic" → `switchBackToMic()`; "现在还原默认输入" → `restoreNow()`.
@MainActor
public final class SystemInputSwitcher {
    public typealias Device = MicPolicy.Device
    public typealias EndDecision = SystemInputPlan.EndDecision

    // MARK: public state

    public enum Status: Sendable, Equatable {
        /// Nothing of ours is in play.
        case idle
        /// The other build holds the lock: "另一个 TalkTalk 正在管系统默认输入". We switch, restore and
        /// enforce nothing.
        case otherInstanceManages
        /// Meeting mode; default input is TalkTalk Mic.
        case holding(original: String)
        /// TalkTalk Mic vanished; macOS picked another device; switch back when it returns.
        case waitingForMic(original: String)
        /// You changed it during meeting mode: record void. Menu "切回 TalkTalk Mic".
        case overridden(by: String)
        /// Our switch back to TalkTalk Mic failed; the default input really is `current` (macOS's
        /// pick, not yours). `retrying`: every refresh tries again, for up to `contestWindow`;
        /// after that it stops but keeps the record (restored at the end). Menu "⚠︎ 没能切回
        /// TalkTalk Mic，系统默认输入是 X(，正在重试)" and "切回 TalkTalk Mic" (review 2026-11-05 #1).
        case switchBackFailed(current: String, retrying: Bool)
        case suspended(original: String)
        /// Meeting mode ended with the call still on: menu bar yellow "默认输入仍是 TalkTalk Mic，通话结束后还原".
        case deferred(original: String)
        /// Deferred (`fromLastRun`: pending, layer 4) with the call on, but the default input is
        /// `current`, a device macOS picked (physical; when not `fromLastRun` also a virtual one):
        /// TalkTalk Mic is gone (`micAbsent`) or our switch back to it failed.
        /// "⚠︎ 系统默认输入是 X（TalkTalk Mic 不在／没能切回），通话结束后还原"
        /// (review of 9d9b3a4 #1, review of 37c505d #1).
        case deferredOnPhysical(current: String, micAbsent: Bool, fromLastRun: Bool)
        /// Layer 4 found last run's record with the call still on: menu bar red, "开启会议模式（接着用
        /// 这份记录）/ 现在还原"; restores by itself when the call ends.
        case pendingFromLastRun(original: String)
        /// Ours to restore but nothing physical exists: HUD red.
        case noRestoreTarget

        /// Says a restore record of ours exists (meeting mode, waiting, last run's).
        public var impliesRecord: Bool {
            switch self {
            case .idle, .otherInstanceManages, .overridden: false
            default: true
            }
        }
    }

    /// One-shot messages for the HUD.
    public enum Notice: Sendable, Equatable {
        /// "X 接入后系统换了默认输入，已切回 TalkTalk Mic"
        case switchedBackAfterInsert(device: String)
        case switchedBackAfterMicReturned
        /// "没能切回 TalkTalk Mic，系统默认输入是 X" (yellow), once per round of failures.
        case switchBackFailed(device: String)
        /// "系统默认输入被改成了 X，跟随系统的会议 App 现在用 X" (yellow, once)
        case manualChange(device: String)
        case restored(device: String, note: SystemInputPlan.RestoreTarget.Notice?)
        /// The no-record invariant put it back (§8.6).
        case invariantRestored(device: String)
        case entryNote(SystemInputPlan.EntryOriginal.Notice)
        case noRestoreTarget
    }

    public enum EntryResult: Sendable, Equatable {
        case switched
        /// Meeting mode already owns it, or the switch is off for this session.
        case unchanged
        /// TalkTalk Mic is not in the device list (Feed not attached / driver missing): HUD yellow.
        case micMissing
        case otherInstanceManages
        case noPhysicalInput
        /// Writing or reading back the default input failed: record deleted, guard told to exit,
        /// lock released; HUD yellow.
        case writeFailed
        case recordWriteFailed
        case guardLaunchFailed
        /// Driver ≥ 0.2.0: writing 'ttmm' = 1 was refused, or TalkTalk Mic's CanBeDefaultDevice did
        /// not become 1 in time. No record left; HUD yellow (§8.6 "会议模式开关").
        case micNotSelectable
    }

    public enum EndResult: Sendable, Equatable {
        case restored(device: String)
        /// The call is still on: record kept, restore when it ends.
        case deferred
        /// Nothing of ours to restore (never switched, voided, or you already changed it).
        case nothingToRestore
        case noRestoreTarget
        case writeFailed
        case notOwner
    }

    public private(set) var status: Status = .idle { didSet { if status != oldValue { onStatus?(status) } } }
    public var onStatus: (@MainActor (Status) -> Void)?
    public var onNotice: (@MainActor (Notice) -> Void)?
    /// One line for the app's log (no device names, no user content).
    public var onLog: (@MainActor (String) -> Void)?

    /// Meeting mode as the switcher knows it (`enterMeetingMode` … `endMeetingMode`/quit), also
    /// while the default input was not switched or the record is void. 完全卸载 and the driver
    /// install read this, not a flag of their own (m2-driver wiring (a)).
    public var isMeetingModeOn: Bool { meetingModeOn }

    /// Whether an owned record still has an active call; normal app end/quit no longer asks.
    public var needsEndConfirmation: Bool {
        guard ownsRecord else { return false }
        switch mode {
        case .meeting, .suspended, .deferred, .pending: return !callEnded
        case .none, .voided: return false
        }
    }

    public private(set) var callEnded = false
    public var lastPhysicalDefault: Device? { tracker.lastPhysicalDefault }

    // MARK: dependencies

    public struct Dependencies {
        public var hal: SysInputHAL
        public var processes: MeetingProcessSource
        public var paths: SysInputPaths
        public var launcher: SysInputGuardLauncher
        public var bundleID: String
        public var executablePath: String
        public var config: SystemInputPlan.Config
        public var now: @Sendable () -> Double
        /// Step 1 of the fixed restore order: close passthrough (§3.8). passthrough-logic wires it.
        public var closePassthrough: @MainActor () -> Void
        /// Layer 4: is `pid` running exactly this executable? (by path, never by name)
        public var pidRuns: @Sendable (Int32, String) -> Bool
        public var terminate: @Sendable (Int32) -> Void
        /// Poll + HAL listeners. Tests turn it off and call `refresh()` themselves.
        public var autoRefresh: Bool
        /// The driver's 'ttmm' switch (§8.3). The app may inject TalkTalkDriverSupport's HAL.
        public var meetingSwitch: MeetingModeSwitch

        public init(hal: SysInputHAL = CoreAudioSysInputHAL(),
                    processes: MeetingProcessSource = ResolverProcessSource(),
                    paths: SysInputPaths = .standard(),
                    launcher: SysInputGuardLauncher = PosixSpawnGuardLauncher(),
                    bundleID: String = BuildFlavor.current.rawValue,
                    executablePath: String = SysInputProcess.currentExecutable,
                    config: SystemInputPlan.Config = .default,
                    now: @escaping @Sendable () -> Double = { Double(HostClock.now()) / 1e9 },
                    closePassthrough: @escaping @MainActor () -> Void = {},
                    pidRuns: @escaping @Sendable (Int32, String) -> Bool = SysInputProcess.runs,
                    terminate: @escaping @Sendable (Int32) -> Void = { _ = kill($0, SIGTERM) },
                    autoRefresh: Bool = true,
                    meetingSwitch: MeetingModeSwitch = CoreAudioMeetingModeSwitch()) {
            self.hal = hal
            self.processes = processes
            self.paths = paths
            self.launcher = launcher
            self.bundleID = bundleID
            self.executablePath = executablePath
            self.config = config
            self.now = now
            self.closePassthrough = closePassthrough
            self.pidRuns = pidRuns
            self.terminate = terminate
            self.autoRefresh = autoRefresh
            self.meetingSwitch = meetingSwitch
        }
    }

    // MARK: internals

    private enum Mode: Equatable {
        case none
        case meeting(SystemInputPlan.MeetingMonitor)
        case suspended(SystemInputPlan.MeetingMonitor)
        case deferred(SystemInputPlan.DeferredMonitor)
        case pending(SystemInputPlan.DeferredMonitor)
        /// Meeting mode goes on, but you changed the default input: the record is gone.
        case voided(original: SystemInputPlan.DeviceRef, changedTo: String)
    }

    private var deps: Dependencies
    private let store: SysInputRecordStore
    private let lock: SysInputLock
    private var mode: Mode = .none
    private var record: SysInputRecord?
    private var guardHandle: SysInputGuardHandle?
    private var guardRestarts: [Double] = []
    private var tracker = SystemInputPlan.Tracker()
    private var callState = CallEndRule.State()
    private var meetingModeOn = false
    private var takeoverAt: Double?
    private var takeoverEnabled = false
    private var pollTask: Task<Void, Never>?
    private var started = false
    private var quitting = false
    /// A restore you asked for now ("现在还原", menu or dialog) failed to write: the retries do not
    /// wait for the call to end. Only your "现在还原" sets it; entering meeting mode, a new end
    /// decision and giving up the record clear it (review B). Kept in the record (`restoreNow`),
    /// the one place for it: the guard after a crash or quit and a layer-4 takeover read the same
    /// value, so your choice is not lost with the app (review of 37c505d #2).
    private var restoreWithoutWaiting: Bool {
        get { record?.restoreNow == true }
        set {
            guard var r = record, (r.restoreNow == true) != newValue || recordDirty else { return }
            r.restoreNow = newValue ? true : nil
            // This process goes by it whether or not the disk write works (review of f5e22ac);
            // the disk copy is for the guard and a later takeover, rewritten until it lands.
            writeRecord(r)
        }
    }
    /// The record in memory is newer than the one on disk (a write failed). refresh() and the
    /// hand-off to the guard write it again: the guard reads only the disk (review of 608af9d #3).
    private var recordDirty = false
    /// "现在还原" during meeting mode failed to write: once a retry succeeds, end as a first-try
    /// success would (record void, "切回 TalkTalk Mic" works). Same lifetime as above (review D).
    private var voidAfterRestore: SystemInputPlan.DeviceRef?
    /// Bumped on every guard launch; an exit notice from an older guard is ignored (review E).
    private var guardGeneration = 0

    public init(_ deps: Dependencies = Dependencies()) {
        self.deps = deps
        self.store = SysInputRecordStore(paths: deps.paths)
        self.lock = SysInputLock(path: deps.paths.lock.path)
    }

    private var ownsRecord: Bool { lock.isHeld && record != nil }
    private var now: Double { deps.now() }

    // MARK: lifecycle

    /// Starts watching (listeners + 2 s poll) and the no-record invariant.
    public func start() {
        guard !started else { return }
        started = true
        tracker.update(deps.hal.snapshot(), now: now)
        if deps.autoRefresh {
            deps.hal.startWatching { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            let period = deps.config.pollInterval
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(period))
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        deps.hal.stopWatching()
        started = false
    }

    /// Layer 4 (§8.6 "下次启动"): call once the Feed is attached (TalkTalk Mic only exists while
    /// talktalk is attached). After `launchSettle` (2 s) the record, if any, is taken over.
    public func beginLaunchTakeover() {
        takeoverEnabled = true
        takeoverAt = now + deps.config.launchSettle
        refresh()
    }

    // MARK: meeting mode

    /// Entry steps 1–4 of §8.6. `switchDefaultInput` = the settings switch (§16 decision 4); off
    /// still tells us meeting mode is on (the no-record invariant pauses).
    @discardableResult
    public func enterMeetingMode(meetingApps: [String], switchDefaultInput: Bool = true) -> EntryResult {
        meetingModeOn = true
        guard switchDefaultInput else { return .unchanged }
        switch mode {
        case .meeting:
            return .unchanged
        case let .suspended(m):
            mode = .meeting(m)
            return .unchanged
        case let .voided(original, _):
            return switchToMic(original: original, meetingApps: meetingApps)
        case .deferred, .pending, .none:
            return switchToMic(original: record?.original, meetingApps: meetingApps)
        }
    }

    /// "结束会议模式" and the automatic ends.
    @discardableResult
    public func endMeetingMode(decision: EndDecision) -> EndResult {
        meetingModeOn = false
        restoreWithoutWaiting = false   // a new end decision replaces an earlier "现在还原"
        voidAfterRestore = nil
        refreshCall()
        switch mode {
        case .none:
            if ownsRecord {
                return finishByRule(callEndedOverride: decision == .restoreNow, userAskedNow: decision == .restoreNow)
            }
            return store.exists ? .notOwner : .nothingToRestore
        case .voided:
            mode = .none
            status = .idle
            return .nothingToRestore
        case .meeting, .suspended, .deferred, .pending:
            break
        }
        guard ownsRecord, let record else { mode = .none; status = .idle; return .notOwner }
        switch SystemInputPlan.endStep(decision, callEnded: callEnded) {
        case .restore:
            return finishByRule(callEndedOverride: true, userAskedNow: decision == .restoreNow)
        case .deferUntilCallEnds:
            // Already deferred or pending (layer 4) keeps its monitor (review C1).
            keepWaiting(record, replacement: currentReplacement(record))
            return .deferred
        }
    }

    /// Sleep, lock, fast user switch away: meeting mode suspends; default input untouched, record kept.
    public func meetingSuspended() {
        if case let .meeting(m) = mode {
            mode = .suspended(m)
            if let r = record { status = .suspended(original: r.original.name) }
        }
    }

    /// Back into meeting mode after wake: TalkTalk Mic again (§3.6 "唤醒").
    public func meetingResumed() {
        guard case var .suspended(m) = mode else { return }
        m.reassert()
        mode = .meeting(m)
        if let r = record { status = .holding(original: r.original.name) }
        let s = deps.hal.snapshot()
        if s.micPresent, !s.defaultIsMic, !writeMic() { switchBackFailed(.reasserted) }
        refresh()
    }

    /// Menu "切回 TalkTalk Mic": redo entry steps 2–4, the original being the one before the record was voided.
    @discardableResult
    public func switchBackToMic() -> EntryResult {
        switch mode {
        case let .voided(original, _):
            return switchToMic(original: original, meetingApps: Array(callState.scope))
        case var .meeting(m):
            m.reassert()
            mode = .meeting(m)
            if writeMic() {
                m.switchBackSucceeded()
                mode = .meeting(m)
                persistReplacement(nil)
                if let r = record { status = .holding(original: r.original.name) }
                return .switched
            }
            switchBackFailed(.reasserted)   // not your change: retried, never voided (review 2026-11-05 #1)
            return .writeFailed
        default:
            return .unchanged
        }
    }

    /// Menu "现在还原默认输入" (and "现在还原" on last run's record): restore now, call or not —
    /// still only when it is ours to restore.
    @discardableResult
    public func restoreNow() -> EndResult { restore(userAskedNow: true) }

    /// The restore behind "现在还原" and 完全卸载 step 1. `userAskedNow`: a failed write keeps
    /// retrying without waiting for the call (your "现在还原"); false: the retries wait for the
    /// call to end by the real rule (the uninstall step, which checked the call itself; review of
    /// 608af9d #1: a new call before a retry must not get the physical mic).
    private func restore(userAskedNow: Bool) -> EndResult {
        guard ownsRecord, let r = record else { return store.exists ? .notOwner : .nothingToRestore }
        let inMeeting: Bool = {
            switch mode {
            case .meeting, .suspended: return true
            default: return false
            }
        }()
        let priorMode = mode
        let priorStatus = status
        let result = finishByRule(callEndedOverride: true, userAskedNow: userAskedNow)
        if inMeeting, case .restored = result {
            // Meeting mode goes on without the switch; "切回 TalkTalk Mic" brings it back.
            mode = .voided(original: r.original, changedTo: deps.hal.defaultInputUID() ?? "")
        }
        if inMeeting, case .writeFailed = result { voidAfterRestore = r.original }
        // 完全卸载 (not your "现在还原"): a restore that did not happen leaves meeting mode as it
        // was. The deferred state finishByRule fell into would run the rest of the meeting on
        // DeferredMonitor, where a USB mic plugged in during the next call counts as your choice
        // and drops the record (review of ecb8f8c). Your "现在还原" keeps the deferred retries,
        // which restore without waiting for the call: that is what you asked for.
        if inMeeting, !userAskedNow, ownsRecord {
            switch result {
            case .writeFailed, .deferred, .noRestoreTarget:
                mode = priorMode
                status = priorStatus
            default:
                break
            }
        }
        return result
    }

    /// What "完全卸载" step 1 (§8.4) found when this app owns the record.
    public enum UninstallRestore: Sendable, Equatable {
        /// No record of ours: the stale-record path (`SysInputRestore.restoreStale`) decides.
        case notOwner
        /// Ours, but nothing to restore (you changed the default input, already restored).
        case nothingToRestore
        /// The call has not ended by §8.6's rule (30 s without IO, or the app gone): not restored.
        case callOngoing
        case restored(device: String)
        case failed(String)
    }

    /// "完全卸载" step 1 with this app's own record (texts as FullUninstaller's own, not catalogued). Unlike `restoreNow()` it never restores during
    /// the call (that would hand the meeting app the original voice; m2-driver wiring (b)). In
    /// meeting mode, once the call has ended, it restores as "现在还原" does and meeting mode stays
    /// on (record void): the driver step then stops at "先结束会议模式", on purpose: ending
    /// meeting mode is yours to do, then 完全卸载 runs again (wiring (d), §8.6).
    public func restoreForUninstall() -> UninstallRestore {
        guard ownsRecord else { return .notOwner }
        refreshCall()
        guard callEnded else { return .callOngoing }
        // In meeting mode, a restore that cannot happen now must not leave meeting mode for the
        // deferred state: the rest of the meeting would run on DeferredMonitor, and a USB mic you
        // plug in during the next call would count as your choice (record dropped) instead of an
        // insert switched back (review of a5b2b6b #2). Ask first, change nothing if it would wait.
        if let r = record, isMeetingMode {
            let snap = deps.hal.snapshot()
            tracker.update(snap, now: now)
            switch SystemInputPlan.deferredDecision(original: r.original, replacementUID: currentReplacement(r),
                                                    snapshot: snap, callEnded: true) {
            case .noTarget: return .failed(Self.uninstallNoTarget)
            case .wait: return .failed(Self.uninstallWaiting)
            default: break
            }
        }
        switch restore(userAskedNow: false) {
        case let .restored(d): return .restored(device: d)
        case .nothingToRestore: return .nothingToRestore
        case .notOwner: return .notOwner
        case .deferred: return .failed(Self.uninstallWaiting)
        case .noRestoreTarget: return .failed(Self.uninstallNoTarget)
        case .writeFailed: return .failed("写默认输入失败，稍后再试")
        }
    }

    static let uninstallWaiting = "原来的输入设备还没回到设备列表，稍后再试"
    static let uninstallNoTarget = "没有可还原的实体输入设备：接上一个麦克风再试"

    private var isMeetingMode: Bool {
        switch mode {
        case .meeting, .suspended: true
        default: false
        }
    }

    /// Normal app quit uses `.restoreNow`; failed restoration is handed to the recovery guard.
    /// `.whenCallEnds` remains available for older pending records and explicit internal callers.
    @discardableResult
    public func prepareForQuit(decision: EndDecision) -> EndResult {
        quitting = true
        meetingModeOn = false
        guard ownsRecord else {
            if case .voided = mode { mode = .none }
            return .nothingToRestore
        }
        // Your answer now replaces an earlier "现在还原" whose write failed: the guard must not
        // restore during the call because of it (review of 608af9d #2).
        if decision == .whenCallEnds {
            restoreWithoutWaiting = false
            voidAfterRestore = nil
        }
        refreshCall()
        switch SystemInputPlan.endStep(decision, callEnded: callEnded) {
        case .restore:
            let r = finishByRule(callEndedOverride: true, userAskedNow: false)
            if case .restored = r { return r }
            if case .nothingToRestore = r { return r }
            if decision == .restoreNow { restoreWithoutWaiting = true }   // the guard goes on restoring, not waiting
            handOffToGuard()
            return r
        case .deferUntilCallEnds:
            handOffToGuard()
            return .deferred
        }
    }

    // MARK: refresh (listeners, poll, tests)

    public func refresh() {
        if recordDirty, ownsRecord, let r = record { writeRecord(r) }
        let snap = deps.hal.snapshot()
        let t = now
        tracker.update(snap, now: t)
        refreshCall()

        if let at = takeoverAt, t >= at {
            takeoverAt = nil
            takeOver(snapshot: snap)
        }

        switch mode {
        case var .meeting(m):
            let action = m.observe(snap, tracker: tracker, now: t)
            mode = .meeting(m)
            persistReplacement(m.replacementUID)
            handle(action, monitor: m)
        case .suspended:
            break
        case var .deferred(m):
            let d = m.observe(snap, tracker: tracker, callEnded: callEnded || restoreWithoutWaiting, now: t)
            mode = .deferred(m)
            persist(m)
            apply(d, snapshot: snap)
        case var .pending(m):
            let d = m.observe(snap, tracker: tracker, callEnded: callEnded || restoreWithoutWaiting, now: t)
            mode = .pending(m)
            persist(m)
            apply(d, snapshot: snap)
        case .voided:
            break
        case .none:
            if !ownsRecord { idleChecks(snap) }
        }
    }

    // MARK: private

    private func refreshCall() {
        guard ownsRecord, let procs = deps.processes.meetingProcesses() else { return }
        callEnded = CallEndRule.observe(&callState, processes: procs, now: now).hasEnded
    }

    private func idleChecks(_ snap: SystemInputPlan.Snapshot) {
        let recordExists = store.exists
        if recordExists {
            // The other build's record, or last run's before the launch takeover has run.
            let free = SysInputLock.isAvailable(path: deps.paths.lock.path)
            if free, takeoverEnabled, takeoverAt == nil {
                takeOver(snapshot: snap)   // nobody holds it any more: it is ours to finish
            } else if !free {
                status = .otherInstanceManages
            }
            return
        }
        if status.impliesRecord || status == .otherInstanceManages { status = .idle }
        // A 1 left by a crash (the driver keeps it while the Mic is listed): back to 0 once nobody
        // owns a record. After the invariant below put a physical device back, the next refresh does it.
        // Hold the lock while doing it, and look again under it: the other build may have taken
        // the lock and switched to the Mic since the snapshot (review 2026-11-05 #2).
        if !meetingModeOn, !lock.isHeld, !snap.defaultIsMic, deps.meetingSwitch.meetingMode() == true,
           lock.tryAcquire(timeout: 0) {
            if !store.exists { MeetingModeGate.release(deps.meetingSwitch, defaultInputUID: deps.hal.defaultInputUID()) }
            lock.release()
        }
        guard snap.defaultIsMic, !meetingModeOn else { return }
        // Someone is between taking the lock and writing the record: leave it to them.
        guard !lock.isHeld, lock.tryAcquire(timeout: 0) else { return }
        defer { lock.release() }
        guard case .none = mode, !meetingModeOn, record == nil, !store.exists else { return }
        let fresh = deps.hal.snapshot()
        tracker.update(fresh, now: now)
        switch SystemInputPlan.noRecordInvariant(snapshot: fresh, meetingModeOn: meetingModeOn, recordExists: store.exists,
                                                 lockAvailable: true, lastPhysical: tracker.lastPhysicalDefault) {
        case .none:
            break
        case let .restore(t):
            // The original snapshot may predate another input selection or ownership change.
            // Recheck immediately before writing; HAL has no atomic compare-and-set operation.
            guard case .none = mode, !meetingModeOn, record == nil, !store.exists,
                  deps.hal.defaultInputUID() == MicPolicy.talkTalkMicUID else { return }
            if deps.hal.writeAndConfirm(uid: t.device.uid) { onNotice?(.invariantRestored(device: t.device.name)) }
        case .noTarget:
            onNotice?(.noRestoreTarget)
        }
    }

    private func switchToMic(original existing: SystemInputPlan.DeviceRef?, meetingApps: [String]) -> EntryResult {
        restoreWithoutWaiting = false
        voidAfterRestore = nil
        let snap = deps.hal.snapshot()
        tracker.update(snap, now: now)
        // 1. TalkTalk Mic must be in the device list.
        guard snap.micPresent else { return .micMissing }
        // 3 (lock first, so the record we read in 2 is ours to reuse).
        let hadLock = lock.isHeld
        guard lock.tryAcquire(timeout: 0.5) else {
            status = .otherInstanceManages
            return .otherInstanceManages
        }
        // A record we were already waiting on (deferred / pending): if the switch fails, it goes
        // back as it was, not deleted (review of a7ef015 #3).
        var prior: (record: SysInputRecord, mode: Mode)?
        switch mode {
        case .deferred, .pending: if let r = record { prior = (r, mode) }
        default: break
        }
        func fail(_ result: EntryResult) -> EntryResult {
            guard var back = prior?.record, let priorMode = prior?.mode else { abandonOwnership(); return result }
            // The guard that runs now, not the one the old record named: pending with no guard
            // launches one here (step 4) and keeps it. A stale pid would make the next launch's
            // takeover unable to stop it ("另一个实例在管", until the call ends) (review of 37c505d #3).
            back.guardPID = guardHandle?.pid
            do { try store.write(back) } catch { abandonOwnership(); return result }
            recordDirty = false
            record = back
            mode = priorMode
            setDeferredStatus(back)
            return result
        }
        // 2. The original.
        let onDisk = record ?? store.read()
        guard let entry = SystemInputPlan.entryOriginal(existing: onDisk?.original ?? existing,
                                                        currentDefault: snap.defaultInput,
                                                        lastPhysical: tracker.lastPhysicalDefault, devices: snap.devices)
        else {
            if !hadLock { lock.release() }
            return .noPhysicalInput
        }
        var rec = SysInputRecord(original: entry.original, writerBundleID: deps.bundleID,
                                 executablePath: deps.executablePath, guardPID: guardHandle?.pid,
                                 meetingApps: meetingApps, replacementUID: nil)
        do { try store.write(rec) } catch {
            if !hadLock { lock.release() }
            return .recordWriteFailed
        }
        recordDirty = false
        record = rec
        // 4. The guard, then the switch.
        if guardHandle == nil {
            guard launchGuard() else { return fail(.guardLaunchFailed) }
            rec.guardPID = guardHandle?.pid
            writeRecord(rec)
        }
        // 4b. Driver ≥ 0.2.0: 'ttmm' = 1 and wait for CanBeDefaultDevice = 1 (after the record and
        // the guard, so a crash here still leaves something that restores and releases).
        guard case .ready = MeetingModeGate.makeMicSelectable(deps.meetingSwitch,
                                                              timeout: deps.config.micSelectableTimeout) else {
            return fail(.micNotSelectable)
        }
        guard deps.hal.writeAndConfirm(uid: MicPolicy.talkTalkMicUID) else { return fail(.writeFailed) }
        callState = CallEndRule.State(scope: Set(meetingApps))
        callEnded = false
        mode = .meeting(SystemInputPlan.MeetingMonitor(config: deps.config))
        status = .holding(original: entry.original.name)
        if let n = entry.notice { onNotice?(.entryNote(n)) }
        return .switched
    }

    /// TalkTalk Mic as the default input during meeting mode (switch-backs, resume, the menu). The
    /// Mic may have re-entered the device list since, which resets 'ttmm' to 0: set it again first.
    private func writeMic() -> Bool {
        guard case .ready = MeetingModeGate.makeMicSelectable(deps.meetingSwitch,
                                                              timeout: deps.config.micSelectableTimeout) else { return false }
        return deps.hal.writeAndConfirm(uid: MicPolicy.talkTalkMicUID)
    }

    private func handle(_ action: SystemInputPlan.MeetingAction, monitor m: SystemInputPlan.MeetingMonitor) {
        guard let r = record else { return }
        switch action {
        case .none:
            switch m.phase {
            case .holding:
                if let d = m.retryDevice { status = .switchBackFailed(current: d.name, retrying: true) }
                else { status = .holding(original: r.original.name) }
            case .waitingForMic: status = .waitingForMic(original: r.original.name)
            case let .overridden(d): status = .overridden(by: d.name)
            case let .switchBackFailed(d): status = .switchBackFailed(current: d.name, retrying: false)
            }
        case let .switchToMic(reason):
            guard writeMic() else { switchBackFailed(reason); return }
            if case var .meeting(mm) = mode {
                mm.switchBackSucceeded()
                mode = .meeting(mm)
            }
            persistReplacement(nil)
            status = .holding(original: r.original.name)
            switch reason {
            case let .deviceInserted(d): onNotice?(.switchedBackAfterInsert(device: d.name))
            case .micReturned: onNotice?(.switchedBackAfterMicReturned)
            case .reasserted: break
            }
        case let .recordReplacement(d):
            persistReplacement(d.uid)
            status = .waitingForMic(original: r.original.name)
        case let .voidRecord(d):
            let original = r.original
            dropOwnership()
            mode = .voided(original: original, changedTo: d.uid)
            status = .overridden(by: d.name)
            onNotice?(.manualChange(device: d.name))
        }
    }

    /// A switch back to the Mic was not written or not read back: the monitor retries while the
    /// default stays where it is; the record and macOS's pick as the replacement stay (review
    /// 2026-11-05 #1, #3; earlier the failure was taken for your change, #5).
    private func switchBackFailed(_ reason: SystemInputPlan.SwitchBackReason) {
        guard case var .meeting(m) = mode, let r = record else { return }
        let firstOfRound = m.retryDevice == nil
        m.switchBackFailed(reason, current: deps.hal.snapshot().defaultInput, now: now)
        mode = .meeting(m)
        persistReplacement(m.replacementUID)
        guard let d = m.retryDevice else { status = .holding(original: r.original.name); return }
        status = .switchBackFailed(current: d.name, retrying: true)
        if firstOfRound { onNotice?(.switchBackFailed(device: d.name)) }
    }

    /// Deferred / pending decisions. `snap`: what the monitor just looked at.
    private func apply(_ d: SystemInputPlan.DeferredDecision, snapshot snap: SystemInputPlan.Snapshot) {
        guard let r = record else { return }
        switch d {
        case .wait:
            setDeferredStatus(r, snap)
        case .noTarget:
            status = .noRestoreTarget
        case .dropRecord:
            dropOwnership()
            mode = .none
            status = .idle
        case let .restore(t):
            if case .writeFailed = performRestore(t) { setDeferredStatus(r) }   // retried next refresh
        case .switchToMic:
            // The Mic is back with the call on (deferred / pending): silence beats the original
            // voice; the record stays until the call ends. A failed write is retried on the next
            // refresh, for up to contestWindow (the monitor counts), with one HUD notice.
            if writeMic() {
                onNotice?(.switchedBackAfterMicReturned)
                setDeferredStatus(r)
                return
            }
            var firstOfRound = false
            switch mode {
            case var .deferred(m):
                firstOfRound = m.retrySince == nil
                m.switchBackFailed(now: now)
                mode = .deferred(m)
            case var .pending(m):
                firstOfRound = m.retrySince == nil
                m.switchBackFailed(now: now)
                mode = .pending(m)
            default:
                break
            }
            let fresh = deps.hal.snapshot()
            setDeferredStatus(r, fresh)
            if firstOfRound, let cur = fresh.defaultInput, !MicPolicy.isTalkTalkMic(cur) {
                onNotice?(.switchBackFailed(device: cur.name))
            }
        }
    }

    /// The deferred / pending status line, always from the default input now (`snap`, else a fresh
    /// snapshot): TalkTalk Mic → "仍是 TalkTalk Mic"; a physical device → what it really is, the Mic
    /// absent or not (review of a7ef015 #1: every path that waits goes through here).
    private func setDeferredStatus(_ r: SysInputRecord, _ snap: SystemInputPlan.Snapshot? = nil) {
        let s = snap ?? deps.hal.snapshot()
        let lastRun: Bool
        if case .pending = mode { lastRun = true } else { lastRun = false }
        // Any non-Mic default says what it is (a virtual one macOS picked after the Mic vanished,
        // BlackHole, too: review of 37c505d #1), except a layer-4 virtual default (Tuwa after a
        // reboot), which keeps "上次的默认输入还没还原".
        if let cur = s.defaultInput, !MicPolicy.isTalkTalkMic(cur), MicPolicy.passesRule2(cur) || !lastRun {
            status = .deferredOnPhysical(current: cur.name, micAbsent: !s.micPresent, fromLastRun: lastRun)
        } else if s.defaultInput == nil, isDeferredStatus(status) {
            // No default input for a moment (macOS between devices): the last line stays, it is
            // not "仍是 TalkTalk Mic".
        } else if lastRun {
            status = .pendingFromLastRun(original: r.original.name)
        } else {
            status = .deferred(original: r.original.name)
        }
    }

    private func isDeferredStatus(_ s: Status) -> Bool {
        switch s {
        case .deferred, .deferredOnPhysical, .pendingFromLastRun: true
        default: false
        }
    }

    /// Restore now if it is ours to restore (`deferredDecision` with the call treated as ended).
    /// `userAskedNow`: your "现在还原"; if the write fails, the retries do not wait for the call.
    private func finishByRule(callEndedOverride: Bool, userAskedNow: Bool) -> EndResult {
        guard let r = record else { return .nothingToRestore }
        let snap = deps.hal.snapshot()
        tracker.update(snap, now: now)
        let ended = callEndedOverride || callEnded
        let d: SystemInputPlan.DeferredDecision
        // A running deferred/pending monitor sees this snapshot first (an armed layer 4 learns its
        // device, a stale replacement expires) and decides; review 2026-11-05 (a2).
        switch mode {
        case var .pending(m):
            d = m.observe(snap, tracker: tracker, callEnded: ended, now: now)
            mode = .pending(m)
            persist(m)
        case var .deferred(m):
            d = m.observe(snap, tracker: tracker, callEnded: ended, now: now)
            mode = .deferred(m)
            persist(m)
        default:
            d = SystemInputPlan.deferredDecision(original: r.original, replacementUID: currentReplacement(r),
                                                 snapshot: snap, callEnded: ended)
        }
        let replacement = currentReplacement(r)
        switch d {
        case let .restore(t):
            let result = performRestore(t)
            if case .writeFailed = result {
                // Retry from the deferred state on the next refresh (listener or 2 s poll); a
                // restore you asked for now does not start waiting for the call to end.
                if userAskedNow { restoreWithoutWaiting = true }
                keepWaiting(r, replacement: replacement)
            }
            return result
        case .dropRecord:
            dropOwnership()
            mode = .none
            status = .idle
            return .nothingToRestore
        case .noTarget:
            // An explicit/automatic restore request remains immediate when a physical device
            // returns; neither this process nor the recovery guard should wait for the call.
            if userAskedNow { restoreWithoutWaiting = true }
            keepWaiting(r, replacement: replacement)
            status = .noRestoreTarget
            onNotice?(.noRestoreTarget)
            return .noRestoreTarget
        case .wait, .switchToMic:
            let alreadyWaiting: Bool
            switch mode {
            case .deferred, .pending: alreadyWaiting = true
            default: alreadyWaiting = false
            }
            // A temporarily missing default/device is still an immediate restore request once
            // the route is known again, not a request to wait for the ongoing call to end.
            if userAskedNow { restoreWithoutWaiting = true }
            keepWaiting(r, replacement: replacement)
            // From meeting mode, enterDeferred's own monitor has set the status (it knows more
            // than the plain decision above: a vanished Mic, a pending switch back).
            if alreadyWaiting { apply(d, snapshot: snap) }
            return .deferred
        }
    }

    /// The device macOS picked when TalkTalk Mic vanished, as the live monitor sees it now (never
    /// the record's copy while a monitor runs: it can be stale, review 2026-11-04 #1).
    private func currentReplacement(_ r: SysInputRecord) -> String? {
        switch mode {
        case let .meeting(m), let .suspended(m): return m.replacementUID
        case let .deferred(m), let .pending(m): return m.replacementUID
        case .none, .voided: return r.replacementUID
        }
    }

    /// Not restorable yet: wait in the deferred state (keeps `pending` if that is where we are).
    private func keepWaiting(_ r: SysInputRecord, replacement: String?) {
        switch mode {
        case .pending, .deferred:
            setDeferredStatus(r)
        default:
            enterDeferred(r, replacement: replacement)
        }
    }

    /// From meeting or suspended mode into the deferred state. One observation right away, so a
    /// replacement that went stale while nothing was observed (suspended, review F) is cleared
    /// and persisted now, not on the next refresh. Its decision waits for that refresh; only the
    /// status line follows it now (a vanished Mic or a pending switch back is not "仍是 TalkTalk Mic").
    private func enterDeferred(_ r: SysInputRecord, replacement: String?) {
        // A switch back that was failing in meeting mode goes on as the same round: no second
        // notice, the same cap (review of a7ef015 #2).
        var round: (since: Double?, gaveUp: Bool) = (nil, false)
        if case let .meeting(mm) = mode { round = (mm.retryStartedAt, mm.gaveUpSwitchingBack) }
        if case let .suspended(mm) = mode { round = (mm.retryStartedAt, mm.gaveUpSwitchingBack) }
        var m = SystemInputPlan.DeferredMonitor(original: r.original, replacementUID: replacement, config: deps.config,
                                                retrySince: round.since, switchBackGaveUp: round.gaveUp)
        let snap = deps.hal.snapshot()
        let t = now
        tracker.update(snap, now: t)
        let d = m.observe(snap, tracker: tracker, callEnded: false, now: t)
        mode = .deferred(m)
        persistReplacement(m.replacementUID)
        setDeferredStatus(r, snap)   // its decision (a switch back, a restore) waits for the next refresh
        _ = d
    }

    /// The fixed order: passthrough off → write → read back → delete record → tell the guard → unlock.
    private func performRestore(_ t: SystemInputPlan.RestoreTarget) -> EndResult {
        deps.closePassthrough()
        guard deps.hal.writeAndConfirm(uid: t.device.uid) else { return .writeFailed }
        let voidTo = voidAfterRestore
        dropOwnership()
        if let o = voidTo, meetingModeOn { mode = .voided(original: o, changedTo: t.device.uid) } else { mode = .none }
        status = .idle
        onNotice?(.restored(device: t.device.name, note: t.notice))
        return .restored(device: t.device.name)
    }

    /// Delete record → guard quits → unlock.
    private func dropOwnership() {
        // The default input is no longer the Mic here (restored, you changed it, or the switch to
        // it failed): 'ttmm' back to 0 so macOS cannot pick the Mic by itself (§8.6).
        MeetingModeGate.release(deps.meetingSwitch, defaultInputUID: deps.hal.defaultInputUID())
        store.delete()
        record = nil                    // restoreWithoutWaiting goes with it
        recordDirty = false
        voidAfterRestore = nil
        let g = guardHandle
        guardHandle = nil
        g?.quit()
        lock.release()
    }

    /// Entry failed after the record was written: same as dropping it.
    private func abandonOwnership() {
        dropOwnership()
        mode = .none
        status = .idle   // no record: nothing that implies one may stay on the menu
    }

    /// Quit with the restore still pending: the guard keeps the lock and gets EOF.
    private func handOffToGuard() {
        if recordDirty, let r = record {
            writeRecord(r)
            if recordDirty { onLog?("handing off with an out-of-date restore record on disk") }
        }
        recordDirty = false
        let g = guardHandle
        guardHandle = nil
        if g == nil, record != nil {
            // No guard (it died and could not be restarted): leave the record for layer 4.
            lock.detach()
        } else {
            g?.handOff()
            lock.detach()
        }
        record = nil
        mode = .none
    }

    /// A deferred/pending monitor's learned state (replacement, layer-4 device) into the record.
    private func persist(_ m: SystemInputPlan.DeferredMonitor) {
        guard var r = record else { return }
        guard r.replacementUID != m.replacementUID || r.layer4UID != m.layer4UID
              || (r.layer4ArmedUntilUptime != nil) != m.layer4Armed else { return }
        r.replacementUID = m.replacementUID
        r.layer4UID = m.layer4UID
        setArmDeadline(&r, m)
        writeRecord(r)
    }

    /// The layer-4 deadline for the guard: `now` is HostClock (CLOCK_UPTIME_RAW) seconds, the same
    /// in the guard during this boot; the boot session tells a value from an earlier boot.
    private func setArmDeadline(_ r: inout SysInputRecord, _ m: SystemInputPlan.DeferredMonitor) {
        r.layer4ArmedUntilUptime = m.layer4ArmedUntil
        r.bootSessionUUID = m.layer4ArmedUntil == nil ? nil : SysInputProcess.bootSessionUUID()
    }

    private func persistReplacement(_ uid: String?) {
        guard var r = record, r.replacementUID != uid else { return }
        r.replacementUID = uid
        writeRecord(r)
    }

    /// `r` becomes the record now; the disk copy follows when it can (`recordDirty`).
    private func writeRecord(_ r: SysInputRecord) {
        record = r
        do {
            try store.write(r)
            recordDirty = false
        } catch {
            if !recordDirty { onLog?("could not write the restore record; will retry") }
            recordDirty = true
        }
    }

    @discardableResult
    private func launchGuard() -> Bool {
        guard lock.isHeld else { return false }
        guardGeneration += 1
        let generation = guardGeneration
        do {
            guardHandle = try deps.launcher.launch(lockFD: lock.fd, paths: deps.paths) { [weak self] status in
                Task { @MainActor in self?.guardExited(status, generation: generation) }
            }
            return true
        } catch {
            return false
        }
    }

    /// "app 发现它退出就重启它" (at most 5 restarts a minute).
    private func guardExited(_ status: Int32, generation: Int) {
        // Only the guard we launched last: a late notice from one we already let go (quit, then
        // a new guard for the next meeting) must not close the new guard's pipe.
        guard generation == guardGeneration, guardHandle != nil else { return }
        guard !quitting, ownsRecord, var r = record else { return }
        let old = guardHandle
        guardHandle = nil
        old?.handOff()   // closes our end of its pipe (no fd leak)
        let t = now
        guardRestarts = guardRestarts.filter { t - $0 < 60 } + [t]
        guard guardRestarts.count <= 5, launchGuard() else { return }
        r.guardPID = guardHandle?.pid
        writeRecord(r)
    }

    /// Layer 4: last run's record. Signal the old guard only if it runs exactly the executable the
    /// record names; leave a live other build alone.
    private func takeOver(snapshot snap: SystemInputPlan.Snapshot) {
        guard !ownsRecord, case .none = mode, let rec = store.read() else { return }
        if !lock.tryAcquire() {
            if rec.writerPID != getpid(), rec.writerPID > 0, deps.pidRuns(rec.writerPID, rec.executablePath) {
                status = .otherInstanceManages
                return
            }
            if let g = rec.guardPID, g > 0, deps.pidRuns(g, rec.executablePath) {
                deps.terminate(g)
                _ = lock.tryAcquire(timeout: 2)
            }
            guard lock.isHeld else {
                status = .otherInstanceManages
                return
            }
        }
        var r = rec
        r.writerBundleID = deps.bundleID
        r.writerPID = getpid()
        r.executablePath = deps.executablePath
        r.guardPID = nil
        // Layer 4 saw nothing before now: the virtual device that is the default now is the only
        // one the virtual rule covers (the guard reads it from the record, review A/C2). No default
        // input right now: the first one that appears (review (a)).
        let t = now
        let m = SystemInputPlan.DeferredMonitor.takeover(original: r.original, replacementUID: r.replacementUID,
                                                         snapshot: snap, now: t, config: deps.config)
        r.layer4UID = m.layer4UID
        setArmDeadline(&r, m)
        // The Mic is still the default (call on): keep it selectable (a Mic that re-entered the
        // list since has 'ttmm' = 0 again). Best effort, no waiting.
        if snap.defaultIsMic { _ = MeetingModeGate.makeMicSelectable(deps.meetingSwitch, timeout: 0) }
        record = r
        if launchGuard() { r.guardPID = guardHandle?.pid }
        writeRecord(r)
        callState = CallEndRule.State(scope: Set(r.meetingApps))
        callEnded = false
        refreshCall()
        mode = .pending(m)
        status = .pendingFromLastRun(original: r.original.name)
    }
}
