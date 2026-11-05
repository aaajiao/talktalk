import Foundation
import TalkTalkCore

/// Runtime guard around the existing key machine. KeyTap drives handle/tick; VAD, availability
/// and commit reports may arrive on other threads. Callbacks receive the original event time.
public final class PushToTalkKey: @unchecked Sendable {
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
    private let onAction: @Sendable (Action) -> Void

    public init(config: PushToTalkMachine.Config, onAction: @escaping @Sendable (Action) -> Void) {
        machine = .init(config: config); self.onAction = onAction
    }
    public var isActive: Bool { lock.withLock { machine.isActive } }
    public var needsPolling: Bool { lock.withLock { machine.phase != .idle } }
    public var phase: PushToTalkMachine.Phase { lock.withLock { machine.phase } }

    public func setAvailability(_ value: Availability, at time: HostTime) {
        lock.withLock {
            availability = value
            if case .blocked = value, acceptedPress {
                acceptedPress = false
                onAction(.machine(.cancelled(at: time)))
            }
        }
    }
    public func handle(_ event: KeyInputEvent) { lock.withLock { deliver(machine.handle(event)) } }
    public func tick(now: HostTime) { lock.withLock { deliver(machine.tick(now: now)) } }
    public func vad(speech: Bool, at time: HostTime) { lock.withLock { machine.vad(speech: speech, at: time) } }
    public func didCommit() { lock.withLock { if acceptedPress { machine.didCommit() } } }
    public func stop(at time: HostTime) {
        lock.withLock {
            if acceptedPress { onAction(.machine(.cancelled(at: time))) }
            acceptedPress = false
            machine = .init(config: machine.config)
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
}
