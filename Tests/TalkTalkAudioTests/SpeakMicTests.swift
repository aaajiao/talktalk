import Foundation
import Synchronization
import Testing
import TalkTalkCore
@testable import TalkTalkAudio

@Suite struct SpeakMicTests {
    private var profile: PolicyProfile.Speak {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try PolicyProfile.load(from: root.appendingPathComponent("Resources/PolicyProfile.default.json")).speak
        }
    }
    @Test func ringEnforcesFloorCapacityAndIdleErase() throws {
        let ring = SpeakMicRing()
        #expect(ring.capacity == 75 * 16_000)
        let start: HostTime = 1_000_000_000
        ring.append(Array(repeating: 0.5, count: 32_000), at: start)
        ring.beginPress(floor: start + 1_300_000_001)
        let clip = try #require(ring.read(from: start, to: start + 2_000_000_000))
        #expect(clip.start == start + 1_300_062_500)
        #expect(clip.samples.count == 11_199)
        ring.clearIdle(before: start + 1_500_000_000)
        #expect(ring.count == 8000)
        #expect(ring.read(from: start, to: start + 1_500_000_000) == nil)
        ring.reset()
        ring.append(Array(repeating: 1, count: ring.capacity + 10), at: start)
        #expect(ring.count == ring.capacity)
        #expect(ring.oldestHostTime == start + 625_000)
        ring.reset()
        ring.append(Array(repeating: 0, count: 3200), at: start)
        ring.append((0..<320).map(Float.init), at: start + 199_750_000)
        ring.beginPress(floor: start + 200_000_000)
        let drifted = try #require(ring.read(from: start, to: start + 210_000_000))
        #expect(drifted.start >= ring.floor && drifted.samples.first == 4)
        #expect(ring.readLatestBlock()?.samples.count == 316)
    }
    @Test func vadOnsetHangoverPercentileAndRate() throws {
        #expect(throws: SpeakVAD.Failure.self) { try SpeakVAD(sampleRate: 48_000) }
        let vad = SpeakVAD(classify: { _ in true })
        var now: HostTime = 1_000_000_000
        for _ in 0..<150 { _ = vad.push(Array(repeating: 0.00001, count: 320), at: now); now += 20_000_000 }
        #expect(vad.thresholdDb == -55)
        let voiced = Array(repeating: Float(0.1), count: 320)
        #expect(vad.push(voiced, at: now).events.isEmpty)
        #expect(vad.push(voiced, at: now + 20_000_000).events.isEmpty)
        #expect(vad.push(voiced, at: now + 40_000_000).events == [.began(now)])
        for i in 0..<5 { #expect(vad.push(Array(repeating: 0, count: 320), at: now + 60_000_000 + UInt64(i) * 20_000_000).events.isEmpty) }
        #expect(vad.push(Array(repeating: 0, count: 320), at: now + 160_000_000).events == [.ended(now + 60_000_000)])
        let noise = SpeakVAD(classify: { _ in false })
        for i in 0...150 { _ = noise.push(Array(repeating: 0.001, count: 320), at: UInt64(i) * 20_000_000) }
        #expect(abs(noise.thresholdDb - (-48)) < 0.01)
    }
    @Test func coldHotCaptureAndRateReplacementUseStampedBlocks() async throws {
        let rig = FakeMicRig()
        let mic = try MicIngest(profile: profile, onBlock: { rig.block($0) }, onSystemEvent: { event, _ in rig.event(event) },
                                devices: { rig.devices }, makeCapture: { rig.make($0) }, watchHAL: false)
        #expect(mic.state.capture == .closed)
        let press = try #require(mic.beginPress(id: 1, keyDownAt: 1_000_000_000, passthroughClosedAt: nil))
        #expect(await eventuallyMic { mic.state.capture == .open })
        let first = try #require(rig.latest)
        first.feed(at: 1_000_000_000, frame: 0)
        #expect(await eventuallyMic { rig.blockCount == 1 })
        #expect(rig.lastBlock?.hostTime == 1_000_000_000)
        press.cancel()
        #expect(await eventuallyMic { mic.state.capture == .closed })
        mic.setHot(true)
        #expect(await eventuallyMic { mic.state.capture == .open })
        let old = try #require(rig.latest)
        rig.changeRate(48_000)
        old.interrupt(.sampleRateChanged(to: 48_000))
        #expect(await eventuallyMic { mic.stats.deviceRate == 48_000 })
        #expect(rig.events.contains(.micFormatChanged))
        #expect(rig.creationEvents.last == .micFormatChanged)
        let resampled = try #require(rig.latest)
        resampled.feed(at: 2_000_000_000, frame: 0, count: 480)
        resampled.feed(at: 2_010_000_000, frame: 480, count: 480)
        #expect(await eventuallyMic { mic.stats.frames16k >= 630 })
        #expect(rig.lastBlock?.hostTime == 2_010_000_000)
        rig.unplug()
        resampled.interrupt(.deviceDied)
        #expect(await eventuallyMic { rig.latest?.device.uid == "replacement" })
        #expect(rig.creationEvents.last == .micUnplugged)
        mic.setHot(false)
        #expect(await eventuallyMic { mic.state.capture == .closed })
        mic.stop()
    }

    @Test func heldSpeechEmitsSegmentBeforeRelease() async throws {
        let rig = FakeMicRig(), clips = Mutex<[SpeakClip]>([])
        let mic = try MicIngest(profile: profile, devices: { rig.devices }, makeCapture: { rig.make($0) },
                                watchHAL: false, vad: SpeakVAD(classify: { _ in true }))
        let start: HostTime = 1_000_000_000
        let press = try #require(mic.beginPress(id: 1, keyDownAt: start, passthroughClosedAt: nil))
        #expect(await eventuallyMic { rig.latest != nil })
        let reader = Task { for await clip in press.clips { clips.withLock { $0.append(clip) } } }
        let capture = try #require(rig.latest)
        for i in 0..<120 { capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320)) }
        #expect(await eventuallyMic { !clips.withLock { $0.isEmpty } })
        #expect(clips.withLock { !$0[0].isFinal && $0[0].pcm.start >= start - 300_000_000 })
        press.cancel(); mic.stop(); await reader.value
    }

    @Test func inputLevelUsesCaptureTimeWithoutRequiringASRAndClearsOnStop() async throws {
        let rig = FakeMicRig()
        let mic = try MicIngest(profile: profile, devices: { rig.devices }, makeCapture: { rig.make($0) }, watchHAL: false)
        defer { mic.stop() }
        let start: HostTime = 1_000_000_000
        #expect(mic.inputLevel(at: start) == nil)
        mic.setHot(true) // Original-audio capture: no press or recognition stream.
        #expect(await eventuallyMic { mic.state.capture == .open })
        #expect(mic.inputLevel(at: start) == nil)
        let capture = try #require(rig.latest)
        capture.feed(at: start, frame: 0, value: 0.25)
        #expect(await eventuallyMic { mic.inputLevel(at: start + 20_000_000) == 0.25 })
        #expect(mic.inputLevel(at: start + 19_000_000) == nil)
        #expect(mic.inputLevel(at: start + 270_000_001) == nil)
        capture.feed(at: start + 20_000_000, frame: 320, value: 0)
        #expect(await eventuallyMic { mic.inputLevel(at: start + 40_000_000) == 0 })
        mic.setHot(false)
        #expect(await eventuallyMic { mic.state.capture == .closed })
        #expect(mic.inputLevel(at: start + 40_000_000) == nil)
        mic.setHot(true)
        #expect(await eventuallyMic { mic.state.capture == .open })
        #expect(mic.inputLevel(at: start + 40_000_000) == nil)
        mic.stop()
        #expect(mic.inputLevel(at: start + 40_000_000) == nil)
    }

    @Test func rapidRestartSplitsReleasedTailWithoutOverlappingOrLosingNewAudio() async throws {
        let rig = FakeMicRig(), blocked = Mutex(false), proceed = DispatchSemaphore(value: 0)
        let start: HostTime = 1_000_000_000, nextStart: HostTime = 1_900_000_000
        let mic = try MicIngest(profile: profile, onBlock: { block in
            if block.hostTime == start + 800_000_000 {
                blocked.withLock { $0 = true }
                _ = proceed.wait(timeout: .now() + 1)
            }
        }, devices: { rig.devices }, makeCapture: { rig.make($0) },
            watchHAL: false, vad: SpeakVAD(classify: { _ in true }))
        defer { proceed.signal(); mic.stop() }
        let first = try #require(mic.beginPress(id: 1, keyDownAt: start, passthroughClosedAt: start))
        #expect(mic.beginPress(id: 99, keyDownAt: start, passthroughClosedAt: start) == nil)
        #expect(await eventuallyMic { rig.latest != nil })
        let capture = try #require(rig.latest)
        let firstReader = Task { var clips: [SpeakClip] = []; for await clip in first.clips { clips.append(clip) }; return clips }
        for i in 0..<40 { capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320)) }
        first.release(at: start + 800_000_000, reason: .keyUp)
        capture.feed(at: start + 800_000_000, frame: 40 * 320)
        #expect(await eventuallyMic { blocked.withLock { $0 } })
        // These queued blocks cross both the new key-down and the old 250 ms tail deadline.
        for i in 41..<80 {
            capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: i < 45 ? 0.1 : 0.2)
        }
        let second = try #require(mic.beginPress(id: 2, keyDownAt: nextStart, passthroughClosedAt: nextStart))
        let secondReader = Task { var clips: [SpeakClip] = []; for await clip in second.clips { clips.append(clip) }; return clips }
        proceed.signal()
        let old = try #require(await firstReader.value.last)
        #expect(old.pcm.end == nextStart && old.pcm.samples.count == 14_400)
        first.cancel() // A late old owner cannot clear the new reservation.
        #expect(mic.beginPress(id: 3, keyDownAt: nextStart, passthroughClosedAt: nextStart) == nil)
        second.release(at: start + 1_600_000_000, reason: .keyUp)
        for i in 80..<96 { capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: 0.2) }
        let new = try #require(await secondReader.value.first)
        #expect(new.pcm.start == nextStart && new.pcm.start == old.pcm.end)
        #expect(new.pcm.samples.count == 15_200 && new.pcm.samples.allSatisfy { $0 == 0.2 })
    }

    @Test func stopAndImmediateReleaseFinishesPressStreams() async throws {
        let rig = FakeMicRig()
        var mic: MicIngest? = try MicIngest(profile: profile, devices: { rig.devices }, makeCapture: { rig.make($0) }, watchHAL: false)
        let press = try #require(mic?.beginPress(id: 1, keyDownAt: HostClock.now(), passthroughClosedAt: nil))
        #expect(await eventuallyMic { rig.latest != nil })
        mic?.stop(); mic = nil
        let reader = Task { for await _ in press.clips {}; for await _ in press.preview {}; rig.markFinished() }
        #expect(await eventuallyMic { rig.finished })
        reader.cancel()
    }
}

