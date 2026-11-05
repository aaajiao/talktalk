import CoreAudio
import Foundation

/// One of the driver's devices as the HAL reports it, looked up by UID (object IDs change after a
/// coreaudiod restart, M0-T8 d4). Reading these never starts IO and needs no TCC.
public struct DriverDeviceInfo: Sendable, Equatable {
    public var uid: String
    public var objectID: UInt32
    public var inputChannels: Int
    public var outputChannels: Int
    public var sampleRate: Double
    public var isHidden: Bool
    /// Listed in `kAudioHardwarePropertyDevices` (hidden devices never are; TalkTalk Mic only while
    /// a talktalk process is attached or someone reads it, §8.3).
    public var inDeviceList: Bool
    public var isAlive: Bool
    public var isRunningSomewhere: Bool
    public var canBeDefault: Bool
    public var firmwareVersion: String?

    public init(uid: String, objectID: UInt32 = 0, inputChannels: Int = 0, outputChannels: Int = 0,
                sampleRate: Double = 48_000, isHidden: Bool = false, inDeviceList: Bool = false,
                isAlive: Bool = true, isRunningSomewhere: Bool = false, canBeDefault: Bool = false,
                firmwareVersion: String? = nil) {
        self.uid = uid
        self.objectID = objectID
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.isHidden = isHidden
        self.inDeviceList = inDeviceList
        self.isAlive = isAlive
        self.isRunningSomewhere = isRunningSomewhere
        self.canBeDefault = canBeDefault
        self.firmwareVersion = firmwareVersion
    }
}

/// The parts of the driver's `'ttdg'` dictionary the app uses (docs/decisions/m0-t8-driver.md
/// "驱动的自定义属性"). Refused Feed AddClient / StartIO calls reach the client only as `'what'`, so
/// these counters are how the app tells such a refusal from any other failure. (A refused 'ttmm'
/// write is different: the client gets the driver's 'nope' unchanged; `ttmmDenied` counts only
/// callers that are not accepted Feed clients, not bad values.)
public struct DriverDiagnostics: Sendable, Equatable {
    public struct Client: Sendable, Equatable, Hashable {
        public var device: String
        public var pid: Int32
        public var bundleID: String?
        public var allowed: Bool
        public var ioRunning: Bool
    }
    public var version: String?
    public var feedAddClientDenied: Int64
    public var feedStartIODenied: Int64
    public var feedWriteCycles: Int64
    public var micReadHitFrames: Int64
    public var testMicReadHitFrames: Int64
    public var micInList: Bool?
    /// Build-time visibility mode: 0 remove, 1 hidden, 2 always (scripts/build-driver.sh --mic-mode).
    public var micMode: Int?
    /// Allowed (talktalk) clients attached to the Feed, and IO clients on the Mic (§8.3).
    public var feedClients: Int64
    public var micIO: Int64
    /// 'ttmm' as the driver sees it (nil before the M2 driver).
    public var meetingMode: Bool?
    /// TalkTalk Mic's CanBeDefaultDevice as the driver reports it (nil before the M2 driver).
    public var micCanBeDefault: Bool?
    /// Accepted / refused 'ttmm' writes, and the clientPID the HAL passed on the last one.
    public var ttmmWrites: Int64
    public var ttmmDenied: Int64
    public var ttmmLastPID: Int64?
    public var clients: [Client]

    public init(version: String? = nil, feedAddClientDenied: Int64 = 0, feedStartIODenied: Int64 = 0,
                feedWriteCycles: Int64 = 0, micReadHitFrames: Int64 = 0, testMicReadHitFrames: Int64 = 0,
                micInList: Bool? = nil, micMode: Int? = nil, feedClients: Int64 = 0, micIO: Int64 = 0,
                meetingMode: Bool? = nil, micCanBeDefault: Bool? = nil, ttmmWrites: Int64 = 0,
                ttmmDenied: Int64 = 0, ttmmLastPID: Int64? = nil, clients: [Client] = []) {
        self.version = version
        self.feedAddClientDenied = feedAddClientDenied
        self.feedStartIODenied = feedStartIODenied
        self.feedWriteCycles = feedWriteCycles
        self.micReadHitFrames = micReadHitFrames
        self.testMicReadHitFrames = testMicReadHitFrames
        self.micInList = micInList
        self.micMode = micMode
        self.feedClients = feedClients
        self.micIO = micIO
        self.meetingMode = meetingMode
        self.micCanBeDefault = micCanBeDefault
        self.ttmmWrites = ttmmWrites
        self.ttmmDenied = ttmmDenied
        self.ttmmLastPID = ttmmLastPID
        self.clients = clients
    }

    /// Processes with IO running on TalkTalk Mic ("谁在用", §11 组件).
    public var micUsers: [Client] { clients.filter { $0.device == "mic" && $0.ioRunning } }

