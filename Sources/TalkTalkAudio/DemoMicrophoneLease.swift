import Foundation
import Synchronization
import TalkTalkCore

/// Standalone SPEAK demo only. Keeps microphone capture off Bluetooth, and temporarily moves
/// a Bluetooth system input only when it is preventing headphone playback at ringO2's rate.
/// Meeting mode never uses this lease: SystemInputSwitcher alone owns TalkTalk Mic there.
@MainActor
public final class DemoMicrophoneLease {
    private struct Observation: Sendable {
        var active = false, writing = false, changed = false
        var expected: String?
    }
    private final class WatchState: Sendable { let value = Mutex(Observation()) }
    private let observed = WatchState()
    private let hal: any SysInputHAL
    private var originalUID: String?
    private var attempted = false
    public private(set) var selectedMicrophone: MicPolicy.Device?

    public init(hal: any SysInputHAL = CoreAudioSysInputHAL()) { self.hal = hal }

    @discardableResult
    public func begin(standaloneDemo: Bool, preferredMicUID: String?) -> MicPolicy.Device? {
        guard standaloneDemo, selectedMicrophone == nil else { return nil }
        let snapshot = hal.snapshot()
        let candidates = snapshot.devices.filter(MicPolicy.isCandidate)
        guard let selected = MicPolicy.select(candidates, userUID: preferredMicUID).device else { return nil }
        selectedMicrophone = selected
        originalUID = nil; attempted = false
        observed.value.withLock { $0 = Observation(active: true, expected: snapshot.defaultInput?.uid) }
        let observed = observed, hal = hal
        hal.startWatching {
            let current = hal.defaultInputUID()
            observed.value.withLock {
                if $0.active, !$0.writing, current != $0.expected { $0.changed = true }
            }
        }
        return selected
    }

    /// A read-only check also used before a restore. A manual choice is sticky, even if the
    /// user later selects the same device we had selected; never "restore over" that choice.
    public func refresh() {
        let current = hal.defaultInputUID()
        observed.value.withLock {
            if $0.active, !$0.writing, current != $0.expected { $0.changed = true }
        }
    }

    /// Called during demo preparation, not from an audio callback. No output/rate property is
    /// written. One failed write is not retried, and any intervening default-input choice wins.
    @discardableResult
    public func recoverBluetoothOutput(transport: String, sampleRate: Double) -> Bool {
        guard MicPolicy.bluetoothTransports.contains(transport), sampleRate > 0,
              sampleRate != MonitorOutput.ringO2Rate, !attempted, let selectedMicrophone else { return false }
        refresh()
        guard !observed.value.withLock({ $0.changed }) else { return false }
        let snapshot = hal.snapshot()
        guard let original = snapshot.defaultInput, MicPolicy.isBluetooth(original), MicPolicy.isUsable(original),
              snapshot.devices.contains(where: { $0.uid == selectedMicrophone.uid && MicPolicy.isCandidate($0) }),
              hal.defaultInputUID() == original.uid else { return false }
        attempted = true
        observed.value.withLock { $0.writing = true; $0.expected = selectedMicrophone.uid }
        let success = hal.writeAndConfirm(uid: selectedMicrophone.uid)
        let current = hal.defaultInputUID()
        observed.value.withLock {
            $0.writing = false
            if current != $0.expected { $0.changed = true }
        }
        if success { originalUID = original.uid }
        return success
    }

    /// End only after demo capture and monitor output have stopped. If the original headset
    /// disappeared, keep the working physical input instead of selecting an unrelated device.
    @discardableResult
    public func end() -> Bool {
        refresh()
        let changed = observed.value.withLock { state -> Bool in
            state.active = false
            return state.changed
        }
        hal.stopWatching()
        let selected = selectedMicrophone?.uid, original = originalUID
        selectedMicrophone = nil; originalUID = nil; attempted = false
        guard !changed, let selected, let original, hal.defaultInputUID() == selected,
              hal.snapshot().devices.contains(where: { $0.uid == original && MicPolicy.isUsable($0) }) else { return false }
        return hal.writeAndConfirm(uid: original)
    }
}
