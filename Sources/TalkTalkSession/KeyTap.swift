import Carbon
import CoreGraphics
import Foundation
import TalkTalkCore

/// One listen-only tap, with its own run loop and 20 ms hardware poll. The owner starts/stops it
/// with a meeting, or explicitly for the onboarding SPEAK session. It never consumes an event,
/// records typed text, or requests Accessibility. Input Monitoring is granted by the user.
public final class KeyTap: @unchecked Sendable {
    public enum Scope: Sendable { case meeting, onboarding }
    public enum Failure: Error { case unavailable }
    public let scope: Scope
    private let worker: Worker

    public init(scope: Scope, onEvent: @escaping @Sendable (KeyInputEvent) -> Void) {
        self.scope = scope
        worker = Worker(onEvent: onEvent)
    }

    /// Serialize lifecycle calls. Sinks run on the tap thread and must not block or await.
    public func start() throws { try worker.start() }
    public func stop() { worker.stop() }
    deinit { worker.stop() }

    /// Pure conversion: time is captured at callback entry, never at a later actor hop.
    public static func translate(type: CGEventType, keyCode: UInt16 = 0, flags: UInt64 = 0,
                                 isRepeat: Bool = false, sourceStateID: Int64 = 0,
                                 dx: Double = 0, dy: Double = 0, at time: HostTime) -> KeyInputEvent? {
        let kind: KeyInputEvent.Kind
        switch type {
        case .flagsChanged: kind = .flagsChanged(keyCode: keyCode, flags: .init(rawValue: flags))
        case .keyDown: kind = .keyDown(keyCode: keyCode, isRepeat: isRepeat)
        case .keyUp: kind = .keyUp(keyCode: keyCode)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .scrollWheel: kind = .scroll
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .mouseMoved(dx: dx, dy: dy)
        case .tapDisabledByTimeout: kind = .tapDisabled(.disabledByTimeout)
        case .tapDisabledByUserInput: kind = .tapDisabled(.disabledByUserInput)
        default: return nil
        }
        return .init(time: time, kind: kind,
                     source: sourceStateID == Int64(CGEventSourceStateID.hidSystemState.rawValue) ? .hidSystem : .other)
    }

    /// Quartz key-state polling can report a right modifier through its left/aggregate code.
    /// Correct only a group whose same-poll flags identify a side and its independent modifier;
    /// otherwise preserve the raw result. Never infer a side from an earlier event.
    static func normalizedPolledKeys(_ raw: Set<UInt16>, flags: ModifierFlags) -> Set<UInt16> {
        var keys = raw
        func normalize(_ independent: ModifierFlags, _ leftBit: ModifierFlags, _ rightBit: ModifierFlags,
                       _ leftCode: UInt16, _ rightCode: UInt16) {
            guard flags.contains(independent), !flags.intersection([leftBit, rightBit]).isEmpty else { return }
            keys.remove(leftCode); keys.remove(rightCode)
            if flags.contains(leftBit) { keys.insert(leftCode) }
            if flags.contains(rightBit) { keys.insert(rightCode) }
        }
        normalize(.option, .deviceLeftOption, .deviceRightOption, KeyCode.option, KeyCode.rightOption)
        normalize(.command, .deviceLeftCommand, .deviceRightCommand, KeyCode.command, KeyCode.rightCommand)
        normalize(.control, .deviceLeftControl, .deviceRightControl, KeyCode.control, KeyCode.rightControl)
        normalize(.shift, .deviceLeftShift, .deviceRightShift, KeyCode.shift, KeyCode.rightShift)
        return keys
    }

    #if TALKTALK_DEV
    /// Explicit bench hook only; no notification listener is installed during normal use.
    public func stallForBench() { worker.stallForBench() }
    #endif

    private final class Worker: @unchecked Sendable {
        let onEvent: @Sendable (KeyInputEvent) -> Void
        let condition = NSCondition()
        var loop: CFRunLoop?
        var starting = false
        var failed = false
        var running = false
        // Only used on the tap thread.
        var tap: CFMachPort?

        init(onEvent: @escaping @Sendable (KeyInputEvent) -> Void) { self.onEvent = onEvent }