    public init(dictionary d: [String: Any]) {
        func num(_ k: String) -> Int64 { (d[k] as? NSNumber)?.int64Value ?? 0 }
        func bool(_ k: String) -> Bool? { (d[k] as? NSNumber)?.boolValue }
        let rows = (d["clients"] as? [[String: Any]]) ?? []
        self.init(version: d["version"] as? String,
                  feedAddClientDenied: num("feedAddClientDenied"), feedStartIODenied: num("feedStartIODenied"),
                  feedWriteCycles: num("feedWriteCycles"), micReadHitFrames: num("micReadHitFrames"),
                  testMicReadHitFrames: num("testMicReadHitFrames"), micInList: bool("micInList"),
                  micMode: (d["micMode"] as? NSNumber)?.intValue, feedClients: num("feedClients"),
                  micIO: num("micIO"), meetingMode: bool("meetingMode"), micCanBeDefault: bool("micCanBeDefault"),
                  ttmmWrites: num("ttmmWrites"), ttmmDenied: num("ttmmDenied"),
                  ttmmLastPID: (d["ttmmLastPID"] as? NSNumber)?.int64Value,
                  clients: rows.map { r in
                      Client(device: (r["device"] as? String) ?? "",
                             pid: (r["pid"] as? NSNumber)?.int32Value ?? -1,
                             bundleID: (r["bundleID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                             allowed: (r["allowed"] as? NSNumber)?.boolValue ?? false,
                             ioRunning: (r["ioRunning"] as? NSNumber)?.boolValue ?? false)
                  })
    }
}

/// The few HAL reads the driver support needs, behind a protocol so state checks and the
/// installer run against a fake in tests.
public protocol DriverHAL: Sendable {
    func device(uid: String) -> DriverDeviceInfo?
    func diagnostics() -> DriverDiagnostics?
    func defaultInputUID() -> String?
    /// 'ttmm' on the Feed (nil: the property does not exist, i.e. a driver before M2).
    func meetingMode() -> Bool?
    /// Writes 'ttmm' (§8.3): 1 lets TalkTalk Mic be the default input, 0 stops that. Only a process
    /// that is an accepted Feed client may write (the driver looks the HAL's clientPID up among its
    /// Feed clients); others get kAudioHardwareIllegalOperationError. Write after the Mic is listed:
    /// every (re)entry of the Mic into the device list resets it to 0.
    func setMeetingMode(_ on: Bool) -> OSStatus
}

extension DriverHAL {
    /// Version of the driver the HAL has loaded: the `version` in 'ttdg'. The devices'
    /// `kAudioObjectPropertyFirmwareVersion` reads back empty through the HAL although the driver
    /// sets it (M0-T8 `ttdevice` rows: `"firmware":""`; M2 DeviceDriverTests: nil), so it is only a
    /// fallback. nil: the Feed is not loaded.
    public func loadedVersion() -> String? {
        if let v = diagnostics()?.version, !v.isEmpty { return v }
        guard let feed = device(uid: DriverIdentity.feedUID) else { return nil }
        return feed.firmwareVersion.flatMap { $0.isEmpty ? nil : $0 } ?? ""
    }
}

public struct CoreAudioDriverHAL: DriverHAL {
    public init() {}

    public func device(uid: String) -> DriverDeviceInfo? {
        guard let id = Self.translate(uid: uid) else { return nil }
        let listed = Self.deviceList().contains(id)
        return DriverDeviceInfo(
            uid: uid, objectID: id,
            inputChannels: Self.channels(id, kAudioObjectPropertyScopeInput),
            outputChannels: Self.channels(id, kAudioObjectPropertyScopeOutput),
            sampleRate: Self.scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0,
            isHidden: (Self.scalar(id, kAudioDevicePropertyIsHidden) as UInt32? ?? 0) != 0,
            inDeviceList: listed,
            isAlive: (Self.scalar(id, kAudioDevicePropertyDeviceIsAlive) as UInt32? ?? 0) != 0,
            isRunningSomewhere: (Self.scalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere) as UInt32? ?? 0) != 0,
            canBeDefault: (Self.scalar(id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                       scope: kAudioObjectPropertyScopeInput) as UInt32? ?? 0) != 0,
            firmwareVersion: Self.string(id, kAudioObjectPropertyFirmwareVersion))
    }

    public func diagnostics() -> DriverDiagnostics? {
        guard let feed = Self.translate(uid: DriverIdentity.feedUID) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: DriverIdentity.diagnosticsSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList?>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(feed, &address, 0, nil, &size, $0) }
        guard st == noErr, let v = value?.takeRetainedValue(), let d = v as? [String: Any] else { return nil }
        return DriverDiagnostics(dictionary: d)
    }

    public func defaultInputUID() -> String? {
        guard let id: AudioObjectID = Self.scalar(AudioObjectID(kAudioObjectSystemObject),
                                                  kAudioHardwarePropertyDefaultInputDevice),
              id != kAudioObjectUnknown else { return nil }
        return Self.string(id, kAudioDevicePropertyDeviceUID)
    }

    /// 'ttmm' is a CFNumber: custom driver properties can only be CFString or CFPropertyList (the HAL
    /// marshals no other type between processes, AudioServerPlugIn.h "Custom Property Data Types").
    public func meetingMode() -> Bool? {
        guard let feed = Self.translate(uid: DriverIdentity.feedUID) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: DriverIdentity.meetingModeSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList?>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(feed, &address, 0, nil, &size, $0) }
        guard st == noErr, let v = value?.takeRetainedValue(), let n = v as? NSNumber else { return nil }
        return n.intValue != 0
    }

    public func setMeetingMode(_ on: Bool) -> OSStatus {
        guard let feed = Self.translate(uid: DriverIdentity.feedUID) else { return OSStatus(kAudioHardwareBadDeviceError) }
        var address = AudioObjectPropertyAddress(mSelector: DriverIdentity.meetingModeSelector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFPropertyList = NSNumber(value: on ? 1 : 0)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(feed, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
    }

    // MARK: Core Audio helpers

    /// `kAudioHardwarePropertyTranslateUIDToDevice`: finds hidden devices too (§8.2).
    public static func translate(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func deviceList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.load(as: T.self)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard st == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
