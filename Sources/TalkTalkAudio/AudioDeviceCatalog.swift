import CoreAudio
import Foundation

/// Every audio device, inputs and outputs (ARCHITECTURE.md, "实时音频与生命周期约束"). Our own private tap
/// aggregates (`com.aaajiao.talktalk.tap.*`) are left out. Read-only, no TCC.
public struct AudioDeviceInfo: Sendable, Equatable, Hashable, Codable {
    public let objectID: UInt32
    public let uid: String
    public let name: String
    public let transport: String
    public let nominalSampleRate: Double
    public let inputChannels: Int
    public let outputChannels: Int
    public let isAlive: Bool
}

public enum AudioDeviceCatalog {
    public static func devices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(info(for:)).filter { !$0.uid.hasPrefix(MeetingTap.uidPrefix) }
    }

    public static func info(for id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = InputDeviceCatalog.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transport: UInt32 = InputDeviceCatalog.scalar(id, kAudioDevicePropertyTransportType) ?? 0
        let alive: UInt32 = InputDeviceCatalog.scalar(id, kAudioDevicePropertyDeviceIsAlive) ?? 0
        return AudioDeviceInfo(
            objectID: id, uid: uid, name: InputDeviceCatalog.string(id, kAudioObjectPropertyName) ?? uid,
            transport: InputDeviceCatalog.fourCC(transport),
            nominalSampleRate: InputDeviceCatalog.scalar(id, kAudioDevicePropertyNominalSampleRate) ?? 0,
            inputChannels: channels(id, kAudioObjectPropertyScopeInput),
            outputChannels: channels(id, kAudioObjectPropertyScopeOutput),
            isAlive: alive != 0)
    }

    public static func defaultOutput() -> AudioDeviceInfo? {
        let id: AudioObjectID? = InputDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        return id.flatMap(info(for:))
    }

    public static func defaultInput() -> AudioDeviceInfo? {
        let id: AudioObjectID? = InputDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return id.flatMap(info(for:))
    }

    /// The process object of `pid`, if it is a Core Audio client (§3.5: the engine must not be).
    public static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
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