        func start() throws {
            condition.lock()
            if running { condition.unlock(); return }
            starting = true; failed = false; running = true
            let thread = Thread { [self] in run() }
            thread.name = "com.aaajiao.talktalk.keytap"
            thread.qualityOfService = .userInteractive
            thread.start()
            while starting { condition.wait() }
            let error = failed
            condition.unlock()
            if error { throw Failure.unavailable }
        }

        func stop() {
            condition.lock()
            while starting { condition.wait() }
            guard let loop else { condition.unlock(); return }
            let sameThread = CFRunLoopGetCurrent() === loop
            if sameThread { CFRunLoopStop(loop) }
            else {
                // Also works if stop races with the first CFRunLoopRun after publication.
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
                CFRunLoopWakeUp(loop)
                while running { condition.wait() }
            }
            condition.unlock()
        }

        func publish(_ loop: CFRunLoop?) {
            condition.lock()
            self.loop = loop; starting = false; failed = loop == nil
            if loop == nil { running = false }
            condition.broadcast(); condition.unlock()
        }

        func run() {
            let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown,
                                       .otherMouseDown, .scrollWheel, .mouseMoved,
                                       .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .listenOnly, eventsOfInterest: mask,
                                               callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let worker = Unmanaged<Worker>.fromOpaque(context).takeUnretainedValue()
                worker.receive(type, event, at: HostClock.now())
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
                  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                publish(nil); return
            }
            tap = port
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, source, .commonModes)
            let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0.020, 0, 0) { [self] _ in poll() }
            CFRunLoopAddTimer(loop, timer, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            onEvent(.init(time: HostClock.now(), kind: .tapEnabled))
            publish(loop)
            CFRunLoopRun()
            onEvent(.init(time: HostClock.now(), kind: .tapDisabled(.portInvalid)))
            CFRunLoopTimerInvalidate(timer)
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            tap = nil
            condition.lock(); self.loop = nil; running = false
            condition.broadcast(); condition.unlock()
        }

        func receive(_ type: CGEventType, _ event: CGEvent, at time: HostTime) {
            if let e = KeyTap.translate(type: type, keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                                       flags: event.flags.rawValue,
                                       isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                       sourceStateID: event.getIntegerValueField(.eventSourceStateID),
                                       dx: event.getDoubleValueField(.mouseEventDeltaX),
                                       dy: event.getDoubleValueField(.mouseEventDeltaY), at: time) {
                onEvent(e)
            }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { enable() }
        }

        func enable() {
            guard let tap, CFMachPortIsValid(tap) else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) { onEvent(.init(time: HostClock.now(), kind: .tapEnabled)) }
        }

        func poll() {
            let time = HostClock.now()
            guard let tap, CFMachPortIsValid(tap) else {
                onEvent(.init(time: time, kind: .tapDisabled(.portInvalid)))
                CFRunLoopStop(CFRunLoopGetCurrent()); return
            }
            if !CGEvent.tapIsEnabled(tap: tap) {
                onEvent(.init(time: time, kind: .tapDisabled(.notEnabled)))
                enable()
            }
            // Scan without retaining key history; this also finds keys pressed before tap startup.
            let rawKeys = Set((UInt16(0)..<128).filter { CGEventSource.keyState(.hidSystemState, key: $0) })
            let flags = ModifierFlags(rawValue: CGEventSource.flagsState(.hidSystemState).rawValue)
            let keys = KeyTap.normalizedPolledKeys(rawKeys, flags: flags)
            let buttons = (UInt32(0)..<32).contains { CGEventSource.buttonState(.hidSystemState, button: CGMouseButton(rawValue: $0)!) }
            onEvent(.init(time: time, kind: .poll(.init(keysDown: keys, flags: flags,
                mouseButtonDown: buttons, secureInput: IsSecureEventInputEnabled()))))
        }

        #if TALKTALK_DEV
        func stallForBench() {
            condition.lock(); let current = loop; condition.unlock()
            guard let current else { return }
            CFRunLoopPerformBlock(current, CFRunLoopMode.commonModes.rawValue) { Thread.sleep(forTimeInterval: 1) }
            CFRunLoopWakeUp(current)
        }
        #endif
    }
}
