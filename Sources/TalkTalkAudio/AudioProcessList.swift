import CoreAudio
import Foundation

/// Read-only listing of Core Audio process objects (`kAudioHardwarePropertyProcessObjectList`).
/// Used by `TalkTalk --list-audio-processes` (M0-T0: the engine PID must have no process object,
/// i.e. the engine never became a Core Audio client) and later by MeetingSourceResolver.
/// Reads properties only; never opens a device or starts IO; needs no TCC permission.
public struct AudioProcessInfo: Sendable, Codable, Equatable {
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
}

public enum AudioProcessList {
    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public let what: String
        public var description: String { "\(what): OSStatus \(status)" }
    }

    public static func current() throws -> [AudioProcessInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw Failure(status: status, what: "ProcessObjectList size") }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        guard status == noErr else { throw Failure(status: status, what: "ProcessObjectList") }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).map { id in
            AudioProcessInfo(
                objectID: id,
                pid: scalar(id, kAudioProcessPropertyPID, as: pid_t.self) ?? -1,
                bundleID: string(id, kAudioProcessPropertyBundleID),
                isRunningInput: (scalar(id, kAudioProcessPropertyIsRunningInput, as: UInt32.self) ?? 0) != 0,
                isRunningOutput: (scalar(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0)
        }
    }

    private static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.load(as: T.self)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { p in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, p)
        }
        guard status == noErr, let s = value?.takeRetainedValue() else { return nil }
        let str = s as String
        return str.isEmpty ? nil : str
    }
}
