import Foundation

/// The rules of the system default input switch (ARCHITECTURE.md §8.6, §3.6, §16 decision 4), as
/// pure functions and small value-type state machines. `SystemInputSwitcher` (app) and
/// `SysInputGuard` (`--sysinput-guard`) only read Core Audio, feed snapshots in, and carry out
/// what comes back. Every comparison is by UID.
///
/// What is in here:
///   - `restoreTarget`: original → built-in → other MicPolicy candidates → other physical inputs →
///     nothing (HUD red). Never TalkTalk Mic or any virtual device.
///   - `entryOriginal`: which device the record names when meeting mode starts.
///   - `Tracker`: device arrivals, Mic vanish/return, the last physical default input.
///   - `MeetingMonitor`: classifies a switch-away in meeting mode (device inserted ≤3 s → switch
///     back once; Mic vanished → wait; anything else → manual, record void; re-switched within 10 s
///     → stop contesting).
///   - `deferredDecision` / `DeferredMonitor`: "only write when it is ours to restore", used after
///     meeting mode ended with a call still on, by the guard after its pipe hits EOF, and by the
///     next launch (layer 4).
///   - `noRecordInvariant`: TalkTalk Mic as default input with no record anywhere → put it back.
public enum SystemInputPlan {
    public typealias Device = MicPolicy.Device

    // MARK: configuration

    public struct Config: Sendable, Equatable {
        /// A device that became default input ≤ this long after it appeared in `Devices` counts as
        /// macOS's automatic switch (3 s until M0-T9 measures ear4).
        public var insertWindow: Double = 3
        /// Switched away again within this long after we switched back → stop contesting, manual.
        public var contestWindow: Double = 10
        /// After TalkTalk Mic vanishes, macOS picks another default within ~35 ms (M0-T8 d2); a
        /// change within this window is "macOS picked it", not you.
        public var micVanishSettle: Double = 3
        /// Poll period backing the property listeners.
        public var pollInterval: Double = 2
        /// Layer 4 waits this long after the Feed is attached before looking at the record.
        public var launchSettle: Double = 2
        /// A takeover that saw no default input: a default appearing within this long counts as
        /// macOS's pick (M0-T8 d2: 0–35 ms), later ones as yours (review 2026-11-05 (a1)).
        public var layer4ArmWindow: Double = 1
        /// Entering meeting mode on driver ≥ 0.2.0: how long to wait for TalkTalk Mic's
        /// CanBeDefaultDevice to become 1 after writing 'ttmm' = 1.
        public var micSelectableTimeout: Double = 1
        /// Removing an unused Mic helps restore input, but a selectable Mic may be chosen
        /// again by macOS when it reappears. Stable selectability from driver 0.2.3 means the
        /// driver layer alone is not an independent recovery guarantee; retain the app/guard.
        public var driverLayerCounts: Bool = false

        public init() {}

        public static let `default` = Config()

        /// Settings text next to the switch: with the driver layer not counting, a crash with no
        /// relaunch leaves restoring to the guard and to the next launch.
        public var loginStartStronglyRecommended: Bool { !driverLayerCounts }
    }

    // MARK: device references (what the record stores)

    public struct DeviceRef: Sendable, Equatable, Hashable, Codable {
        public var uid: String
        public var name: String
        public var transport: String

        public init(uid: String, name: String, transport: String) {
            self.uid = uid
            self.name = name
            self.transport = transport
        }

        public init(_ d: Device) { self.init(uid: d.uid, name: d.name, transport: d.transport) }

        /// Judged from the stored values alone (the device may be gone).
        public var looksVirtual: Bool {
            MicPolicy.exclusion(Device(uid: uid, name: name, transport: transport)) != nil
        }
    }

    public struct Snapshot: Sendable, Equatable {
        /// Input devices in `kAudioHardwarePropertyDevices` (hidden ones are not there).
        public var devices: [Device]
        public var defaultInput: Device?
        /// How many `kAudioHardwarePropertyServiceRestarted` notifications the HAL has seen
        /// (coreaudiod restarted). A change counts as a Mic vanish even when no snapshot caught the
        /// device list empty (review of 9d9b3a4 #2).
        public var serviceRestarts: Int

