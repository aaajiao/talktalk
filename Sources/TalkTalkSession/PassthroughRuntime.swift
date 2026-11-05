import Foundation
import TalkTalkCore

/// Per-session wiring for the shared tap, PTT and passthrough. No audio device is opened here:
/// the app supplies the Feed state sink and playout yielding implementation. All callbacks must
/// enqueue work, never wait for another queue. The gate is also safe for the audio worker's admit.
public final class PassthroughRuntime: @unchecked Sendable {
    public enum Cue: Sendable { case open, close }
    public struct MeetingAudioSnapshot: Sendable {
        /// nil means no current physical-key observation, not a released key.
        public let held: Bool?
        public let recordingActive: Bool
        public let busy: Bool
        public let originalOpen: Bool
        public let hardwarePollFresh: Bool
        public let originalReadiness: PassthroughPolicy.Verdict
        public let translationReadiness: PassthroughPolicy.Verdict

        /// Display eligibility only. A fresh hardware poll still owns the actual gate open.
        public var canRestoreOriginal: Bool {
            held == false && !busy && hardwarePollFresh && originalReadiness.isAvailable
        }
    }
    public let gate: PassthroughGate
    public let pushToTalk: PushToTalkKey
    public let passthrough: PassthroughKey
    public let scope: KeyTap.Scope
    private let lock: NSRecursiveLock
    /// Shared with the PTT callback, protected by the runtime lock. A pending action is work
    /// even before the controller's async action consumer has entered SpeakPipeline.
    private final class AutomaticOriginal: @unchecked Sendable {
        let enabled: Bool
        var held: Bool?
        var translationBusy = true
        var pendingActions = 0
        init(enabled: Bool) { self.enabled = enabled }
    }
    private let automatic: AutomaticOriginal
    private var tap: KeyTap?
    private var stopped = false
    private var lastHardwarePoll: HostTime?
    private let recordsIntervals: Bool
    private let log: EventLog?
    private var lastAvailability: PushToTalkKey.Availability?

    public init(profile: PolicyProfile.Speak, scope: KeyTap.Scope = .meeting,
                useAltKey: Bool = false, diagnosticsEnabled: Bool = false, automaticOriginal: Bool = false,
                interaction: PushToTalkKey.Interaction = .hold,
                sink: any PassthroughStateSink, playout: (any PassthroughPlayoutYielding)? = nil,
                log: EventLog? = nil,
                onPushToTalk: @escaping @Sendable (PushToTalkKey.Action) -> Void,
                onHUD: @escaping @Sendable (HUDModel.PassthroughEvent) -> Void = { _ in },
                onCue: @escaping @Sendable (Cue) -> Void = { _ in },
                onStartMic: @escaping @Sendable () -> Void = {},
                onOpenChange: @escaping @Sendable (Bool, HostTime) -> Void = { _, _ in }) {
        self.scope = scope; self.log = log
        let lock = NSRecursiveLock()
        self.lock = lock
        let automatic = AutomaticOriginal(enabled: automaticOriginal && scope == .meeting)
        self.automatic = automatic
        #if TALKTALK_DEV
        recordsIntervals = true
        #else
        recordsIntervals = diagnosticsEnabled
        #endif
        let notices = NoticeSink(log: log, onHUD: onHUD, onCue: onCue,
                                 onStartMic: onStartMic, onOpenChange: onOpenChange)
        let gate = PassthroughGate(config: .init(profile: profile.passthrough), sink: sink, playout: playout,
                                  onNotice: { notices.receive($0) })
        self.gate = gate
        pushToTalk = PushToTalkKey(config: .init(speak: profile), interaction: interaction, onAction: { action in
            if automatic.enabled, case let .machine(machine) = action {
                lock.withLock {
                    automatic.pendingActions += 1
                    let time: HostTime
                    switch machine {
                    case let .began(at), let .released(at, _), let .cancelled(at), let .tapped(at), let .doubleTapped(at): time = at
                    }
                    gate.updateFacts(at: time) { $0.pushToTalkActive = true }
                }
            }
            onPushToTalk(action)
        })
        // The profile key is restricted to right Command or right Control.
        let config = PassthroughKeyMachine.Config(profile: profile.passthrough, useAltKey: useAltKey,
                                                  recordsIntervals: recordsIntervals)!
        passthrough = PassthroughKey(config: config, gate: gate)
        tap = KeyTap(scope: scope) { [weak self] in self?.handle($0) }
    }

