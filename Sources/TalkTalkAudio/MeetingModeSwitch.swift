import CoreAudio
import Foundation
import TalkTalkCore

/// The driver's meeting-mode switch `'ttmm'` (ARCHITECTURE.md §8.3, driver ≥ 0.2.0): TalkTalk Mic
/// enters the device list with `CanBeDefaultDevice` = 0 and can be made the default input only
/// after an accepted Feed client wrote `'ttmm'` = 1. A protocol so tests use a fake (TalkTalkAudio
/// cannot import TalkTalkDriverSupport: that target depends on this one). `meetingMode()` and
/// `setMeetingMode(_:)` match `DriverHAL`; `DriverHAL` has no `micCanBeDefault()`, so injecting
/// `CoreAudioDriverHAL` takes an extension that reads `device(uid:)?.canBeDefault`.
public protocol MeetingModeSwitch: Sendable {
    /// `'ttmm'` now. nil: the Feed has no such property (driver 0.1.0, where the Mic can always be
    /// the default) or the Feed is not loaded.
    func meetingMode() -> Bool?
    /// Writes `'ttmm'`. Only an accepted Feed client process may (others get
    /// kAudioHardwareIllegalOperationError).
    func setMeetingMode(_ on: Bool) -> OSStatus
    /// TalkTalk Mic's `kAudioDevicePropertyDeviceCanBeDefaultDevice` (input scope); nil: no Mic.
    func micCanBeDefault() -> Bool?
}

/// Core Audio implementation (the same calls as m0-driver's `CoreAudioDriverHAL`).
public struct CoreAudioMeetingModeSwitch: MeetingModeSwitch {
    /// `'ttmm'` on the Feed (generated from scripts/lib/versions.sh).
    public static let selector: AudioObjectPropertySelector = DriverPins.meetingModeSelector

    public init() {}

    public func meetingMode() -> Bool? {
        guard let feed = Self.translate(uid: DriverPins.feedUID) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: Self.selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(feed, &address) else { return nil }
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList?>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(feed, &address, 0, nil, &size, $0) }
        guard st == noErr, let v = value?.takeRetainedValue(), let n = v as? NSNumber else { return nil }
        return n.intValue != 0
    }

    /// A CFNumber: custom driver properties can only be CFString or CFPropertyList.
    public func setMeetingMode(_ on: Bool) -> OSStatus {
        guard let feed = Self.translate(uid: DriverPins.feedUID) else { return OSStatus(kAudioHardwareBadDeviceError) }
        var address = AudioObjectPropertyAddress(mSelector: Self.selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFPropertyList = NSNumber(value: on ? 1 : 0)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(feed, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
    }

    public func micCanBeDefault() -> Bool? {
        guard let mic = Self.translate(uid: DriverPins.micUID) else { return nil }
        let v: UInt32? = InputDeviceCatalog.scalar(mic, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                   scope: kAudioObjectPropertyScopeInput)
        return v.map { $0 != 0 }
    }

    /// `kAudioHardwarePropertyTranslateUIDToDevice` (finds the hidden Feed too).
    static func translate(uid: String) -> AudioObjectID? {
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
}

/// How sysinput uses the switch (§8.6 "会议模式开关").
public enum MeetingModeGate {
    public enum Readiness: Sendable, Equatable {
        /// The Mic can be the default input now (`'ttmm'` already 1, or driver 0.1.0).
        case ready
        /// Writing `'ttmm'` = 1 failed (not an accepted Feed client, Feed gone): status kept for the HUD.
        case switchRefused(OSStatus)
        /// `'ttmm'` = 1 was accepted but the Mic's CanBeDefaultDevice did not become 1 in time.
        case notSelectable
    }

    /// Before every write of TalkTalk Mic as the default input (entry, switch-backs, resume).
    /// Polls (10 ms) up to `timeout` seconds of real time; returns at once on the fast paths.
    public static func makeMicSelectable(_ sw: MeetingModeSwitch, timeout: Double) -> Readiness {
        if sw.micCanBeDefault() == true { return .ready }
        // Driver 0.1.0 has no 'ttmm' (and its Mic can always be the default): just try the write.
        guard sw.meetingMode() != nil else { return .ready }
        let st = sw.setMeetingMode(true)
        guard st == noErr else { return .switchRefused(st) }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if sw.micCanBeDefault() == true { return .ready }
            if Date() >= deadline { return .notSelectable }
            usleep(10_000)
        }
    }

    /// After the default input is confirmed to be something else than the Mic (restore, voided,
    /// dropped record, a stale 1 found at idle). Best effort: errors are ignored (the driver
    /// resets it anyway when the Mic next enters the device list).
    @discardableResult
    public static func release(_ sw: MeetingModeSwitch, defaultInputUID: String?) -> Bool {
        guard defaultInputUID != MicPolicy.talkTalkMicUID, sw.meetingMode() == true else { return false }
        return sw.setMeetingMode(false) == noErr
    }
}
