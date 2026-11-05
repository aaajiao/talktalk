import CoreAudio
import Foundation
import TalkTalkCore

/// A changing set of Core Audio property listeners (process objects come and go; devices too),
/// for MeetingMicGuard and OutputRouteProbe. Properties only: never opens a device or starts IO.
///
/// Callbacks arrive on `queue`. Adding and removing happen on a separate serial `control` queue,
/// never from a callback on `queue` (whether removing a listener on its own delivery queue can
/// block is not documented; the same rule as CoreAudioSysInputHAL, review of a7ef015 #7).
/// `kAudioHardwarePropertyServiceRestarted`: AudioHardware.h says every listener has to be added
/// again; `restart(keys:)` drops the old registrations and adds the new set.
final class HALListenerSet: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var object: AudioObjectID
        var selector: AudioObjectPropertySelector
        var scope: AudioObjectPropertyScope

        init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
            self.object = object; self.selector = selector; self.scope = scope
        }

        var address: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }
    }

    private let queue: DispatchQueue
    private let control: DispatchQueue
    private let onControlKey = DispatchSpecificKey<Bool>()
    /// Only on `control`.
    private var registered: [Key: AudioObjectPropertyListenerBlock] = [:]
    private var stopped = false
    private let handler: @Sendable (Key) -> Void

    init(label: String, handler: @escaping @Sendable (Key) -> Void) {
        queue = DispatchQueue(label: label)
        control = DispatchQueue(label: label + ".control")
        self.handler = handler
        control.setSpecific(key: onControlKey, value: true)
    }

    deinit {
        let regs = registered
        for (k, block) in regs {
            var a = k.address
            AudioObjectRemovePropertyListenerBlock(k.object, &a, queue, block)
        }
    }

    /// Makes the registered set exactly `keys` (async on `control`).
    func set(_ keys: Set<Key>) {
        control.async { [weak self] in self?.apply(keys, dropAll: false) }
    }

    /// After a coreaudiod restart: every listener again (async on `control`).
    func restart(_ keys: Set<Key>) {
        control.async { [weak self] in self?.apply(keys, dropAll: true) }
    }

    /// Removes everything and ignores later `set` calls. Waits for `control` (not from `queue`).
    func stop() {
        let body = { [self] in
            stopped = true
            apply([], dropAll: true)
        }
        if DispatchQueue.getSpecific(key: onControlKey) == true { body() } else { control.sync(execute: body) }
    }

    /// The keys registered right now (tests, diagnostics).
    var current: Set<Key> {
        if DispatchQueue.getSpecific(key: onControlKey) == true { return Set(registered.keys) }
        return control.sync { Set(registered.keys) }
    }

    /// On `control`.
    private func apply(_ keys: Set<Key>, dropAll: Bool) {
        let target: Set<Key> = stopped ? [] : keys
        for (k, block) in registered where dropAll || !target.contains(k) {
            var a = k.address
            // A dead object (process exited, coreaudiod restarted) answers with an error: fine.
            AudioObjectRemovePropertyListenerBlock(k.object, &a, queue, block)
            registered[k] = nil
        }
        for k in target where registered[k] == nil {
            let h = handler
            let block: AudioObjectPropertyListenerBlock = { _, _ in h(k) }
            var a = k.address
            if AudioObjectAddPropertyListenerBlock(k.object, &a, queue, block) == noErr { registered[k] = block }
        }
    }
}

/// Device and process-object reads shared by MeetingMicGuard and OutputRouteProbe.
enum HALReads {
    /// `kAudioProcessPropertyDevices` in `scope` (input: what it reads; output: what it plays on).
    static func processDevices(_ process: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID]? {
        objectList(process, kAudioProcessPropertyDevices, scope: scope)
    }

    static func objectList(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        if size == 0 { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func uid(_ d: AudioObjectID) -> String? { InputDeviceCatalog.string(d, kAudioDevicePropertyDeviceUID) }
    static func name(_ d: AudioObjectID) -> String? { InputDeviceCatalog.string(d, kAudioObjectPropertyName) }
    static func transport(_ d: AudioObjectID) -> UInt32 { InputDeviceCatalog.scalar(d, kAudioDevicePropertyTransportType) ?? 0 }

    static func isAggregate(_ d: AudioObjectID) -> Bool {
        let classID: AudioClassID = InputDeviceCatalog.scalar(d, kAudioObjectPropertyClass) ?? 0
        return transport(d) == kAudioDeviceTransportTypeAggregate || classID == kAudioAggregateDeviceClassID
    }

    /// An input device for MeetingMicGuardPlan (nil: its UID could not be read).
    static func inputDevice(_ d: AudioObjectID) -> MeetingMicGuardPlan.InputDevice? {
        guard let uid = uid(d) else { return nil }
        let agg = isAggregate(d)
        var subs: [String] = []
        if agg, let ids = objectList(d, kAudioAggregateDevicePropertyActiveSubDeviceList) {
            subs = inputSubDeviceUIDs(ids.map { (channels: inputChannels($0), uid: Self.uid($0)) })
        }
        return MeetingMicGuardPlan.InputDevice(uid: uid, name: name(d) ?? uid, isAggregate: agg, inputSubDeviceUIDs: subs)
    }

    /// An aggregate's input sub-devices. One whose channel count or UID cannot be read empties the
    /// list: an aggregate with unknown sub-devices is red (§8.6), never "TalkTalk Mic only" because
    /// a physical mic in it failed to read once (review of a5b2b6b #1). Only a sub-device read
    /// as having 0 input channels is left out.
    static func inputSubDeviceUIDs(_ subs: [(channels: Int?, uid: String?)]) -> [String] {
        var out: [String] = []
        for s in subs {
            guard let c = s.channels else { return [] }
            if c == 0 { continue }
            guard let u = s.uid else { return [] }
            out.append(u)
        }
        return out
    }

    /// Input channels (`kAudioDevicePropertyStreamConfiguration`, input scope); nil: not readable.
    static func inputChannels(_ id: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        if size == 0 { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// An output device for OutputRouteClassifier (nil: its UID could not be read).
    static func outputDevice(_ d: AudioObjectID) -> OutputRouteClassifier.Device? {
        guard let uid = uid(d) else { return nil }
        let code = transport(d)
        let t: OutputRouteClassifier.Transport = isAggregate(d) ? .aggregate
            : OutputRouteClassifier.Transport(fourCC: InputDeviceCatalog.fourCC(code))
        let ds: UInt32? = InputDeviceCatalog.scalar(d, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        return OutputRouteClassifier.Device(uid: uid, name: name(d) ?? uid, transport: t, dataSource: ds)
    }

    static func defaultOutput() -> AudioObjectID? {
        let id: AudioObjectID? = InputDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject),
                                                           kAudioHardwarePropertyDefaultOutputDevice)
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The device with this UID (kAudioHardwarePropertyTranslateUIDToDevice), nil if not listed.
    static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }
}

/// Capture this box on HAL's delivery queue; resolve the owner only after hopping to its queue.
/// That keeps the last owner release (and listener teardown) off HAL's delivery queue.
final class AudioWeakReference<Owner: AnyObject>: @unchecked Sendable {
    weak var value: Owner?
    init(_ value: Owner? = nil) { self.value = value }
}