    /// Start or resume only after the owner has provided current guard/device facts. Onboarding
    /// explicitly allows PTT outside a meeting; passthrough still requires meetingModeActive.
    public func start() throws {
        let canStart = lock.withLock { !stopped }
        guard canStart else { return }
        try tap?.start()
    }

    /// Close before waiting for the tap thread; never wait while holding the runtime lock.
    public func suspend(at time: HostTime) {
        lock.withLock {
            automatic.held = nil
            lastHardwarePoll = nil
            gate.systemEvent(.sleep, at: time)
            gate.updateFacts(at: time) { $0.awaitingAudioConfirmation = true; $0.tapHealthy = false }
            pushToTalk.stop(at: time)
        }
        tap?.stop()
    }

    public func stop(at time: HostTime = HostClock.now()) {
        let first = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            automatic.held = nil
            lastHardwarePoll = nil
            gate.systemEvent(.meetingModeEnded, at: time)
            gate.updateFacts(at: time) { $0.meetingModeActive = false; $0.tapHealthy = false }
            pushToTalk.stop(at: time)
            return true
        }
        guard first else { return }
        tap?.stop()
        log?.event("pt.prearm_cancels", ["count": .int(passthrough.prearmCancels)], at: time)
        log?.event("pt.lost_key_up", ["count": .int(passthrough.lostKeyUps)], at: time)
        if recordsIntervals {
            let histogram = passthrough.intervals
            var fields: [String: EventLog.Value] = ["binMs": .int(IntervalHistogram.binMs),
                "overflow": .int(histogram.overflow), "total": .int(histogram.total)]
            for (i, count) in histogram.counts.enumerated() { fields["bin_\(i)"] = .int(count) }
            log?.event("pt.intervals", fields, at: time)
        }
    }

    deinit { stop() }

    public var lastCloseHostTime: HostTime? { gate.lastCloseHostTime }
    public var usesAutomaticOriginal: Bool { automatic.enabled }
    /// Unknown hardware state is held/closed until the next hardware poll proves release.
    public var translationHeld: Bool { lock.withLock { automatic.held != false } }
    public var translationBusy: Bool {
        lock.withLock { automatic.translationBusy || automatic.pendingActions > 0 }
    }

    /// Keep the held/work/gate view in one runtime turn. Unlike gate.isOpen, reading this
    /// snapshot has no side effects: it neither opens, renews nor closes the audio gate.
    public func meetingAudioSnapshot(at time: HostTime? = nil) -> MeetingAudioSnapshot {
        lock.withLock {
            let now = time ?? HostClock.now()
            let state = gate.state
            var facts = gate.facts
            facts.pushToTalkActive = false // intentional translation is not a device failure
            let lease = UInt64(max(0, gate.config.leaseMs)) * 1_000_000
            let fresh = !stopped && lastHardwarePoll.map { now >= $0 && now - $0 < lease } == true
            return MeetingAudioSnapshot(
                held: automatic.held,
                recordingActive: pushToTalk.recordingActive,
                busy: automatic.translationBusy || automatic.pendingActions > 0 || pushToTalk.isActive,
                originalOpen: state.open && state.source == .mic && now >= state.openAt
                    && now < state.leaseUntil && now < state.deadline,
                hardwarePollFresh: fresh,
                originalReadiness: PassthroughPolicy.evaluate(facts, allowInSpeakerMode: gate.config.allowInSpeakerMode),
                translationReadiness: PassthroughPolicy.evaluate(facts, allowInSpeakerMode: true))
        }
    }

    public func setTranslationBusy(_ busy: Bool, at time: HostTime = HostClock.now()) {
        lock.withLock {
            guard !stopped, automatic.enabled else { return }
            automatic.translationBusy = busy
            reconcileAutomatic(at: time)
        }
    }

    /// Acknowledge each delivered .machine action after SpeakPipeline.handle has completed.
    /// A stale idle notification cannot bypass other queued key actions or a physical hold.
    public func actionHandled(translationBusy: Bool, at time: HostTime = HostClock.now()) {
        lock.withLock {
            guard !stopped, automatic.enabled else { return }
            automatic.pendingActions = max(0, automatic.pendingActions - 1)
            automatic.translationBusy = translationBusy
            reconcileAutomatic(at: time)
        }
    }

    /// External facts cannot override tap health, secure input or the PTT state owned here.
    public func updateFacts(at time: HostTime, _ update: (inout PassthroughPolicy.Facts) -> Void) {
        lock.withLock {
            guard !stopped else { return }
            gate.updateFacts(at: time) { facts in
                let health = facts.tapHealthy, secure = facts.secureInput, active = facts.pushToTalkActive
                update(&facts)
                facts.tapHealthy = health; facts.secureInput = secure; facts.pushToTalkActive = active
                if automatic.enabled { facts.settingEnabled = true }
            }
            refreshAvailability(at: time)
            reconcileAutomatic(at: time)
        }
    }
    public func systemEvent(_ event: PassthroughSystemEvent, at time: HostTime) {
        lock.withLock {
            log?.event("key.system_event", ["reason": .tag(event.rawValue)], at: time)
            automatic.held = nil
            lastHardwarePoll = nil
            gate.systemEvent(event, at: time)
            // A device/lifecycle transition cancels the current PTT as well. The owner supplies
            // fresh facts before enabling it again; a held key cannot start a replacement press.
            gate.updateFacts(at: time) { $0.awaitingAudioConfirmation = true }
            refreshAvailability(at: time)
        }
    }
    public func vad(speech: Bool, at time: HostTime, reportedAt: HostTime = HostClock.now()) {
        lock.withLock {
            pushToTalk.vad(speech: speech, at: time)
            if speech { gate.vadSpeechStarted(onset: time, now: reportedAt) }
            else { gate.vadSpeechEnded(at: time) }
        }
    }

    /// Only the tap calls this in production. Tests use the same route without installing a tap.
    func handle(_ event: KeyInputEvent) {
        lock.withLock {
            guard !stopped else { return }
            let wasActive = pushToTalk.isActive
            if case .tapDisabled = event.kind { lastHardwarePoll = nil }
            if automatic.enabled {
                switch event.kind {
                case let .flagsChanged(code, flags) where code == KeyCode.rightOption:
                    let down = ModifierKey.rightOption.isDown(in: flags)
                    if down || event.source == .hidSystem { automatic.held = down }
                case .keyDown(let code, _) where code == KeyCode.rightOption:
                    automatic.held = true
                case .keyUp(let code) where code == KeyCode.rightOption && event.source == .hidSystem:
                    automatic.held = false
                case .poll(let snapshot) where event.source == .hidSystem:
                    automatic.held = snapshot.isDown(.rightOption) || ModifierKey.rightOption.isDown(in: snapshot.flags)
                case .tapDisabled: automatic.held = nil
                default: break
                }
                // This closes the RT state before availability callbacks, PTT actions or any
                // async controller work, including a press which the PTT guard later refuses.
                reconcileAutomatic(at: event.time)
            }
            gate.updateFacts(at: event.time) { facts in
                switch event.kind {
                case .tapEnabled: facts.tapHealthy = true
                case .tapDisabled: facts.tapHealthy = false
                case let .poll(snapshot): facts.secureInput = snapshot.secureInput
                default: break
                }
            }
            refreshAvailability(at: event.time)
            if case .flagsChanged(let code, let flags) = event.kind, code == KeyCode.rightOption {
                // Only our PTT key's status, never typed keys or a raw modifier history.
                log?.event("key.option_seen", ["down": .bool(ModifierKey.rightOption.isDown(in: flags)),
                    "sole_modifier": .bool(ModifierKey.rightOption.isSoleHeldModifier(in: flags)),
                    "tap_healthy": .bool(gate.facts.tapHealthy == true),
                    "secure_input": .bool(gate.facts.secureInput == true)], at: event.time)
            }
            pushToTalk.handle(event)
            if wasActive, case .mustRelease = pushToTalk.phase, case .poll(let snapshot) = event.kind {
                let extra = snapshot.otherKeysDown(than: .rightOption)
                let modifiers = Set(KeyCode.modifiers)
                log?.event("key.poll_chord", [
                    "ordinary_count": .int(extra.subtracting(modifiers).count),
                    "modifier_count": .int(extra.intersection(modifiers).count),
                    "left_option_down": .bool(snapshot.keysDown.contains(KeyCode.option)),
                    "right_option_down": .bool(snapshot.keysDown.contains(KeyCode.rightOption)),
                    "flags_left_option": .bool(snapshot.flags.contains(.deviceLeftOption)),
                    "flags_right_option": .bool(snapshot.flags.contains(.deviceRightOption)),
                    "flags_other_modifier": .bool(!snapshot.flags.intersection(.held)
                        .subtracting([.deviceRightOption, .option]).isEmpty),
                    "secure_input": .bool(snapshot.secureInput == true)
                ], at: event.time)
            }
            // Poll every non-idle phase, including releasing and mustRelease. The tap's timer
            // keeps running even with no held key, so lost key-ups cannot strand either machine.
            pushToTalk.tick(now: event.time)
            if automatic.enabled {
                let poll: Bool
                if case .poll = event.kind { poll = event.source == .hidSystem } else { poll = false }
                reconcileAutomatic(at: event.time, confirmedPoll: poll)
            } else {
                gate.updateFacts(at: event.time) { $0.pushToTalkActive = pushToTalk.isActive }
                passthrough.handle(event)
                passthrough.tick(now: event.time)
            }
            gate.tick(now: event.time)
            if case .poll = event.kind, event.source == .hidSystem { lastHardwarePoll = event.time }
        }
    }

    /// Only a fresh hardware poll may open or renew. UI/work callbacks can close, but cannot
    /// extend a lease while KeyTap's polling thread is stalled.
    private func reconcileAutomatic(at time: HostTime, confirmedPoll: Bool = false) {
        guard automatic.enabled, !stopped else { return }
        let blocked = automatic.held != false || automatic.translationBusy
            || automatic.pendingActions > 0 || pushToTalk.isActive
        gate.updateFacts(at: time) { $0.settingEnabled = true; $0.pushToTalkActive = blocked }
        if !blocked, confirmedPoll { _ = gate.confirmAutomatic(at: time) }
    }

    private func refreshAvailability(at time: HostTime) {
        let facts = gate.facts
        let availability: PushToTalkKey.Availability
        if facts.secureInput != false { availability = .blocked(.secureInput) }
        else if facts.awaitingAudioConfirmation != false || facts.tapHealthy != true || facts.selfTestRunning != false {
            availability = .blocked(.awaitingAudioConfirmation)
        }
        else if facts.physicalMicPassesRule2 != true { availability = .blocked(.noMeetingReader) }
        else if scope == .onboarding { availability = .allowed }
        else if facts.meetingModeActive != true { availability = .blocked(.notInSession) }
        else if facts.micGuard == .meetingUsesPhysicalMic { availability = .blocked(.meetingUsesPhysicalMic) }
        else if facts.micGuard != .green { availability = .blocked(.noMeetingReader) }
        else { availability = .allowed }
        if availability != lastAvailability {
            let reason: String
            switch availability { case .allowed: reason = "allowed"; case .blocked(let why): reason = String(describing: why) }
            log?.event("key.availability", ["state": .tag(reason), "tap_healthy": .bool(facts.tapHealthy == true),
                "secure_input": .bool(facts.secureInput == true), "audio_pending": .bool(facts.awaitingAudioConfirmation != false),
                "physical": .bool(facts.physicalMicPassesRule2 == true), "self_test": .bool(facts.selfTestRunning != false)], at: time)
            lastAvailability = availability
        }
        pushToTalk.setAvailability(availability, at: time)
    }

    private struct NoticeSink: Sendable {
        let log: EventLog?
        let onHUD: @Sendable (HUDModel.PassthroughEvent) -> Void
        let onCue: @Sendable (Cue) -> Void
        let onStartMic: @Sendable () -> Void
        let onOpenChange: @Sendable (Bool, HostTime) -> Void
        func receive(_ notice: PassthroughNotice) {
            if let event = notice.hudEvent { onHUD(event) }
            switch notice {
            case .startMic: onStartMic()
            // Existing gate semantics: cueMs starts at this request, not at device playback.
            // MonitorOutput can enqueue later or decline it. Never wait on the key thread.
            case .playOpenCue: onCue(.open)
            case .playCloseCue: onCue(.close)
            case let .opened(time, wait, _):
                log?.event("pt.open", ["waitMs": .int(wait)], at: time); onOpenChange(true, time)
            case let .closed(time, reason, held):
                log?.event("pt.close", ["reason": .tag(reason.tag), "heldMs": .int(held)], at: time)
                onOpenChange(false, time)
            case let .refused(reason): log?.event("pt.deny", ["reason": .tag(reason.tag)])
            case .waitingForClause, .countdown, .cancelled: break
            }
        }
    }
}
