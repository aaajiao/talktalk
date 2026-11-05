import Testing
import TalkTalkAudio
import TalkTalkCore

@MainActor struct DemoMicrophoneLeaseTests {
    @Test func standaloneDemoSelectsBuiltInAndRestoresOnlyItsOwnInput() {
        let hal = FakeHAL(devices: [Devs.ear4, Devs.usb, Devs.builtIn, Devs.mic], defaultUID: Devs.ear4.uid)
        let lease = DemoMicrophoneLease(hal: hal)
        #expect(lease.begin(standaloneDemo: false, preferredMicUID: nil) == nil)
        #expect(!lease.recoverBluetoothOutput(transport: "blue", sampleRate: 24_000))
        #expect(hal.writes.isEmpty)
        #expect(lease.begin(standaloneDemo: true, preferredMicUID: Devs.ear4.uid)?.uid == Devs.builtIn.uid)
        #expect(!lease.recoverBluetoothOutput(transport: "blue", sampleRate: 48_000))
        #expect(lease.recoverBluetoothOutput(transport: "blue", sampleRate: 24_000))
        #expect(hal.defaultInputUID() == Devs.builtIn.uid)
        #expect(lease.end())
        #expect(hal.writes == [Devs.builtIn.uid, Devs.ear4.uid])

        hal.setDefault(Devs.mic.uid)
        _ = lease.begin(standaloneDemo: true, preferredMicUID: nil)
        #expect(!lease.recoverBluetoothOutput(transport: "blue", sampleRate: 24_000))
        #expect(!lease.end())
        #expect(hal.defaultInputUID() == Devs.mic.uid)
    }

    @Test func manualInputChangeStaysAuthoritativeEvenAfterSelectingOurDeviceAgain() {
        let hal = FakeHAL(devices: [Devs.ear4, Devs.usb, Devs.builtIn], defaultUID: Devs.ear4.uid)
        let lease = DemoMicrophoneLease(hal: hal)
        _ = lease.begin(standaloneDemo: true, preferredMicUID: nil)
        #expect(lease.recoverBluetoothOutput(transport: "blue", sampleRate: 24_000))
        hal.setDefault(Devs.usb.uid); lease.refresh()
        hal.setDefault(Devs.builtIn.uid); lease.refresh()
        #expect(!lease.end())
        #expect(hal.defaultInputUID() == Devs.builtIn.uid)
        #expect(hal.writes == [Devs.builtIn.uid])
    }
}
