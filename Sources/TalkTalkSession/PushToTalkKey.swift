import Foundation
import TalkTalkCore

/// Runtime guard around the existing key machine. KeyTap drives handle/tick; VAD, availability
/// and commit reports may arrive on other threads. Callbacks receive the original event time.
public final class PushToTalkKey: @unchecked Sendable {
    public enum Interaction: Sendable { case hold, toggle }
    public enum BlockReason: Sendable, Equatable {
        case notInSession, meetingUsesPhysicalMic, awaitingAudioConfirmation, noMeetingReader, secureInput
    }
    public enum Availability: Sendable, Equatable { case allowed, blocked(BlockReason) }
    public enum Action: Sendable, Equatable {
        case machine(PushToTalkMachine.Action)
        case refused(at: HostTime, reason: BlockReason)
    }
    private let lock = NSRecursiveLock()
    private var machine: PushToTalkMachine
    private var availability: Availability = .blocked(.notInSession)
    private var acceptedPress = false
    public let interaction: Interaction
    private var toggleDownAt: HostTime?
    private var mouseButtonDown = false
    private let onAction: @Sendable (Action) -> Void

    public init(config: PushToTalkMachine.Config, interaction: Interaction = .hold,
                onAction: @escaping @Sendable (Action) -> Void) {
        machine = .init(config: config); self.interaction = interaction; self.onAction = onAction
        if interaction == .toggle { machine.discardUntilRelease() }
    }
    public var isActive: Bool { lock.withLock { machine.isActive || (interaction == .toggle && acceptedPress) } }
    public var recordingActive: Bool { lock.withLock { acceptedPress } }
    public var needsPolling: Bool { lock.withLock { machine.phase != .idle || (interaction == .toggle && acceptedPress) } }
    public var phase: PushToTalkMachine.Phase { lock.withLock { machine.phase } }

    public func setAvailability(_ value: Availability, at time: HostTime) {
        lock.withLock {
            availability = value
            if interaction == .toggle {
                if case .blocked = value, acceptedPress || toggleDownAt != nil { cancelToggle(at: time) }
                return
            }
            if case .blocked = value, acceptedPress {
                acceptedPress = false
                onAction(.machine(.cancelled(at: time)))
            }
        }
    }
    public func handle(_ event: KeyInputEvent) {
        lock.withLock {
            guard interaction == .toggle else { deliver(machine.handle(event)); return }
            switch event.kind {
            case .tapDisabled:
                _ = machine.handle(event)
                cancelToggle(at: event.time)
                return
            case .mouseDown:
                mouseButtonDown = true
                discardToggleGesture()
            case .scroll:
                discardToggleGesture()
            case let .poll(snapshot) where event.source == .hidSystem:
                mouseButtonDown = snapshot.mouseButtonDown
                if mouseButtonDown { discardToggleGesture() }
            default: break
            }
            let actions = machine.handle(event)
            let cleanKeyUp: Bool
            if case let .flagsChanged(code, flags) = event.kind {
                cleanKeyUp = event.source == .hidSystem && code == machine.config.key.keyCode
                    && flags.intersection(.held).isEmpty && machine.otherKeysDown.isEmpty && !mouseButtonDown
            } else { cleanKeyUp = false }
            deliverToggle(actions, cleanKeyUp: cleanKeyUp, source: event.source)
        }
    }
    public func tick(now: HostTime) {
        lock.withLock {
            let actions = machine.tick(now: now)
            if interaction == .toggle { deliverToggle(actions, cleanKeyUp: false, source: .other) }
            else { deliver(actions) }
        }
    }
    public func vad(speech: Bool, at time: HostTime) { lock.withLock { machine.vad(speech: speech, at: time) } }
    public func didCommit() { lock.withLock { if acceptedPress { machine.didCommit() } } }
    public func stop(at time: HostTime) {
        lock.withLock {
            if acceptedPress { onAction(.machine(.cancelled(at: time))) }
            acceptedPress = false
            toggleDownAt = nil; mouseButtonDown = false
            machine = .init(config: machine.config)
            if interaction == .toggle { machine.discardUntilRelease() }
            availability = .blocked(.notInSession)
        }
    }

    private func deliver(_ actions: [PushToTalkMachine.Action]) {
        for action in actions {
            if case let .began(time) = action {
                if case let .blocked(reason) = availability {
                    acceptedPress = false; onAction(.refused(at: time, reason: reason))
                } else { acceptedPress = true; onAction(.machine(action)) }
            } else if acceptedPress {
                acceptedPress = false
                onAction(.machine(action))
            } else {
                machine.discardTapSequence()
            }
        }
    }

    private func discardToggleGesture() {
        guard toggleDownAt != nil else { return }
        toggleDownAt = nil
        machine.discardUntilRelease()
    }

    private func cancelToggle(at time: HostTime) {
        let wasRecording = acceptedPress
        acceptedPress = false; toggleDownAt = nil
        machine.discardUntilRelease()
        if wasRecording { onAction(.machine(.cancelled(at: time))) }
    }

    /// The existing machine validates the physical gesture. Only a real clean key-up commits
    /// one toggle; a poll-inferred release or a chord cannot start or stop logical recording.
    private func deliverToggle(_ actions: [PushToTalkMachine.Action], cleanKeyUp: Bool, source: KeyEventSource) {
        for action in actions {
            switch action {
            case let .began(at):
                guard source == .hidSystem, !mouseButtonDown else {
                    toggleDownAt = nil; machine.discardUntilRelease(); continue
                }
                if case let .blocked(reason) = availability {
                    toggleDownAt = nil; machine.discardUntilRelease()
                    onAction(.refused(at: at, reason: reason))
                } else { toggleDownAt = at }
            case let .tapped(at), let .doubleTapped(at), let .released(at, .keyUp):
                defer { toggleDownAt = nil; machine.discardTapSequence() }
                guard cleanKeyUp, let downAt = toggleDownAt else { continue }
                guard case .allowed = availability else { continue }
                if acceptedPress {
                    acceptedPress = false
                    onAction(.machine(.released(at: at, reason: .keyUp)))
                } else {
                    acceptedPress = true
                    onAction(.machine(.began(at: downAt)))
                }
            case .cancelled, .released:
                toggleDownAt = nil; machine.discardTapSequence()
            }
        }
    }
}
