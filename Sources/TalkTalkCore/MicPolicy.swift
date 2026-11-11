// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Which microphone SPEAK reads, and which devices are physical enough to be a system default
/// input restore target (ARCHITECTURE.md, "实时音频与生命周期约束"). Pure functions of
/// device values; every comparison is by UID (object IDs change across coreaudiod restarts).
///
/// The five rules:
///   1. candidates: transport built-in, USB, Thunderbolt or PCI;
///   2. excluded: virtual, aggregate, our own UIDs (`com.aaajiao.talktalk.*`), Tuwa, Microsoft Teams Audio;
///   3. a UID the user picked in settings wins, but it must pass rule 2;
///   4. default: the built-in microphone;
///   5. never pick Bluetooth automatically; never follow the system default input (in meeting
///      mode that is TalkTalk Mic, and following it would loop our own output back in).
///
/// Rule 2 is exported on its own (`exclusion(_:)` / `passesRule2(_:)`): `PassthroughPolicy`
/// asserts it on the physical mic right before opening passthrough (§3.5), and
/// `SystemInputPlan` uses it to decide what may ever become the system default input again.
public enum MicPolicy {
    /// One input device, as values. TalkTalkAudio builds it from Core Audio properties.
    public struct Device: Sendable, Equatable, Hashable, Codable {
        public var uid: String
        public var name: String
        /// `kAudioDevicePropertyTransportType` as a four-char code ("bltn", "usb ", "blue", "virt", ...).
        public var transport: String
        public var isAggregate: Bool
        public var isAlive: Bool

        public init(uid: String, name: String, transport: String, isAggregate: Bool = false, isAlive: Bool = true) {
            self.uid = uid
            self.name = name
            self.transport = transport
            self.isAggregate = isAggregate
            self.isAlive = isAlive
        }
    }

    // MARK: constants

    /// TalkTalk Mic (§8.2), from the generated driver pins.
    public static let talkTalkMicUID = DriverPins.micUID
    /// Every UID we create starts with this (Mic, Feed, Test Mic, `com.aaajiao.talktalk.tap.*`).
    public static let ownUIDPrefix = DriverPins.ownUIDPrefix + "."

    /// Rule 1 transports.
    public static let candidateTransports: Set<String> = ["bltn", "usb ", "thun", "pci "]
    public static let bluetoothTransports: Set<String> = ["blue", "blea"]
    public static let continuityTransports: Set<String> = ["ccwd", "ccwl"]
    static let aggregateTransports: Set<String> = ["grup", "fgrp"]
    /// Rule 2 name exclusions (lowercased substrings): third-party virtual drivers on this Mac
    /// that do not always report transport `virt` (§8.1, research:macos-audio-routing F14).
    public static let excludedNameFragments = ["tuwa", "microsoft teams audio"]

    // MARK: rule 2

    public enum Exclusion: String, Sendable, Equatable, CaseIterable {
        case ownDevice       // com.aaajiao.talktalk.*
        case aggregate
        case virtual         // transport virt
        case excludedByName  // Tuwa, Microsoft Teams Audio

        /// Shown in settings next to a device that cannot be used.
        public var text: String {
            switch self {
            case .ownDevice: String(appLocalized: "TalkTalk 自己的虚拟设备")
            case .aggregate: String(appLocalized: "聚合设备")
            case .virtual: String(appLocalized: "虚拟设备")
            case .excludedByName: String(appLocalized: "其他软件的虚拟麦克风")
            }
        }
    }

    /// Rule 2: why this device may never be read as the microphone, nor be restored as the system
    /// default input. nil = it passes. Liveness is not part of rule 2 (see `isUsable`).
    public static func exclusion(_ d: Device) -> Exclusion? {
        if isOwnUID(d.uid) { return .ownDevice }
        if d.isAggregate || aggregateTransports.contains(d.transport) { return .aggregate }
        if d.transport == "virt" { return .virtual }
        let lower = d.name.lowercased()
        if excludedNameFragments.contains(where: { lower.contains($0) }) { return .excludedByName }
        return nil
    }

    public static func passesRule2(_ d: Device) -> Bool { exclusion(d) == nil }

    /// Rule 2 plus "alive": what passthrough and restore actually require at the moment of use.
    public static func isUsable(_ d: Device) -> Bool { d.isAlive && passesRule2(d) }

    public static func isOwnUID(_ uid: String) -> Bool {
        uid.hasPrefix(ownUIDPrefix) || uid == DriverPins.ownUIDPrefix
    }

    public static func isTalkTalkMic(_ d: Device?) -> Bool { d?.uid == talkTalkMicUID }

    // MARK: rules 1, 3, 4, 5

    /// Rule 1 + rule 2 + alive: may be chosen automatically.
    public static func isCandidate(_ d: Device) -> Bool {
        isUsable(d) && candidateTransports.contains(d.transport)
    }

    public static func isBluetooth(_ d: Device) -> Bool { bluetoothTransports.contains(d.transport) }
    public static func isContinuity(_ d: Device) -> Bool { continuityTransports.contains(d.transport) }

    public struct Selection: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            case user            // the UID picked in settings
            case builtIn         // rule 4
            case otherCandidate  // first USB / Thunderbolt / PCI
        }
        public var device: Device?
        public var source: Source?
        /// Set when the user's pick could not be used, so settings can say why.
        public var userPickProblem: UserPickProblem?
    }

    public enum UserPickProblem: Sendable, Equatable {
        case missing
        case notAlive
        case excluded(Exclusion)
    }

    /// The SPEAK microphone. `devices` is the input device list; the system default input is
    /// deliberately not a parameter (rule 5).
    public static func select(_ devices: [Device], userUID: String?) -> Selection {
        var problem: UserPickProblem?
        if let userUID {
            if let d = devices.first(where: { $0.uid == userUID }) {
                if let ex = exclusion(d) { problem = .excluded(ex) }
                else if !d.isAlive { problem = .notAlive }
                else { return Selection(device: d, source: .user, userPickProblem: nil) }
            } else {
                problem = .missing
            }
        }
        let ok = devices.filter(isCandidate)
        if let b = ok.first(where: { $0.transport == "bltn" }) {
            return Selection(device: b, source: .builtIn, userPickProblem: problem)
        }
        if let o = ok.first {
            return Selection(device: o, source: .otherCandidate, userPickProblem: problem)
        }
        return Selection(device: nil, source: nil, userPickProblem: problem)
    }

    /// What settings must show before the user's pick takes effect (§3.2).
    public enum PickNotice: Sendable, Equatable {
        /// Needs a second confirmation: the headset drops to HFP call quality.
        case confirmBluetoothHFP
        /// Informational: Continuity microphones add about 125 ms.
        case continuityLatency

        public var text: String {
            switch self {
            case .confirmBluetoothHFP: String(appLocalized: "耳机会切到通话音质，识别也会变差")
            case .continuityLatency: String(appLocalized: "接续互通麦克风有约 125 ms 延迟")
            }
        }

        public var needsConfirmation: Bool { self == .confirmBluetoothHFP }
    }

    public static func pickNotice(_ d: Device) -> PickNotice? {
        if isBluetooth(d) { return .confirmBluetoothHFP }
        if isContinuity(d) { return .continuityLatency }
        return nil
    }

    /// Which devices settings lists as pickable (rule 2 + alive; Bluetooth and Continuity included,
    /// with `pickNotice`).
    public static func pickable(_ devices: [Device]) -> [Device] { devices.filter(isUsable) }
}
