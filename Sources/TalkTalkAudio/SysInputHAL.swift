import CoreAudio
import Foundation
import TalkTalkCore

extension MicPolicy.Device {
    public init(_ d: InputDeviceInfo) {
        self.init(uid: d.uid, name: d.name, transport: d.transport, isAggregate: d.isAggregate, isAlive: d.isAlive)
    }
}

/// The few HAL operations the default-input switch needs (ARCHITECTURE.md, "实时音频与生命周期约束"): read the input
/// device list and the default input, write the default input by UID, and two listeners
/// (`kAudioHardwarePropertyDefaultInputDevice`, `kAudioHardwarePropertyDevices`). Thin on purpose,
/// so `SystemInputSwitcher` and `SysInputGuard` run against a fake in tests. Never touches the
/// default output or the system output.
public protocol SysInputHAL: AnyObject, Sendable {
    func snapshot() -> SystemInputPlan.Snapshot
    /// Writes `kAudioHardwarePropertyDefaultInputDevice`. The caller reads back with `defaultInputUID`.
    func setDefaultInput(uid: String) -> Bool
    func defaultInputUID() -> String?
    /// `onChange` runs on an arbitrary queue whenever the default input or the device list changes.
    func startWatching(_ onChange: @escaping @Sendable () -> Void)
    func stopWatching()
}

extension SysInputHAL {
    /// Write, then read back (§8.6 "写 … 读回确认").
    public func writeAndConfirm(uid: String) -> Bool {
        setDefaultInput(uid: uid) && defaultInputUID() == uid
    }
}

/// Core Audio implementation. Reading properties and writing the default input need no TCC
/// (M0-T8 d1, d6).
public final class CoreAudioSysInputHAL: SysInputHAL, @unchecked Sendable {
    /// Listener blocks are delivered here.
    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.sysinput-hal")
    /// Adding and removing listeners (and `listeners`) happen here, never on `queue`: whether
    /// AudioObjectRemovePropertyListenerBlock may be called from a block running on its own
    /// delivery queue is not documented, so the 'srst' block only schedules the re-add (review of
    /// a7ef015 #7; to be measured in M2 acceptance).
    private let control = DispatchQueue(label: "com.aaajiao.talktalk.sysinput-hal.control")
    private let onControlKey = DispatchSpecificKey<Bool>()
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var onChange: (@Sendable () -> Void)?
    /// `kAudioHardwarePropertyServiceRestarted` notifications seen (a lock: a snapshot from any
    /// thread, a listener callback included, must not wait on a queue).
    private let restartLock = NSLock()
    private var restarts = 0

    public init() {
        control.setSpecific(key: onControlKey, value: true)
    }

    deinit { stopWatching() }

    /// Runs `body` on `control`, inline if already there (a deinit on it must not deadlock).
    private func onControl(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: onControlKey) == true { body() } else { control.sync(execute: body) }
    }

    public func snapshot() -> SystemInputPlan.Snapshot {
        // Read the current input before enumerating devices: HAL may register our Feed client
        // during enumeration, making the Mic appear and allowing macOS to select it.
        let def: AudioObjectID? = InputDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject),
                                                            kAudioHardwarePropertyDefaultInputDevice)
        let defInfo = def.flatMap { id in id == kAudioObjectUnknown ? nil : InputDeviceCatalog.info(for: id) }
        let devices = InputDeviceCatalog.inputDevices()
        return SystemInputPlan.Snapshot(devices: devices.map(MicPolicy.Device.init), defaultInput: defInfo.map(MicPolicy.Device.init),
                                        serviceRestarts: restartLock.withLock { restarts })
    }

    public func setDefaultInput(uid: String) -> Bool {
        guard let d = InputDeviceCatalog.inputDevices().first(where: { $0.uid == uid }) else { return false }
        var id = AudioObjectID(d.objectID)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                            UInt32(MemoryLayout<AudioObjectID>.size), &id)
        return st == noErr
    }

    public func defaultInputUID() -> String? {
        let def: AudioObjectID? = InputDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject),
                                                            kAudioHardwarePropertyDefaultInputDevice)
        guard let def, def != kAudioObjectUnknown else { return nil }
        return InputDeviceCatalog.string(def, kAudioDevicePropertyDeviceUID)
    }

    /// Default input, device list, and `kAudioHardwarePropertyServiceRestarted` (coreaudiod
    /// restarted: AudioHardware.h says every listener must then be added again, so they are; the
    /// restart counts as a Mic vanish even if no snapshot saw it, review of 9d9b3a4 #2).
    public func startWatching(_ onChange: @escaping @Sendable () -> Void) {
        onControl {
            guard listeners.isEmpty else { return }
            self.onChange = onChange
            addListeners()
        }
    }

    /// On `control`.
    private func addListeners() {
        guard let onChange else { return }
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
                listeners.append((addr, block))
            }
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyServiceRestarted,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // On `queue`: count, schedule the re-add on `control` (never remove from here), tell.
            self.restartLock.withLock { self.restarts += 1 }
            self.control.async { [weak self] in
                guard let self, self.onChange != nil else { return }   // stopped meanwhile
                self.removeListeners()
                self.addListeners()
            }
            onChange()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
            listeners.append((addr, block))
        }
    }

    /// On `control`.
    private func removeListeners() {
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        }
        listeners.removeAll()
    }

    public func stopWatching() {
        onControl {
            removeListeners()
            onChange = nil
        }
    }
}

