/// The input-event model shared by PushToTalkMachine, PassthroughKeyMachine and the future KeyTap
/// (ARCHITECTURE.md §3.8 "键", §5.2). Pure values: KeyTap (TalkTalkSession, one listen-only
/// `CGEventTap` on its own thread) turns each `CGEvent` into a `KeyInputEvent`, and the poll timer
/// turns `CGEventSourceKeyState` / `CGEventSourceFlagsState` / `CGEventSourceButtonState` into a
/// `KeyStateSnapshot`. Nothing here imports CoreGraphics, so the machines run on a virtual clock.
///
/// Privacy: mouse events carry only the movement deltas (`kCGMouseEventDeltaX/Y`), never
/// coordinates; key events carry the key code only because the machines must tell their own key
/// from every other one. Nothing in this file is logged.

/// Virtual key codes (`kVK_*`, HIToolbox Events.h, macOS 27.2 SDK).
public enum KeyCode {
    public static let rightCommand: UInt16 = 0x36
    public static let command: UInt16 = 0x37       // left ⌘
    public static let shift: UInt16 = 0x38
    public static let capsLock: UInt16 = 0x39
    public static let option: UInt16 = 0x3A
    public static let control: UInt16 = 0x3B
    public static let rightShift: UInt16 = 0x3C
    public static let rightOption: UInt16 = 0x3D
    public static let rightControl: UInt16 = 0x3E
    public static let function: UInt16 = 0x3F

    /// Every modifier key code; the poll scans these with `CGEventSourceKeyState`.
    public static let modifiers: [UInt16] = [rightCommand, command, shift, capsLock, option, control,
                                             rightShift, rightOption, rightControl, function]
}

/// `CGEventFlags` as a raw bit set: device-independent masks plus the device-dependent `NX_DEVICE*`
/// bits (IOLLEvent.h, macOS 27.2 SDK). Left and right ⌘ share `.command`; only the device bits and
/// the key code tell them apart.
public struct ModifierFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    // NX_DEVICE* (device dependent)
    public static let deviceLeftControl = ModifierFlags(rawValue: 0x0000_0001)
    public static let deviceLeftShift = ModifierFlags(rawValue: 0x0000_0002)
    public static let deviceRightShift = ModifierFlags(rawValue: 0x0000_0004)
    public static let deviceLeftCommand = ModifierFlags(rawValue: 0x0000_0008)
    public static let deviceRightCommand = ModifierFlags(rawValue: 0x0000_0010)   // NX_DEVICERCMDKEYMASK
    public static let deviceLeftOption = ModifierFlags(rawValue: 0x0000_0020)
    public static let deviceRightOption = ModifierFlags(rawValue: 0x0000_0040)    // NX_DEVICERALTKEYMASK
    public static let deviceRightControl = ModifierFlags(rawValue: 0x0000_2000)   // NX_DEVICERCTLKEYMASK

    // device independent (kCGEventFlagMask*)
    public static let capsLock = ModifierFlags(rawValue: 0x0001_0000)     // alphaShift: a lock state
    public static let shift = ModifierFlags(rawValue: 0x0002_0000)
    public static let control = ModifierFlags(rawValue: 0x0004_0000)
    public static let option = ModifierFlags(rawValue: 0x0008_0000)
    public static let command = ModifierFlags(rawValue: 0x0010_0000)
    public static let numericPad = ModifierFlags(rawValue: 0x0020_0000)
    public static let help = ModifierFlags(rawValue: 0x0040_0000)
    public static let function = ModifierFlags(rawValue: 0x0080_0000)    // secondaryFn

    /// Bits that mean "a modifier key is held". Caps Lock is a lock *state* (it stays set while the
    /// light is on), and numericPad is set on arrow/keypad keyDowns, so neither counts as held; a
    /// Caps Lock toggle still arrives as a flagsChanged event and counts as a modifier change.
    public static let held: ModifierFlags = [
        .deviceLeftControl, .deviceLeftShift, .deviceRightShift, .deviceLeftCommand, .deviceRightCommand,
        .deviceLeftOption, .deviceRightOption, .deviceRightControl,
        .shift, .control, .option, .command, .function, .help,
    ]
}

/// One modifier key the machines can own: its key code, its device bit and its device-independent bit.
public struct ModifierKey: Sendable, Hashable {
    public let keyCode: UInt16
    public let deviceBit: ModifierFlags
    public let independentBit: ModifierFlags

    public static let rightCommand = ModifierKey(keyCode: KeyCode.rightCommand, deviceBit: .deviceRightCommand, independentBit: .command)
    public static let rightControl = ModifierKey(keyCode: KeyCode.rightControl, deviceBit: .deviceRightControl, independentBit: .control)
    public static let rightOption = ModifierKey(keyCode: KeyCode.rightOption, deviceBit: .deviceRightOption, independentBit: .option)

    /// PolicyProfile `speak.passthrough.key` / `altKey` names.
    public init?(profileName: String) {
        switch profileName {
        case "rightCommand": self = .rightCommand
        case "rightControl": self = .rightControl
        case "rightOption": self = .rightOption
        default: return nil
        }
    }

