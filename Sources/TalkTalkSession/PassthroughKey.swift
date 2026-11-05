import Foundation
import TalkTalkCore

/// The shared tap drives this wrapper after PushToTalkKey and the tap/PTT policy facts. The
/// controller remains the sole bridge between its pure key machine and the gate.
public final class PassthroughKey: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let controller: PassthroughController
    public init(config: PassthroughKeyMachine.Config, gate: PassthroughGate) {
        controller = .init(machine: .init(config: config), gate: gate)
    }
    public var needsPolling: Bool { lock.withLock { controller.machine.phase != .idle } }
    public var intervals: IntervalHistogram { lock.withLock { controller.machine.intervals } }
    public var prearmCancels: Int { lock.withLock { controller.machine.prearmCancels } }
    public var lostKeyUps: Int { lock.withLock { controller.machine.lostKeyUps } }
    public func handle(_ event: KeyInputEvent) { lock.withLock { _ = controller.handle(event) } }
    public func tick(now: HostTime) { lock.withLock { _ = controller.tick(now: now) } }
    #if TALKTALK_DEV
    public func inject(_ event: KeyInputEvent, context: PassthroughKeyMachine.DevInjection) {
        lock.withLock { _ = controller.inject(event, context) }
    }
    #endif
}
