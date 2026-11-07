// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation
import TalkTalkAudio
import TalkTalkCore

/// Which microphones may record the voice reference and bench takes (ARCHITECTURE.md §9.2 step 1,
/// §3.2): only built-in or USB, nominal rate ≥ 44.1 kHz; never Bluetooth (HFP, 16–24 kHz),
/// virtual, aggregate, Continuity or TalkTalk's own devices. Pure function of the device values.
///
/// The part shared with SPEAK's microphone choice — own UIDs, aggregate, virtual, the excluded
/// third-party names (§3.2 rule 2) — is delegated to sysinput's `MicPolicy.exclusion`, so the two
/// can never disagree on what counts as virtual. What is recording-only stays here: the narrower
/// transport list (no Thunderbolt/PCI, no Continuity), the sample-rate floor, and a few extra
/// virtual-driver names that only matter for a reference take.
public enum RecordingDevicePolicy {
    public enum Verdict: Equatable, Sendable {
        case accepted
        case rejected(String)

        public var isAccepted: Bool { self == .accepted }
        public var reason: String? { if case let .rejected(r) = self { r } else { nil } }
    }

    public static let minimumSampleRate = 44_100.0
    /// Beyond MicPolicy's rule-2 names: drivers that should never record a reference even when they
    /// claim a built-in/USB transport.
    static let extraVirtualNames = ["blackhole", "zoomaudiodevice"]

    public static func evaluate(_ d: InputDeviceInfo) -> Verdict {
        if !d.isAlive { return .rejected(String(appLocalized: "设备当前不可用")) }
        if let e = MicPolicy.exclusion(MicPolicy.Device(d)) { return .rejected(e.text) }
        let lower = d.name.lowercased()
        if extraVirtualNames.contains(where: { lower.contains($0) }) { return .rejected(MicPolicy.Exclusion.virtual.text) }
        if MicPolicy.bluetoothTransports.contains(d.transport) {
            return .rejected(String(appLocalized: "蓝牙耳机的麦克风走通话音质（HFP），不能用来录声音"))
        }
        if MicPolicy.continuityTransports.contains(d.transport) {
            return .rejected(String(appLocalized: "接续互通麦克风有延迟和压缩，不用来录声音"))
        }
        guard d.transport == "bltn" || d.transport == "usb " else {
            return .rejected(String(appLocalized: "只支持内建麦克风或 USB 麦克风"))
        }
        if d.nominalSampleRate <= 24_000 { return .rejected(String(appLocalized: "采样率太低（≤24 kHz），像是通话模式")) }
        if d.nominalSampleRate < minimumSampleRate {
            return .rejected(String(appLocalized: "采样率需要 ≥44.1 kHz（现在 \(Int(d.nominalSampleRate)) Hz）"))
        }
        return .accepted
    }

    /// Default: the built-in microphone, else the first accepted USB microphone.
    public static func preferred(_ devices: [InputDeviceInfo]) -> InputDeviceInfo? {
        let ok = devices.filter { evaluate($0).isAccepted }
        return ok.first { $0.transport == "bltn" } ?? ok.first
    }
}
