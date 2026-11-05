import CoreAudio
import Foundation
import Synchronization
import Testing
import TalkTalkCore
@testable import TalkTalkAudio

private final class WatcherState: Sendable {
    let device = Mutex(AudioDeviceInfo(objectID: 31, uid: "physical", name: "test", transport: "bltn",
        nominalSampleRate: 48_000, inputChannels: 1, outputChannels: 2, isAlive: true))
    let events = Mutex<[(DeviceWatcher.Event, HostTime)]>([])
}

@Suite struct DeviceWatcherTests {
    @Test func repeatedRestartsReResolveUIDAndRejectOldCallbacks() {
        let state = WatcherState()
        let watcher = DeviceWatcher(liveHAL: false, resolve: { _ in state.device.withLock { $0 } },
                                    streams: { id, _ in [id + 100] })
        watcher.startTimed { event, time in state.events.withLock { $0.append((event, time)) } }
        watcher.watch(deviceUID: "physical")
        let first = watcher.registrationEpoch
        let system = HALListenerSet.Key(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted)
        state.device.withLock { $0 = AudioDeviceInfo(objectID: 71, uid: "physical", name: "test", transport: "bltn",
            nominalSampleRate: 44_100, inputChannels: 1, outputChannels: 2, isAlive: true) }
        watcher.deliverForTesting(system, generation: first, at: 111)
        let second = watcher.registrationEpoch
        #expect(second > first)
        #expect(watcher.registeredDeviceKeys.contains(.init(171, kAudioStreamPropertyVirtualFormat)))
        #expect(!watcher.registeredDeviceKeys.contains(.init(131, kAudioStreamPropertyVirtualFormat)))
        watcher.deliverForTesting(system, generation: first, at: 222)
        #expect(watcher.registrationEpoch == second)
        watcher.deliverForTesting(system, generation: second, at: 333)
        #expect(watcher.registrationEpoch > second)
        #expect(state.events.withLock { $0.map(\.1) } == [111, 333])
        watcher.stop()
    }
    @Test func formatEventsCarryUIDAndOriginalTime() {
        let state = WatcherState()
        let watcher = DeviceWatcher(liveHAL: false, resolve: { _ in state.device.withLock { $0 } },
                                    streams: { id, _ in [id + 100] })
        watcher.startTimed { event, time in state.events.withLock { $0.append((event, time)) } }
        watcher.watch(deviceUID: "physical")
        watcher.deliverForTesting(.init(131, kAudioStreamPropertyVirtualFormat), generation: watcher.registrationEpoch, at: 42)
        #expect(state.events.withLock { $0.first?.0 } == .deviceFormatChanged(uid: "physical"))
        #expect(state.events.withLock { $0.first?.1 } == 42)
        watcher.stop()
    }
}