private func eventuallyMic(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<500 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(2)) }
    return condition()
}
private final class FakeMicRig: @unchecked Sendable {
    private let lock = NSLock()
    private var rate = 16_000.0
    private var uid = "physical"
    private var capture: FakeSpeakCapture?
    private var blocks: [MicBlock] = []
    private var systemEvents: [PassthroughSystemEvent] = []
    private var createdAfter: [PassthroughSystemEvent?] = []
    private var didFinish = false
    var finished: Bool { lock.withLock { didFinish } }
    func markFinished() { lock.withLock { didFinish = true } }
    var devices: [InputDeviceInfo] { lock.withLock { [.init(objectID: 9, uid: uid, name: "Microphone", transport: "bltn", nominalSampleRate: rate, inputChannels: 1, isAlive: true, isAggregate: false)] } }
    var latest: FakeSpeakCapture? { lock.withLock { capture } }
    var blockCount: Int { lock.withLock { blocks.count } }
    var lastBlock: MicBlock? { lock.withLock { blocks.last } }
    var events: [PassthroughSystemEvent] { lock.withLock { systemEvents } }
    var creationEvents: [PassthroughSystemEvent?] { lock.withLock { createdAfter } }
    func changeRate(_ rate: Double) { lock.withLock { self.rate = rate } }
    func unplug() { lock.withLock { uid = "replacement" } }
    func block(_ block: MicBlock) { lock.withLock { blocks.append(block) } }
    func event(_ event: PassthroughSystemEvent) { lock.withLock { systemEvents.append(event) } }
    func make(_ device: InputDeviceInfo) -> any SpeakCapture {
        lock.withLock {
            let next = FakeSpeakCapture(device); capture = next; createdAfter.append(systemEvents.last); return next
        }
    }
}
private final class FakeSpeakCapture: SpeakCapture, @unchecked Sendable {
    let device: InputDeviceInfo
    var sampleRate: Double { device.nominalSampleRate }
    private let lock = NSLock()
    private var chunk: (@Sendable (MicCapture.Chunk) -> Void)?
    private var interruption: (@Sendable (MicCapture.Interruption) -> Void)?
    init(_ device: InputDeviceInfo) { self.device = device }
    func start(onChunk: @escaping @Sendable (MicCapture.Chunk) -> Void, onInterruption: @escaping @Sendable (MicCapture.Interruption) -> Void) throws {
        lock.withLock { chunk = onChunk; interruption = onInterruption }
    }
    func stop() { lock.withLock { chunk = nil; interruption = nil } }
    func setDrainCadence(milliseconds: Int) {}
    func feed(at: HostTime, frame: UInt64, count: Int = 320, value: Float = 0.1) { lock.withLock { chunk }?(.init(samples: Array(repeating: value, count: count), startFrame: frame, hostTime: at)) }
    func interrupt(_ event: MicCapture.Interruption) { lock.withLock { interruption }?(event) }
}
