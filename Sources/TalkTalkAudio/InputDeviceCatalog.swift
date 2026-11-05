import CoreAudio
import Foundation

/// One Core Audio input device, as read from its properties (ARCHITECTURE.md §3.2).
/// Values only; reading these never opens the device and needs no TCC permission.
public struct InputDeviceInfo: Sendable, Equatable, Hashable {
    public let objectID: UInt32
    public let uid: String
    public let name: String
    /// `kAudioDevicePropertyTransportType` as a four-char code: "bltn", "usb ", "blue", "virt", ...
    public let transport: String
    public let nominalSampleRate: Double
    public let inputChannels: Int
    public let isAlive: Bool
    public let isAggregate: Bool

    public init(objectID: UInt32, uid: String, name: String, transport: String, nominalSampleRate: Double,
                inputChannels: Int, isAlive: Bool, isAggregate: Bool) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.transport = transport
        self.nominalSampleRate = nominalSampleRate
        self.inputChannels = inputChannels
        self.isAlive = isAlive
        self.isAggregate = isAggregate
    }
}

public enum InputDeviceCatalog {
    /// All devices that currently have at least one input channel.
    public static func inputDevices() -> [InputDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap(info(for:))
    }

    public static func device(uid: String) -> InputDeviceInfo? {
        inputDevices().first { $0.uid == uid }
    }

    public static func info(for id: AudioObjectID) -> InputDeviceInfo? {
        let channels = inputChannelCount(id)
        guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transportCode: UInt32 = scalar(id, kAudioDevicePropertyTransportType) ?? 0
        let classID: AudioClassID = scalar(id, kAudioObjectPropertyClass) ?? 0
        return InputDeviceInfo(
            objectID: id,
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? uid,
            transport: fourCC(transportCode),
            nominalSampleRate: scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0,
            inputChannels: channels,
            isAlive: (scalar(id, kAudioDevicePropertyDeviceIsAlive) as UInt32? ?? 0) != 0,
            isAggregate: transportCode == kAudioDeviceTransportTypeAggregate
                || classID == kAudioAggregateDeviceClassID)
    }

    public static func fourCC(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) { return String(decoding: bytes, as: UTF8.self) }
        return String(format: "0x%08x", code)
    }

    static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.load(as: T.self)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { p in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, p)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
