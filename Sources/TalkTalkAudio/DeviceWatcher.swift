import AppKit
import CoreAudio
import Foundation
import TalkTalkCore

/// Watches capture/output changes without opening an audio device. HAL delivery only timestamps
/// and enqueues; registration and removal use HALListenerSet's separate control queue.
public final class DeviceWatcher: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case devicesChanged, defaultOutputChanged, defaultInputChanged, processListChanged, serviceRestarted
        case deviceSampleRateChanged(uid: String, rate: Double)
        case deviceFormatChanged(uid: String)
        case deviceDied(uid: String)
        case willSleep, didWake, sessionResigned, sessionActivated
    }

    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.device-watcher", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var handler: (@Sendable (Event, HostTime) -> Void)?
    private var listeners: HALListenerSet?
    private var watchedUIDs: Set<String> = []
    private var deviceKeys: [HALListenerSet.Key: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var epoch: UInt64 = 0
    private let liveHAL: Bool
    private let resolve: @Sendable (String) -> AudioDeviceInfo?
    private let streams: @Sendable (AudioObjectID, AudioObjectPropertyScope) -> [AudioObjectID]

    public convenience init() {
        self.init(liveHAL: true,
                  resolve: { uid in AudioDeviceCatalog.devices().first { $0.uid == uid } },
                  streams: { id, scope in HALReads.objectList(id, kAudioDevicePropertyStreams, scope: scope) ?? [] })
    }
    init(liveHAL: Bool, resolve: @escaping @Sendable (String) -> AudioDeviceInfo?,
         streams: @escaping @Sendable (AudioObjectID, AudioObjectPropertyScope) -> [AudioObjectID]) {
        self.liveHAL = liveHAL; self.resolve = resolve; self.streams = streams
        queue.setSpecific(key: queueKey, value: ())
    }
    deinit { stop() }

    public func start(_ handler: @escaping @Sendable (Event) -> Void) {
        startTimed { event, _ in handler(event) }
    }
    /// Time is captured when the HAL/NSWorkspace notification arrives, before any actor hop.
    public func startTimed(_ handler: @escaping @Sendable (Event, HostTime) -> Void) {
        onQueue {
            guard self.handler == nil else { return }
            self.handler = handler
            registerAll()
            guard liveHAL else { return }
            let notificationCenter = NSWorkspace.shared.notificationCenter
            let pairs: [(Notification.Name, Event)] = [
                (NSWorkspace.willSleepNotification, .willSleep), (NSWorkspace.didWakeNotification, .didWake),
                (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
                (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
            ]
            let owner = AudioWeakReference(self), queue = self.queue
            observers = pairs.map { name, event in
                notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
                    let time = HostClock.now()
                    queue.async { owner.value?.handler?(event, time) }
                }
            }
        }
    }

    public func watch(deviceUID uid: String) {
        onQueue { if watchedUIDs.insert(uid).inserted, handler != nil { updateKeys() } }
    }
    public func unwatch(deviceUID uid: String) {
        onQueue { if watchedUIDs.remove(uid) != nil, handler != nil { updateKeys() } }
    }
    public func stop() {
        onQueue {
            handler = nil; epoch &+= 1
            listeners?.stop(); listeners = nil; deviceKeys.removeAll(); watchedUIDs.removeAll()
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observers.removeAll()
        }
    }

    private var systemKeys: Set<HALListenerSet.Key> {
        let id = AudioObjectID(kAudioObjectSystemObject)
        return Set([kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyServiceRestarted].map { HALListenerSet.Key(id, $0) })
    }
    private func updateKeys() {
        deviceKeys.removeAll()
        for uid in watchedUIDs {
            guard let device = resolve(uid) else { continue }
            let id = AudioObjectID(device.objectID)
            for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
                deviceKeys[.init(id, selector)] = uid
            }
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                deviceKeys[.init(id, kAudioDevicePropertyStreams, scope)] = uid
                deviceKeys[.init(id, kAudioDevicePropertyStreamConfiguration, scope)] = uid
                for stream in streams(id, scope) { deviceKeys[.init(stream, kAudioStreamPropertyVirtualFormat)] = uid }
            }
        }
        listeners?.set(systemKeys.union(deviceKeys.keys))
        _ = listeners?.current
    }
    private func registerAll() {
        epoch &+= 1
        listeners?.stop(); listeners = nil
        if liveHAL {
            let generation = epoch, queue = self.queue, owner = AudioWeakReference(self)
            listeners = HALListenerSet(label: "com.aaajiao.talktalk.device-watcher.hal") { key in
                let time = HostClock.now()
                queue.async { owner.value?.changed(key, generation: generation, at: time) }
            }
        }
        updateKeys() // resolve watched devices by UID again, never reuse pre-restart object IDs
    }
    private func changed(_ key: HALListenerSet.Key, generation: UInt64, at time: HostTime) {
        guard generation == epoch, let handler else { return }
        let event: Event
        if key.object == AudioObjectID(kAudioObjectSystemObject) {
            switch key.selector {
            case kAudioHardwarePropertyServiceRestarted:
                registerAll() // restores ServiceRestarted itself, so a second restart is observed
                event = .serviceRestarted
            case kAudioHardwarePropertyDevices:
                updateKeys(); event = .devicesChanged
            case kAudioHardwarePropertyDefaultOutputDevice: event = .defaultOutputChanged
            case kAudioHardwarePropertyDefaultInputDevice: event = .defaultInputChanged
            case kAudioHardwarePropertyProcessObjectList: event = .processListChanged
            default: return
            }
        } else {
            guard let uid = deviceKeys[key] else { return }
            switch key.selector {
            case kAudioDevicePropertyNominalSampleRate:
                event = .deviceSampleRateChanged(uid: uid, rate: resolve(uid)?.nominalSampleRate ?? 0)
            case kAudioDevicePropertyDeviceIsAlive:
                guard resolve(uid)?.isAlive != true else { return }
                event = .deviceDied(uid: uid)
            default:
                updateKeys(); event = .deviceFormatChanged(uid: uid)
            }
        }
        handler(event, time)
    }
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    var registrationEpoch: UInt64 { onQueue { epoch } }
    var registeredDeviceKeys: Set<HALListenerSet.Key> { onQueue { Set(deviceKeys.keys) } }
    func deliverForTesting(_ key: HALListenerSet.Key, generation: UInt64, at time: HostTime) {
        onQueue { changed(key, generation: generation, at: time) }
    }
}
