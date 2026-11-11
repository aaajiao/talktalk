/// Headphones or speakers (ARCHITECTURE.md, "实时音频与生命周期约束"). A pure lookup: TalkTalkAudio's OutputRouteProbe
/// reads the meeting process's output devices (`kAudioProcessPropertyDevices`, output scope), the
/// self-monitor device and the default output, and re-asks on every device, DataSource or process
/// device change. Everything not positively known to be headphones is a speaker.
public enum OutputRouteClassifier {
    public enum Transport: Sendable, Hashable {
        case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort, airPlay, thunderbolt, pci,
             firewire, virtual, aggregate, unknown
    }

    public enum Route: Sendable, Hashable { case headphones, speaker }

    /// What the probe knows about one output device.
    public struct Device: Sendable, Hashable {
        public var uid: String
        public var name: String
        public var transport: Transport
        /// `kAudioDevicePropertyDataSource` of the output scope as a four-char code ('hdpn', 'ispk'), if any.
        public var dataSource: UInt32?

        public init(uid: String, name: String, transport: Transport, dataSource: UInt32? = nil) {
            self.uid = uid; self.name = name; self.transport = transport; self.dataSource = dataSource
        }
    }

    public static let dataSourceHeadphones: UInt32 = 0x6864_706E   // 'hdpn'
    public static let dataSourceInternalSpeaker: UInt32 = 0x6973_706B   // 'ispk'
    /// The name macOS gives the built-in jack's headphone device on Apple silicon.
    public static let externalHeadphonesName = "External Headphones"

    /// One device. `confirmedHeadphones`: UIDs the user once confirmed as "这是耳机" (only Bluetooth
    /// and USB devices can be confirmed).
    public static func classify(_ d: Device, confirmedHeadphones: Set<String>) -> Route {
        switch d.transport {
        case .builtIn:
            if d.dataSource == dataSourceHeadphones || d.name == externalHeadphonesName { return .headphones }
            return .speaker
        case .bluetooth, .bluetoothLE, .usb:
            return confirmedHeadphones.contains(d.uid) ? .headphones : .speaker
        case .unknown:
            // "名为 External Headphones 的设备" when the HAL reports no transport (Transport(fourCC:)
            // maps only code 0 here; unrecognized codes are .virtual). A virtual or aggregate
            // device using that name stays a speaker: the name alone is not trusted there.
            return d.name == externalHeadphonesName ? .headphones : .speaker
        case .hdmi, .displayPort, .airPlay, .thunderbolt, .pci, .firewire, .virtual, .aggregate:
            return .speaker
        }
    }

    /// Speaker mode (§3.7): any device the meeting app plays on, or the self-monitor device while
    /// self-monitoring is on, is a speaker. nil when the meeting's output devices are unknown (the
    /// probe timed out, the devices are being rebuilt): PassthroughPolicy treats nil as unavailable.
    public static func isSpeakerMode(meetingOutputs: [Device]?, monitor: Device?,
                                     confirmedHeadphones: Set<String>) -> Bool? {
        guard let outs = meetingOutputs, !outs.isEmpty else { return nil }
        let all = outs + (monitor.map { [$0] } ?? [])
        return all.contains { classify($0, confirmedHeadphones: confirmedHeadphones) == .speaker }
    }

    /// Cues (passthrough and MeetingMicGuard) play on the default output, and only when that device
    /// is headphones: the default output may still be the built-in speaker (§3.4, C11).
    public static func cueAllowed(defaultOutput: Device?, confirmedHeadphones: Set<String>) -> Bool {
        guard let d = defaultOutput else { return false }
        return classify(d, confirmedHeadphones: confirmedHeadphones) == .headphones
    }
}