        public init(devices: [Device], defaultInput: Device?, serviceRestarts: Int = 0) {
            self.devices = devices
            self.defaultInput = defaultInput
            self.serviceRestarts = serviceRestarts
        }

        public var micPresent: Bool { devices.contains { $0.uid == MicPolicy.talkTalkMicUID } }
        public var defaultIsMic: Bool { MicPolicy.isTalkTalkMic(defaultInput) }
        public var mic: Device? { devices.first { $0.uid == MicPolicy.talkTalkMicUID } }
    }

    // MARK: restore target

    public struct RestoreTarget: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            case original
            case builtIn
            case candidate       // USB / Thunderbolt / PCI
            case otherPhysical   // Bluetooth, Continuity, anything else that passes rule 2
            case lastPhysical    // the no-record invariant's first choice
        }
        public enum Notice: Sendable, Equatable {
            /// The original was itself virtual (or ours): restored elsewhere, say so once.
            case originalWasVirtual(name: String)
            case originalMissing(name: String)
        }
        public var device: Device
        public var source: Source
        public var notice: Notice?
    }

    /// The restore order of §8.6. nil = nothing physical exists: do not write, HUD red.
    public static func restoreTarget(original: DeviceRef?, devices: [Device]) -> RestoreTarget? {
        var notice: RestoreTarget.Notice?
        if let o = original {
            let live = devices.first { $0.uid == o.uid }
            if o.looksVirtual || (live.map { !MicPolicy.passesRule2($0) } ?? false) {
                notice = .originalWasVirtual(name: o.name)
            } else if let live, live.isAlive {
                return RestoreTarget(device: live, source: .original, notice: nil)
            } else {
                notice = .originalMissing(name: o.name)
            }
        }
        return fallback(devices, notice: notice)
    }

    static func fallback(_ devices: [Device], notice: RestoreTarget.Notice?) -> RestoreTarget? {
        let candidates = devices.filter(MicPolicy.isCandidate)
        if let b = candidates.first(where: { $0.transport == "bltn" }) {
            return RestoreTarget(device: b, source: .builtIn, notice: notice)
        }
        if let c = candidates.first { return RestoreTarget(device: c, source: .candidate, notice: notice) }
        if let p = devices.first(where: MicPolicy.isUsable) {
            return RestoreTarget(device: p, source: .otherPhysical, notice: notice)
        }
        return nil
    }

    // MARK: entering meeting mode (step 2)

    public struct EntryOriginal: Sendable, Equatable {
        public enum Notice: Sendable, Equatable {
            /// The current default input is virtual (not TalkTalk Mic); the record names `restoreTo`.
            case currentDefaultVirtual(current: String, restoreTo: String)
        }
        public var original: DeviceRef
        public var reusedRecord: Bool
        public var notice: Notice?
    }

    /// Step 2 of "进入会议模式": an existing record (left by a crash) is reused; otherwise the
    /// current default input, unless it is TalkTalk Mic or virtual, then the last physical default
    /// input, then the restore order. nil = no physical input at all: do not switch.
    public static func entryOriginal(existing: DeviceRef?, currentDefault: Device?, lastPhysical: Device?,
                                     devices: [Device]) -> EntryOriginal? {
        if let existing { return EntryOriginal(original: existing, reusedRecord: true, notice: nil) }
        if let c = currentDefault, MicPolicy.isUsable(c) {
            return EntryOriginal(original: DeviceRef(c), reusedRecord: false, notice: nil)
        }
        let pick: Device?
        if let l = lastPhysical, let live = devices.first(where: { $0.uid == l.uid }), MicPolicy.isUsable(live) {
            pick = live
        } else {
            pick = fallback(devices, notice: nil)?.device
        }
        guard let pick else { return nil }
        var notice: EntryOriginal.Notice?
        if let c = currentDefault, !MicPolicy.isTalkTalkMic(c) {
            notice = .currentDefaultVirtual(current: c.name, restoreTo: pick.name)
        }
        return EntryOriginal(original: DeviceRef(pick), reusedRecord: false, notice: notice)
    }

    // MARK: device history

    /// Device arrivals, TalkTalk Mic vanish/return, the last physical default input. Runs all the
    /// time the app runs (and in the guard), so "DeviceWatcher 记下的上一个实体默认输入" lives here.
    public struct Tracker: Sendable, Equatable {
        public private(set) var knownUIDs: Set<String> = []
        /// uid → time it appeared in `Devices` (not filled from the very first snapshot).
        public private(set) var arrivals: [String: Double] = [:]
        public private(set) var lastPhysicalDefault: Device?
        public private(set) var micPresent = false
        public private(set) var micVanishedAt: Double?
        public private(set) var lastDefaultUID: String?
        /// The last Mic vanish (or coreaudiod restart); unlike `micVanishedAt` it stays once the Mic
        /// is back, so a default that macOS moved while no snapshot saw the Mic gone is still
        /// recognised (`isRestartPick`).
        public private(set) var lastVanishAt: Double?
        /// When the current default became the default, and what it was before.
        public private(set) var defaultSince: Double?
        public private(set) var previousDefaultUID: String?
        /// The Mic was the default again after `lastVanishAt` (in a later snapshot): from then on a
        /// change is yours, not macOS's re-arbitration.
        public private(set) var micDefaultSinceVanish = false
        private var lastServiceRestarts = 0
        private var started = false

        public init() {}

        public struct Changes: Sendable, Equatable {
            public var arrived: [String] = []
            public var micVanished = false
            public var micReturned = false
            public var defaultChanged = false
        }

        @discardableResult
        public mutating func update(_ s: Snapshot, now: Double) -> Changes {
            var ch = Changes()
            let uids = Set(s.devices.map(\.uid))
            let vanishBefore = lastVanishAt
            if started {
                for u in uids.subtracting(knownUIDs) {
                    arrivals[u] = now
                    ch.arrived.append(u)
                }
                if micPresent && !s.micPresent { ch.micVanished = true; micVanishedAt = now; lastVanishAt = now }
                if !micPresent && s.micPresent { ch.micReturned = true; micVanishedAt = nil }
                if s.serviceRestarts != lastServiceRestarts { lastVanishAt = now }
            } else if !s.micPresent {
                micVanishedAt = nil   // never seen: not "vanished"
            }
            lastServiceRestarts = s.serviceRestarts
            if lastVanishAt != vanishBefore { micDefaultSinceVanish = false }
            else if lastVanishAt != nil, s.defaultIsMic { micDefaultSinceVanish = true }
            for (u, t) in arrivals where now - t > 60 || !uids.contains(u) { arrivals[u] = nil }
            knownUIDs = uids
            micPresent = s.micPresent
            if let d = s.defaultInput, MicPolicy.isUsable(d) { lastPhysicalDefault = d }
            if s.defaultInput?.uid != lastDefaultUID {
                ch.defaultChanged = started
                previousDefaultUID = lastDefaultUID
                lastDefaultUID = s.defaultInput?.uid
                defaultSince = started ? now : nil
            }
            started = true
            return ch
        }

        public func arrived(_ uid: String, within window: Double, now: Double) -> Bool {
            guard let t = arrivals[uid] else { return false }
            return now - t <= window
        }

        /// `uid`, the default now, is the device macOS picked in a Mic vanish or coreaudiod restart
        /// that the snapshots may not have seen in between (d4t: devices [] and no default up to
        /// ~1 s, then built-in, the Mic ~20 ms later): it became the default within
        /// `micVanishSettle` after the vanish, moving from TalkTalk Mic or from no default, and the
        /// Mic has not been the default again since the vanish (then the change is yours).
        public func isRestartPick(_ uid: String, now: Double, config: Config) -> Bool {
            guard let v = lastVanishAt, !micDefaultSinceVanish, let since = defaultSince, lastDefaultUID == uid,
                  since >= v, since - v <= config.micVanishSettle, uid != MicPolicy.talkTalkMicUID else { return false }
            return previousDefaultUID == nil || previousDefaultUID == MicPolicy.talkTalkMicUID
        }

        /// A change to `uid` while TalkTalk Mic is absent that macOS made, not you.
        func isMicVanishReplacement(_ uid: String, now: Double, config: Config) -> Bool {
            if let v = micVanishedAt, now - v <= config.micVanishSettle { return true }
            return arrived(uid, within: config.insertWindow, now: now)
        }
    }

    // MARK: meeting mode

    public enum MeetingAction: Sendable, Equatable {
        case none
        /// Write TalkTalk Mic as default input again.
        case switchToMic(SwitchBackReason)
        /// TalkTalk Mic vanished and macOS picked this one: store it in the record (the guard and
        /// layer 4 may then restore over it).
        case recordReplacement(Device)
        /// You changed it: record void (not restored at the end), HUD yellow once.
        case voidRecord(changedTo: Device)
    }

    public enum SwitchBackReason: Sendable, Equatable {
        /// "X 接入后系统换了默认输入，已切回 TalkTalk Mic"
        case deviceInserted(Device)
        /// TalkTalk Mic came back (coreaudiod restart, wake, driver reload) and macOS did not re-select it.
        case micReturned
        /// Menu "切回 TalkTalk Mic", or resuming after sleep (no HUD notice on success: you asked).
        case reasserted
    }

    /// Classifies default-input changes while meeting mode owns the record (§8.6 "会议模式中默认
    /// 输入被改走"). Feed it every snapshot after `Tracker.update`.
    public struct MeetingMonitor: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            case holding
            case waitingForMic
            /// Manual change seen; we stopped acting until the user asks to switch back.
            case overridden(Device)
            /// Our switch back kept failing for `contestWindow` while the default stayed on this
            /// device (macOS's pick, not yours): no more retries, but the record and the replacement
            /// stay (restored at the end). Menu "切回 TalkTalk Mic" retries; the default moving to
            /// anything else goes by the usual rules (review 2026-11-05 #2, #1).
            case switchBackFailed(Device)
        }

        public private(set) var phase: Phase = .holding
        public private(set) var replacementUID: String?
        private var handledArrivals: Set<String> = []
        private var lastSwitchBackAt: Double?
        /// Our switch back to the Mic failed while the default was this device: try again while it
        /// stays there, and do not take it for your change (review 2026-11-05 #5). nil: not retrying.
        public private(set) var retryDevice: Device?
        private var retryReason: SwitchBackReason?
        /// When this round of retries began (the first failure); after `contestWindow` we stop.
        private var retrySince: Double?
        /// The Tracker's `lastVanishAt` this monitor has acted on: a newer one (a restart only the
        /// Tracker saw) starts a new round (review of a7ef015 #4).
        private var lastSeenVanishAt: Double?
        private var observedOnce = false
        public var config: Config

        /// For the hand-over to the deferred state (the same round goes on there).
        public var retryStartedAt: Double? { retrySince }
        public var gaveUpSwitchingBack: Bool {
            if case .switchBackFailed = phase { return true }
            return false
        }

        public init(config: Config = .default, replacementUID: String? = nil) {
            self.config = config
            self.replacementUID = replacementUID
        }

        /// "切回 TalkTalk Mic" from the menu, or resuming after sleep: act again.
        public mutating func reassert() {
            phase = .holding
            lastSwitchBackAt = nil
            clearRetry()
        }

        /// The `.switchToMic` just returned could not be written ('ttmm' refused, the Mic not
        /// selectable yet, the write not read back). `current`: the default input now, which is not
        /// yours (macOS's pick after a vanish or an insert, or the device you asked us to leave):
        /// it becomes the replacement, so ending restores over it and the deferred state / the
        /// guard keep switching back while the call is on (review of 54e9fca #3, of 9d9b3a4 #5).
        public mutating func switchBackFailed(_ reason: SwitchBackReason, current: Device?, now: Double) {
            guard let current, !MicPolicy.isTalkTalkMic(current) else { return }
            replacementUID = current.uid
            if retryDevice?.uid != current.uid { retrySince = now }   // a new round
            retryDevice = current
            retryReason = reason
            if case .deviceInserted = reason { lastSwitchBackAt = nil }   // nothing was switched
        }

        /// The `.switchToMic` just returned was written and read back.
        public mutating func switchBackSucceeded() {
            replacementUID = nil
            clearRetry()
        }

        private mutating func clearRetry() {
            retryDevice = nil
            retryReason = nil
            retrySince = nil
        }

        public mutating func observe(_ s: Snapshot, tracker: Tracker, now: Double) -> MeetingAction {
            if case .overridden = phase { return .none }
            let cur = s.defaultInput
            if !observedOnce {
                observedOnce = true
                lastSeenVanishAt = tracker.lastVanishAt               // older ones are not news
            } else if let v = tracker.lastVanishAt, v != lastSeenVanishAt {
                lastSeenVanishAt = v
                clearRetry()                                          // a new round
                if case .switchBackFailed = phase { phase = .holding }
            }
            if case let .switchBackFailed(d) = phase {
                if s.micPresent, cur?.uid == d.uid { return .none }
                phase = .holding   // the default moved, or the Mic vanished: the usual rules
            }
            // A replacement is valid only while the default input stays on it. Once the default
            // moves (macOS re-selects TalkTalk Mic when it returns, M0-T8 d3/d4, or you pick
            // something), it is no longer "the device macOS picked when the Mic vanished".
            if let r = replacementUID, let cur, cur.uid != r { replacementUID = nil }

            if !s.micPresent {
                phase = .waitingForMic
                clearRetry()   // a vanish starts a new round (review 2026-11-05 #2)
                guard let cur, !MicPolicy.isTalkTalkMic(cur), cur.uid != replacementUID else { return .none }
                if tracker.isMicVanishReplacement(cur.uid, now: now, config: config) {
                    replacementUID = cur.uid
                    return .recordReplacement(cur)
                }
                phase = .overridden(cur)
                return .voidRecord(changedTo: cur)
            }

            if let r = retryDevice, let reason = retryReason {
                guard let cur else { return .none }   // macOS's brief "none": keep the round
                if cur.uid == r.uid {
                    if let since = retrySince, now - since >= config.contestWindow {
                        clearRetry()
                        phase = .switchBackFailed(cur)
                        return .none
                    }
                    // Not reachable since a vanish clears the round; kept consistent anyway.
                    if phase == .waitingForMic { phase = .holding }
                    if case .deviceInserted = reason { lastSwitchBackAt = now }
                    return .switchToMic(reason)
                }
                clearRetry()
            }

            if phase == .waitingForMic {
                phase = .holding
                // replacementUID stays while the default is still on it (checked above): if the
                // switch back fails, ending still restores over macOS's pick (review 2026-11-05 #3).
                // No snapshot saw macOS's pick while the Mic was gone (the vanish showed no
                // default): it is the pick if it took over right after the vanish (9d9b3a4 #2).
                if let cur, replacementUID == nil, !MicPolicy.isTalkTalkMic(cur),
                   tracker.isRestartPick(cur.uid, now: now, config: config) {
                    replacementUID = cur.uid
                }
                guard let cur else { return .switchToMic(.micReturned) }
                // Driver 0.1.0 (M0-T8 d3/d4): macOS re-selected the Mic by itself. 0.2.0 never does
                // (d2t, d4t): we switch back.
                return MicPolicy.isTalkTalkMic(cur) ? .none : .switchToMic(.micReturned)
            }

            guard let cur, !MicPolicy.isTalkTalkMic(cur) else { return .none }

            // Still on the device we know is macOS's pick, no round running (a new round after a
            // restart only the Tracker saw, a7ef015 #4): switch back again.
            if cur.uid == replacementUID { return .switchToMic(.micReturned) }
            // A vanish no snapshot saw (coreaudiod restart between two refreshes, or only the
            // ServiceRestarted notification): macOS's pick, not yours (review of 9d9b3a4 #2).
            if tracker.isRestartPick(cur.uid, now: now, config: config) {
                replacementUID = cur.uid
                return .switchToMic(.micReturned)
            }

            if let t = lastSwitchBackAt, now - t < config.contestWindow {
                phase = .overridden(cur)
                return .voidRecord(changedTo: cur)
            }
            if let at = tracker.arrivals[cur.uid], now - at <= config.insertWindow {
                let key = "\(cur.uid)@\(at)"
                if !handledArrivals.contains(key) {
                    handledArrivals.insert(key)
                    lastSwitchBackAt = now
                    return .switchToMic(.deviceInserted(cur))
                }
            }
            phase = .overridden(cur)
            return .voidRecord(changedTo: cur)
        }
    }

    // MARK: deferred restore ("只在该还原时写")

    public enum DeferredDecision: Sendable, Equatable {
        case wait(WaitReason)
        case restore(RestoreTarget)
        /// Delete the record, write nothing.
        case dropRecord(DropReason)
        /// Ours to restore, but nothing physical exists: keep the record, HUD red, try again later.
        case noTarget
        /// TalkTalk Mic came back with the call still on and the default still on macOS's pick:
        /// make the Mic selectable and write it again; keep the record (`DeferredMonitor` only).
        case switchToMic
    }

    public enum WaitReason: Sendable, Equatable {
        case callOngoing
        case noDefaultInput   // the brief "none" macOS shows while it re-arbitrates
        /// TalkTalk Mic is gone with the call on: macOS's pick stays until the Mic returns (then
        /// `.switchToMic`) or the call ends (then restore). Only the app, if it runs, says so (menu
        /// `.deferredOnPhysical`); the driver (layer 3) cannot show anything.
        case micAbsent
        /// The device list just changed (a Mic vanish or return, coreaudiod restart): the original
        /// is not listed yet, so a restore now would land on a fallback. Up to `micVanishSettle`.
        case devicesSettling
        /// TalkTalk Mic is back but switching to it kept failing for `contestWindow`: no more
        /// tries, the default stays on macOS's pick until the call ends (record kept).
        case switchBackFailed
    }

    public enum DropReason: Sendable, Equatable {
        /// You (or something we did not see) changed it to a physical device: leave it.
        case changedTo(Device)
        /// The restore target already is the default input.
        case alreadyRestored
    }

    /// Restore if and only if the current default is TalkTalk Mic (once the call has ended), or the
    /// device macOS picked when TalkTalk Mic vanished. Anything else is your choice → drop the
    /// record only (§8.6 "你已经手动改成别的，就只删记录，不动它"), virtual devices included.
    ///
    /// `layer4UID` (§8.6 layer 4: the next launch, which saw none of the changes before it): the
    /// virtual device, other than the original, that was the default when the launch took the
    /// record over (after a reboot macOS may have picked Tuwa Mic before TalkTalk Mic existed).
    /// That device, and only that one, also counts as ours to restore, once the call has ended or
    /// TalkTalk Mic is gone. A device you pick after the takeover is seen, so it is your choice.
    public static func deferredDecision(original: DeviceRef, replacementUID: String?, snapshot s: Snapshot,
                                        callEnded: Bool, layer4UID: String? = nil) -> DeferredDecision {
        guard let cur = s.defaultInput else { return .wait(.noDefaultInput) }
        func restore() -> DeferredDecision {
            guard let t = restoreTarget(original: original, devices: s.devices) else { return .noTarget }
            return t.device.uid == cur.uid ? .dropRecord(.alreadyRestored) : .restore(t)
        }
        if MicPolicy.isTalkTalkMic(cur) { return callEnded ? restore() : .wait(.callOngoing) }
        if cur.uid == replacementUID { return restore() }
        if let l = layer4UID, cur.uid == l, !MicPolicy.passesRule2(cur), cur.uid != original.uid {
            return callEnded || !s.micPresent ? restore() : .wait(.callOngoing)
        }
        return .dropRecord(cur.uid == original.uid ? .alreadyRestored : .changedTo(cur))
    }

    /// `deferredDecision` plus the bookkeeping of which device macOS picked when TalkTalk Mic
    /// vanished while we were waiting (the guard and the app's deferred state both use it).
    public struct DeferredMonitor: Sendable, Equatable {
        public var original: DeviceRef
        public private(set) var replacementUID: String?
        public var config: Config
        /// Layer 4 only (the next launch's takeover, and the guard it hands to); see `deferredDecision`.
        public private(set) var layer4UID: String?
        /// A takeover that saw no default input: until this time (monotonic), the first default
        /// that appears becomes `layer4UID` (macOS's pick); after it, nothing more (review (a), (a1)).
        public private(set) var layer4ArmedUntil: Double?
        public var layer4Armed: Bool { layer4ArmedUntil != nil }
        /// Sticky "TalkTalk Mic vanished, waiting for it to return" (review 2026-11-05 #4, the
        /// guard through a coreaudiod restart): while the call is on we do not restore over macOS's
        /// pick, and when the Mic returns we switch back to it. Cleared once the Mic is the default
        /// again or the call ends. A monitor built with a replacement starts with it set (the
        /// switcher's hand-over, the guard, the next launch; review of 9d9b3a4 #3).
        public private(set) var micVanished = false
        /// When our first switch back of this round failed; after `contestWindow` we stop.
        public private(set) var retrySince: Double?
        public private(set) var switchBackGaveUp = false
        private var micSeen: Bool?
        private var lastSeenVanishAt: Double?
        private var observedOnce = false
        /// After a Mic vanish or return: until then a restore that would land on a fallback waits.
        private var settleUntil: Double?

        /// `retrySince` / `switchBackGaveUp`: a failing switch-back round carried over from meeting
        /// mode (review of a7ef015 #2).
        public init(original: DeviceRef, replacementUID: String?, config: Config = .default, layer4UID: String? = nil,
                    layer4ArmedUntil: Double? = nil, retrySince: Double? = nil, switchBackGaveUp: Bool = false) {
            self.original = original
            self.replacementUID = replacementUID
            self.config = config
            self.layer4UID = layer4UID
            self.layer4ArmedUntil = layer4UID == nil ? layer4ArmedUntil : nil
            self.micVanished = replacementUID != nil
            self.retrySince = retrySince
            self.switchBackGaveUp = switchBackGaveUp
        }

        /// The `.switchToMic` just returned was not written or not read back.
        public mutating func switchBackFailed(now: Double) {
            if retrySince == nil { retrySince = now }
        }

        private mutating func endRound() {
            retrySince = nil
            switchBackGaveUp = false
        }

        /// The monitor a launch takeover starts with: `layer4UID` from the current default, or,
        /// with no default input, armed for `config.layer4ArmWindow`.
        public static func takeover(original: DeviceRef, replacementUID: String?, snapshot s: Snapshot,
                                    now: Double, config: Config = .default) -> DeferredMonitor {
            DeferredMonitor(original: original, replacementUID: replacementUID, config: config,
                            layer4UID: layer4UID(original: original, snapshot: s),
                            layer4ArmedUntil: s.defaultInput == nil ? now + config.layer4ArmWindow : nil)
        }

        /// What a takeover records as `layer4UID`: the current default, if it is a virtual device
        /// other than TalkTalk Mic and the original.
        public static func layer4UID(original: DeviceRef, snapshot s: Snapshot) -> String? {
            guard let cur = s.defaultInput, !MicPolicy.isTalkTalkMic(cur), !MicPolicy.passesRule2(cur),
                  cur.uid != original.uid else { return nil }
            return cur.uid
        }

        public mutating func observe(_ s: Snapshot, tracker: Tracker, callEnded: Bool, now: Double) -> DeferredDecision {
            if let until = layer4ArmedUntil {
                if now > until {
                    layer4ArmedUntil = nil          // too late to be macOS's pick
                } else if s.defaultInput != nil {
                    layer4UID = Self.layer4UID(original: original, snapshot: s)
                    layer4ArmedUntil = nil
                }
            }
            var vanishedAgain = false
            if !observedOnce {
                observedOnce = true
                lastSeenVanishAt = tracker.lastVanishAt   // older ones are not news (a carried round stays)
            } else if let v = tracker.lastVanishAt, v != lastSeenVanishAt {
                vanishedAgain = true
            }
            if vanishedAgain {
                lastSeenVanishAt = tracker.lastVanishAt
                micVanished = true
                endRound()   // a vanish only the Tracker saw also starts a new round (a7ef015 #4)
            }
            // With the call on and the Mic gone (or just back), macOS may move its pick on to
            // another physical device right after the vanish: still macOS's, not yours. Only here:
            // in meeting mode the same rule would take back a change of yours within 3 s. The
            // alternative here is dropping the record during the call (review of a7ef015 #4).
            if micVanished, !callEnded, let r = replacementUID, let cur = s.defaultInput, cur.uid != r,
               MicPolicy.isUsable(cur), let v = tracker.lastVanishAt, let since = tracker.defaultSince,
               tracker.lastDefaultUID == cur.uid, since >= v, since - v <= config.micVanishSettle {
                replacementUID = cur.uid
            }
            // Valid only while the default input stays on it (see MeetingMonitor.observe).
            if let r = replacementUID, let cur = s.defaultInput, cur.uid != r { replacementUID = nil }
            if !s.micPresent, let cur = s.defaultInput, !MicPolicy.isTalkTalkMic(cur), cur.uid != replacementUID,
               tracker.isMicVanishReplacement(cur.uid, now: now, config: config) {
                replacementUID = cur.uid
            }
            // The Mic vanished and came back between two snapshots (or only ServiceRestarted told
            // us): the default that took over right after is macOS's pick (review of 9d9b3a4 #2).
            if s.micPresent, let cur = s.defaultInput, !MicPolicy.isTalkTalkMic(cur), cur.uid != replacementUID,
               tracker.isRestartPick(cur.uid, now: now, config: config) {
                replacementUID = cur.uid
                micVanished = true
            }
            if micSeen.map({ $0 != s.micPresent }) ?? !s.micPresent { settleUntil = now + config.micVanishSettle }
            if let v = tracker.lastVanishAt, v + config.micVanishSettle > (settleUntil ?? -.infinity) {
                settleUntil = v + config.micVanishSettle
            }
            micSeen = s.micPresent
            if !s.micPresent {
                micVanished = true
                endRound()   // a vanish starts a new round
            }

            if micVanished {
                let cur = s.defaultInput
                if callEnded || cur.map(MicPolicy.isTalkTalkMic) == true {
                    micVanished = false
                    endRound()
                } else if let cur, cur.uid == replacementUID {
                    // Same rule as meeting mode (layer 2): with the call on, silence beats the
                    // original voice. Mic gone: keep macOS's pick (restoring would not help, the
                    // meeting app hears a physical mic either way). Mic back: switch to it, for
                    // up to contestWindow after the first failure.
                    guard s.micPresent else { return .wait(.micAbsent) }
                    if let since = retrySince, now - since >= config.contestWindow { switchBackGaveUp = true }
                    return switchBackGaveUp ? .wait(.switchBackFailed) : .switchToMic
                }
            }

            let d = SystemInputPlan.deferredDecision(original: original, replacementUID: replacementUID,
                                                     snapshot: s, callEnded: callEnded, layer4UID: layer4UID)
            // Right after the device list changed the original may not be listed yet: do not
            // restore to (or call "already restored" on) a fallback until it had time to return.
            if let until = settleUntil, now < until, !s.devices.contains(where: { $0.uid == original.uid }) {
                switch d {
                case .restore, .noTarget, .dropRecord(.alreadyRestored): return .wait(.devicesSettling)
                default: break
                }
            }
            return d
        }
    }

    // MARK: ending meeting mode

    public enum EndDecision: Sendable, Equatable {
        /// Restore now if the call has ended, otherwise keep the record and restore when it does
        /// (the dialog's default button, auto end, end after sleep/lock).
        case whenCallEnds
        /// "现在还原" (the meeting app following the default will switch to the physical mic),
        /// logout and shutdown.
        case restoreNow
    }

    public enum EndStep: Sendable, Equatable {
        case restore
        case deferUntilCallEnds
    }

    public static func endStep(_ decision: EndDecision, callEnded: Bool) -> EndStep {
        switch decision {
        case .restoreNow: .restore
        case .whenCallEnds: callEnded ? .restore : .deferUntilCallEnds
        }
    }

    // MARK: the no-record invariant

    public enum InvariantDecision: Sendable, Equatable {
        case none
        case restore(RestoreTarget)
        case noTarget
    }

    /// talktalk runs, meeting mode is off, there is no restore record at all (ours, the other
    /// build's, a deferred one), we could take the lock, and yet the default input is TalkTalk Mic
    /// (whoever set it, including macOS re-selecting it when the Mic reappears, M0-T8 d3): put back
    /// the last physical default input, else the restore order. With a record, its owner handles it.
    public static func noRecordInvariant(snapshot s: Snapshot, meetingModeOn: Bool, recordExists: Bool,
                                         lockAvailable: Bool, lastPhysical: Device?) -> InvariantDecision {
        guard !meetingModeOn, !recordExists, lockAvailable, s.defaultIsMic else { return .none }
        if let l = lastPhysical, let live = s.devices.first(where: { $0.uid == l.uid }), MicPolicy.isUsable(live) {
            return .restore(RestoreTarget(device: live, source: .lastPhysical, notice: nil))
        }
        return fallback(s.devices, notice: nil).map(InvariantDecision.restore) ?? .noTarget
    }
}