    init(keyCode: UInt16, deviceBit: ModifierFlags, independentBit: ModifierFlags) {
        self.keyCode = keyCode; self.deviceBit = deviceBit; self.independentBit = independentBit
    }

    /// The flags show this key held and no other modifier held (cicada `RightOptionKey`: only a
    /// clean press counts).
    public func isSoleHeldModifier(in flags: ModifierFlags) -> Bool {
        flags.intersection(.held) == [deviceBit, independentBit]
    }

    /// This key's device bit is set.
    public func isDown(in flags: ModifierFlags) -> Bool { flags.contains(deviceBit) }
}

/// Where an event came from (`kCGEventSourceStateID`). Only `.hidSystem` events may open the
/// passthrough (§3.8); closing and cancelling accept every source.
public enum KeyEventSource: Sendable, Hashable {
    case hidSystem          // kCGEventSourceStateHIDSystemState
    case other              // combined session state, private, remote control, injected
}

/// Why the event tap stopped delivering (§3.8 "关闭").
public enum TapFailure: Sendable, Hashable {
    case disabledByTimeout       // kCGEventTapDisabledByTimeout
    case disabledByUserInput     // kCGEventTapDisabledByUserInput
    case notEnabled              // CGEventTapIsEnabled became false
    case portInvalid             // the tap's mach port died
}

/// The hardware key state read by the poll (`CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, …)`
/// per key code, `CGEventSourceFlagsState`, `CGEventSourceButtonState`). It is ahead of the tap: it
/// shows the physical state even while tap events are still in flight or were lost.
public struct KeyStateSnapshot: Sendable, Hashable {
    /// Key codes found pressed (all modifiers, plus whatever the poll scanned).
    public var keysDown: Set<UInt16>
    public var flags: ModifierFlags
    public var mouseButtonDown: Bool
    /// `IsSecureEventInputEnabled()`, nil when it cannot be called (§3.8 "安全输入", M2 open item).
    public var secureInput: Bool?

    public init(keysDown: Set<UInt16>, flags: ModifierFlags, mouseButtonDown: Bool = false, secureInput: Bool? = nil) {
        self.keysDown = keysDown; self.flags = flags; self.mouseButtonDown = mouseButtonDown; self.secureInput = secureInput
    }

    /// Key codes whose `CGEventSourceKeyState` may report a state rather than a press: caps lock
    /// (the lock, not the key) and fn. Neither counts as "another key held" here; a held fn still
    /// shows as the `.function` flag, which is in `ModifierFlags.held`.
    public static let stateKeyCodes: Set<UInt16> = [KeyCode.capsLock, KeyCode.function]

    /// Key codes held other than `key` and the state-like ones.
    public func otherKeysDown(than key: ModifierKey) -> Set<UInt16> {
        keysDown.subtracting(Self.stateKeyCodes).subtracting([key.keyCode])
    }

    /// Another key code or another held modifier bit besides `key` (the mouse is not included).
    public func othersHeld(besides key: ModifierKey) -> Bool {
        !otherKeysDown(than: key).isEmpty
            || !flags.intersection(.held).subtracting([key.deviceBit, key.independentBit]).isEmpty
    }

    /// `key` is held and nothing else is: no other key code, no other held modifier bit, no mouse button.
    public func isSoleHeld(_ key: ModifierKey) -> Bool {
        isDown(key) && !othersHeld(besides: key) && !mouseButtonDown
    }

    public func isDown(_ key: ModifierKey) -> Bool { keysDown.contains(key.keyCode) }
}

/// One input event, stamped with the host time at which KeyTap received it (§3.8 privacy
/// invariant 4: `HostClock.now()` in the callback until M0-T18 shows `CGEventGetTimestamp` is the
/// same clock).
public struct KeyInputEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// `kCGEventFlagsChanged`: `keyCode` is the modifier that changed, `flags` the new flags.
        case flagsChanged(keyCode: UInt16, flags: ModifierFlags)
        case keyDown(keyCode: UInt16, isRepeat: Bool)
        case keyUp(keyCode: UInt16)
        /// Left, right or other mouse button down.
        case mouseDown
        case scroll
        /// `kCGMouseEventDeltaX/Y` only (points).
        case mouseMoved(dx: Double, dy: Double)
        case tapDisabled(TapFailure)
        case tapEnabled
        /// The poll timer's reading of the hardware state.
        case poll(KeyStateSnapshot)
    }

    public var time: HostTime
    public var kind: Kind
    public var source: KeyEventSource

    public init(time: HostTime, kind: Kind, source: KeyEventSource = .hidSystem) {
        self.time = time; self.kind = kind; self.source = source
    }

    /// Any user input other than the poll and tap health: what breaks a hold.
    public var isUserInput: Bool {
        switch kind {
        case .flagsChanged, .keyDown, .keyUp, .mouseDown, .scroll, .mouseMoved: true
        case .tapDisabled, .tapEnabled, .poll: false
        }
    }
}