/// The meeting processes "通话结束" looks at (§8.6, §3.1), behind a protocol so tests feed
/// recorded snapshots. nil = could not read (never treated as "the call ended").
public protocol MeetingProcessSource: Sendable {
    func meetingProcesses() -> [CallEndRule.Process]?
}

/// MeetingSourceResolver over the live (or a recorded) process object list. The guard uses the
/// same resolver as the app, not a second copy of the rules.
public struct ResolverProcessSource: MeetingProcessSource {
    public let resolver: MeetingSourceResolver
    public let list: @Sendable () -> [AudioProcessInfo]?

    public init(resolver: MeetingSourceResolver = MeetingSourceResolver(),
                list: @escaping @Sendable () -> [AudioProcessInfo]? = { try? AudioProcessList.current() }) {
        self.resolver = resolver
        self.list = list
    }

    public func meetingProcesses() -> [CallEndRule.Process]? {
        guard let procs = list() else { return nil }
        return resolver.candidates(procs).flatMap { c in
            c.processes.map {
                CallEndRule.Process(appID: c.app.id, pid: $0.pid, isRunningInput: $0.isRunningInput,
                                    isRunningOutput: $0.isRunningOutput)
            }
        }
    }
}

/// A file-backed HAL and process source: a JSON file stands in for Core Audio. For tests and
/// dev only (the guard process uses it under `--sysinput-fake-hal` in the dev build, so
/// cross-process tests never touch the real default input).
///
///     {"devices": [MicPolicy.Device], "defaultUID": "…"|null, "processes": [CallEndRule.Process]|null,
///      "writes": ["uid", …]}
public final class SysInputFileHAL: SysInputHAL, MeetingProcessSource, @unchecked Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var devices: [MicPolicy.Device]
        public var defaultUID: String?
        public var processes: [CallEndRule.Process]?
        public var writes: [String]

        public init(devices: [MicPolicy.Device], defaultUID: String?, processes: [CallEndRule.Process]?, writes: [String] = []) {
            self.devices = devices
            self.defaultUID = defaultUID
            self.processes = processes
            self.writes = writes
        }
    }

    public let path: String
    private let lock = NSLock()

    public init(path: String) { self.path = path }

    public func load() -> State? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    public func save(_ s: State) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func snapshot() -> SystemInputPlan.Snapshot {
        lock.withLock {
            guard let s = load() else { return .init(devices: [], defaultInput: nil) }
            return .init(devices: s.devices, defaultInput: s.devices.first { $0.uid == s.defaultUID })
        }
    }

    public func setDefaultInput(uid: String) -> Bool {
        lock.withLock {
            guard var s = load(), s.devices.contains(where: { $0.uid == uid }) else { return false }
            s.defaultUID = uid
            s.writes.append(uid)
            save(s)
            return true
        }
    }

    public func defaultInputUID() -> String? { lock.withLock { load()?.defaultUID } }
    public func startWatching(_ onChange: @escaping @Sendable () -> Void) {}
    public func stopWatching() {}
    public func meetingProcesses() -> [CallEndRule.Process]? { lock.withLock { load()?.processes } }
}
