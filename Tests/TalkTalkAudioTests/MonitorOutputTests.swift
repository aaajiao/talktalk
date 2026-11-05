import CAudioCore
import CoreAudio
import Foundation
import Synchronization
import Testing
import TalkTalkCore
@testable import TalkTalkAudio

/// The HAL as the test sets it: devices by id (or the failure their describe throws), the default
/// output, the dead ones, and what turning their input streams off confirms.
private final class FakeHAL: Sendable {
    enum InputsOff: Sendable { case all, only(Int), refused }
    private struct S {
        var devices: [AudioObjectID: Result<MonitorOutput.Target, MonitorOutput.Failure>] = [:]
        var defaultID: AudioObjectID?
        var dead: Set<AudioObjectID> = []
        var inputsOff = InputsOff.all
        var turnOffCalls: [Int] = []
    }
    private let s = Mutex(S())

    func set(_ t: MonitorOutput.Target) { s.withLock { $0.devices[t.id] = .success(t); $0.dead.remove(t.id) } }
    func fail(_ id: AudioObjectID, _ f: MonitorOutput.Failure) { s.withLock { $0.devices[id] = .failure(f) } }
    func setDefault(_ id: AudioObjectID?) { s.withLock { $0.defaultID = id } }
    func kill(_ id: AudioObjectID) { s.withLock { _ = $0.dead.insert(id) } }
    func setInputsOff(_ m: InputsOff) { s.withLock { $0.inputsOff = m } }
    var turnOffCalls: [Int] { s.withLock { $0.turnOffCalls } }

    var hal: MonitorOutput.HAL {
        MonitorOutput.HAL(
            realIO: false,
            defaultOutput: { [self] in s.withLock { st in st.defaultID.flatMap { st.dead.contains($0) ? nil : $0 } } },
            describe: { [self] id in
                guard let r = s.withLock({ $0.devices[id] }) else { throw MonitorOutput.Failure(status: 0, what: "no device \(id)") }
                return try r.get()
            },
            isAlive: { [self] id in s.withLock { !$0.dead.contains(id) } },
            turnOffInputStreams: { [self] _, proc, n in
                #expect(proc == nil)
                let mode = s.withLock { $0.turnOffCalls.append(n); return $0.inputsOff }
                switch mode {
                case .all: return n
                case .only(let k): return k
                case .refused: throw MonitorOutput.Failure(status: -50, what: "IOProcStreamUsage 写不进去", transient: false)
                }
            },
            bufferFrames: { _ in 512 })
    }
}

/// MonitorOutput on a FakeHAL: the default output is set by the test, cycles run through
/// `processOffline` (tt_monitor_process, monitorIOProc's cycle logic), HAL listener callbacks are
/// delivered by the test with the epoch of the registration. The setters queue their change; the
/// helpers here wait for it.
private final class OfflineMonitor {
    let fake = FakeHAL()
    let monitor: MonitorOutput
    let ringO2: RingO
    let changes = ChangeLog()
    private let maxFrames = 4096
    private let list = AudioBufferList.allocate(maximumBuffers: 1)
    private let storage: UnsafeMutablePointer<Float>
    private(set) var ch0: [Float] = []
    private(set) var ch1: [Float] = []

    init() throws {
        ringO2 = try #require(RingO())
        let log = changes
        monitor = MonitorOutput(ringO2: ringO2, events: try #require(EventRing(minCapacity: 4096)), hal: fake.hal) { log.add($0) }
        storage = .allocate(capacity: 4 * maxFrames)
        storage.initialize(repeating: 0, count: 4 * maxFrames)
    }

    deinit {
        free(list.unsafeMutablePointer)
        storage.deallocate()
    }

    /// One stereo cycle; appends both channels. False when not attached.
    @discardableResult
    func cycle(_ frames: Int = 480) -> Bool {
        storage.update(repeating: 777, count: 2 * frames)
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(2 * frames * 4), mData: storage)
        guard monitor.processOffline(list.unsafeMutablePointer, frames: UInt32(frames)) else { return false }
        ch0 += (0..<frames).map { storage[2 * $0] }
        ch1 += (0..<frames).map { storage[2 * $0 + 1] }
        return true
    }

    /// One cycle into a single 4-channel buffer: the four channels' values of its first frame.
    func cycle4(_ frames: Int = 480) -> [Float]? {
        storage.update(repeating: 777, count: 4 * frames)
        list[0] = AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(4 * frames * 4), mData: storage)
        guard monitor.processOffline(list.unsafeMutablePointer, frames: UInt32(frames)) else { return nil }
        return (0..<4).map { storage[$0] }
    }

    func clearOutput() { ch0 = []; ch1 = [] }

    /// A ringO2 clause of a constant value.
    func clause(_ value: Float, frames: Int, tag: UInt32 = 1) {
        let x = [Float](repeating: value, count: frames)
        _ = x.withUnsafeBufferPointer { ringO2.writeClause($0, frames: frames, marks: [.start, .end], tag: tag) }
    }

    /// `t` becomes the default output (nil: none), as the DefaultOutputDevice listener reports it.
    func setDefault(_ t: MonitorOutput.Target?) {
        if let t { fake.set(t) }
        fake.setDefault(t?.id)
        monitor.deliverSystemChange(kAudioHardwarePropertyDefaultOutputDevice, epoch: monitor.systemListenerEpoch)
    }

    /// The attached device now reads as `t`; its listener reports `selector`.
    func change(_ t: MonitorOutput.Target, _ selector: AudioObjectPropertySelector) {
        fake.set(t)
        monitor.deliverPropertyChange(selector, epoch: monitor.listenerEpoch)
    }

    func use(_ u: MonitorOutput.Use, _ on: Bool) { monitor.setUse(u, on); monitor.flush() }
    func speakerMode(_ v: Bool?) { monitor.setMeetingSpeakerMode(v); monitor.flush() }
    func confirm(_ uids: Set<String>) { monitor.setConfirmedHeadphones(uids); monitor.flush() }
    func gainDb(_ db: Float) { monitor.setSelfListenGainDb(db); monitor.flush() }
    func meetingMode(_ on: Bool) { monitor.setMeetingMode(on); monitor.flush() }
    func resume() { monitor.resume(); monitor.flush() }

    static func headphones(id: AudioObjectID = 41, uid: String = "BuiltInHeadphoneOutputDevice", rate: Double = 48_000,
                           inputs: Int = 0) -> MonitorOutput.Target {
        .init(id: id, device: .init(uid: uid, name: OutputRouteClassifier.externalHeadphonesName, transport: .builtIn,
                                    dataSource: OutputRouteClassifier.dataSourceHeadphones),
              sampleRate: rate, inputStreams: inputs)
    }

    static func speakers(id: AudioObjectID = 42, rate: Double = 48_000) -> MonitorOutput.Target {
        .init(id: id, device: .init(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn,
                                    dataSource: OutputRouteClassifier.dataSourceInternalSpeaker),
              sampleRate: rate, inputStreams: 0)
    }

    static func airpods(id: AudioObjectID = 43, rate: Double = 48_000) -> MonitorOutput.Target {
        .init(id: id, device: .init(uid: "AA-BB-CC:output", name: "AirPods", transport: .bluetooth), sampleRate: rate, inputStreams: 1)
    }
}

/// Records the rates a cue was rendered at.
private final class Rates: Sendable {
    private let items = Mutex<[Double]>([])
    func add(_ r: Double) { items.withLock { $0.append(r) } }
    var all: [Double] { items.withLock { $0 } }
}

private final class ChangeLog: Sendable {
    private let items = Mutex<[MonitorOutput.Change]>([])
    func add(_ c: MonitorOutput.Change) { items.withLock { $0.append(c) } }
    var all: [MonitorOutput.Change] { items.withLock { $0 } }
}

private final class Outcome: Sendable {
    private let value = Mutex<Result<Void, any Error>?>(nil)
    func set(_ r: Result<Void, any Error>) { value.withLock { $0 = r } }
    var result: Result<Void, any Error>? { value.withLock { $0 } }
    var error: (any Error)? { if case .failure(let e) = result { return e }; return nil }
}

/// Polls `cond` (sleeping 1 ms between) up to `seconds`; runs `step` each turn. The limit only turns
/// a hang into a failure: under the full parallel suite a first AVAudioConverter can take seconds.
private func wait(seconds: Double = 20, step: () -> Void = {}, until cond: () -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !cond() {
        if Date() > end { return false }
        step()
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

/// Starts an audition in its own task; the outcome is recorded when it ends.
private func audition(_ m: MonitorOutput, _ x: [Float], rate: Double = 24_000) -> (Task<Void, Never>, Outcome) {
    let out = Outcome()
    let t = Task { do { try await m.playAudition(x, sampleRate: rate); out.set(.success(())) } catch { out.set(.failure(error)) } }
    return (t, out)
}

/// Waits (≤ 20 s, running `step` each turn) for an audition to end; cancels it if it has not, so a
/// broken build fails the test instead of hanging it.
private func ended(_ t: Task<Void, Never>, _ out: Outcome, step: () -> Void = {}) async throws -> Bool {
    let done = try await wait(step: step) { out.result != nil }
    if !done { t.cancel() }
    _ = await t.value
    return done
}

private let minus10 = Float(pow(10.0, -0.5))

@Suite struct MonitorOutputTests {
    // MARK: self-listen

    @Test func selfListenPlaysRingO2AtMinusTenDecibelsOnlyWhenEverythingAllows() throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        r.use(.selfListen, true)
        #expect(r.monitor.selfListen == .meetingSpeaker)             // meeting route not known yet: off
        r.speakerMode(false)
        #expect(r.monitor.selfListen == .audible && r.monitor.isSelfListenAudible)
        r.clause(0.5, frames: 4800)
        r.cycle(); r.clearOutput(); r.cycle()                        // past the 5 ms clause fade-in
        for i in 0..<480 {
            #expect(abs(r.ch0[i] - 0.5 * minus10) < 1e-6)
            #expect(r.ch1[i] == r.ch0[i])
        }
        #expect(abs(r.monitor.stats.gain - minus10) < 1e-6)

        r.gainDb(-20)
        #expect(abs(r.monitor.stats.gain - 0.1) < 1e-6)
        r.gainDb(-70)
        #expect(r.monitor.stats.gain == 0)
    }

    @Test func selfListenStateNamesWhyItIsOff() {
        let hp = OfflineMonitor.headphones(), bt = OfflineMonitor.airpods()
        func s(_ t: MonitorOutput.Target?, _ meeting: Bool? = false, _ confirmed: Set<String> = [], wanted: Bool = true) -> MonitorOutput.SelfListen {
            MonitorOutput.selfListenState(wanted: wanted, target: t, meetingSpeakerMode: meeting, confirmedHeadphones: confirmed)
        }
        #expect(s(hp, wanted: false) == .off)
        #expect(s(nil) == .noOutput)
        #expect(s(OfflineMonitor.speakers()) == .notHeadphones)
        #expect(s(bt) == .notHeadphones)                             // Bluetooth only once confirmed
        #expect(s(bt, false, [bt.device.uid]) == .audible)
        #expect(s(hp, nil) == .meetingSpeaker)
        #expect(s(hp, true) == .meetingSpeaker)
        #expect(s(OfflineMonitor.headphones(rate: 44_100)) == .sampleRate(44_100))
        #expect(s(hp) == .audible)
    }

    /// A new context starts at the gains the policy says, not at the defaults ramping: attached
    /// for cues only, ringO2 audio stays silent from the first frame.
    @Test func theFirstCycleNeverRampsFromTheDefaultGain() throws {
        let r = try OfflineMonitor()
        r.clause(0.5, frames: 4800)
        r.setDefault(OfflineMonitor.headphones())
        r.use(.cues, true)
        #expect(r.monitor.isAttached && r.monitor.selfListen == .off)
        r.cycle()
        #expect(r.ch0.allSatisfy { $0 == 0 })
        #expect(r.monitor.stats.audioFrames > 0)                    // ringO2 was read all the same
        #expect(r.monitor.stats.cueGain == 1)
    }

    @Test func speakerModeMutesWithinOneCycleAndReportsARouteChange() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        r.speakerMode(false)
        r.use(.selfListen, true)
        // The attach's own report first, so the one counted below can only be the speaker mode's.
        #expect(try await wait { r.changes.all.filter { $0 == .route }.count == 1 })
        r.clause(0.5, frames: 9600)
        r.cycle(); r.cycle()
        r.speakerMode(true)
        #expect(r.monitor.selfListen == .meetingSpeaker && !r.monitor.isSelfListenAudible)
        #expect(r.monitor.stats.gain == 0)
        r.clearOutput()
        r.cycle(); r.cycle()
        #expect(r.ch0[0] > 0 && r.ch0[479] == 0)                    // the ramp, then silence
        #expect(r.ch0[480...].allSatisfy { $0 == 0 })
        #expect(try await wait { r.changes.all.filter { $0 == .route }.count == 2 })
    }

    @Test func aDeviceNotAt48kKeepsRingO2SilentButStillReadsIt() throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones(rate: 44_100))
        r.speakerMode(false)
        r.use(.selfListen, true)
        #expect(r.monitor.selfListen == .sampleRate(44_100))
        r.clause(0.5, frames: 4800)
        r.cycle(); r.cycle()
        #expect(r.ch0.allSatisfy { $0 == 0 })
        #expect(r.monitor.stats.audioFrames == 960)
    }

    // MARK: cues

    @Test func cuesPlayAtTheDeviceRateOnlyOnHeadphonesWithTheCuesUse() async throws {
        let r = try OfflineMonitor()
        let rates = Rates()
        let cue: @Sendable (Double) -> [Float] = { rate in rates.add(rate); return [Float](repeating: 0.25, count: Int(rate * 0.03)) }

        r.setDefault(OfflineMonitor.headphones(rate: 44_100))
        r.use(.selfListen, true)                                     // attached, but no .cues use
        #expect(r.monitor.isAttached && !r.monitor.cuesAudible)
        #expect(await r.monitor.playCue(cue) == false)
        #expect(r.monitor.stats.cueGain == 0)
        r.use(.cues, true)
        #expect(r.monitor.cuesAudible && r.monitor.stats.cueGain == 1)
        r.cycle(); r.clearOutput()                                   // the cue gain's 0 → 1 ramp, on silence
        #expect(await r.monitor.playCue(cue))
        #expect(rates.all == [44_100])
        r.cycle(1323); r.cycle(480)
        #expect(r.ch0[..<1323].allSatisfy { $0 == 0.25 })            // unity gain, self-listen not audible
        #expect(r.ch1[..<1323].allSatisfy { $0 == 0.25 })
        #expect(r.ch0[1323...].allSatisfy { $0 == 0 })
        #expect(r.monitor.stats.cueFrames == 1323)

        r.setDefault(OfflineMonitor.speakers())                      // the default output becomes the speaker
        #expect(r.monitor.isAttached && !r.monitor.cuesAudible)
        #expect(await r.monitor.playCue(cue) == false)
        #expect(rates.all == [44_100])

        r.setDefault(OfflineMonitor.airpods())
        #expect(!r.monitor.cuesAudible)
        r.confirm([OfflineMonitor.airpods().device.uid])
        #expect(r.monitor.cuesAudible)
        let played = Mutex<Bool?>(nil)
        r.monitor.playCue(cue) { ok in played.withLock { $0 = ok } } // the non-blocking form
        #expect(try await wait { played.withLock { $0 } == true })
        #expect(rates.all == [44_100, 48_000])
    }

    /// Intel built-in output: one device, its data source switches 'hdpn' → 'ispk'. The attachment
    /// stays, and a cue already queued stops within one cycle instead of playing on the speaker.
    @Test func aQueuedCueStopsWithinOneCycleWhenTheSameDeviceTurnsIntoItsSpeaker() async throws {
        let r = try OfflineMonitor()
        let jack = OfflineMonitor.headphones()
        r.setDefault(jack)
        r.use(.cues, true)
        #expect(await r.monitor.playCue { [Float](repeating: 0.25, count: Int($0)) })   // 1 s
        r.cycle()
        #expect(r.ch0.allSatisfy { $0 == 0.25 })
        var speaker = jack
        speaker.device.name = "MacBook Pro Speakers"
        speaker.device.dataSource = OutputRouteClassifier.dataSourceInternalSpeaker
        r.change(speaker, kAudioDevicePropertyDataSource)
        #expect(r.monitor.stats.attachments == 1 && !r.monitor.cuesAudible)
        #expect(r.monitor.stats.cueGain == 0)
        r.clearOutput()
        r.cycle(); r.cycle()
        #expect(r.ch0[0] > 0 && r.ch0[479] == 0)                    // the one-cycle ramp
        #expect(r.ch0[480...].allSatisfy { $0 == 0 } && r.ch1[480...].allSatisfy { $0 == 0 })
        #expect(r.monitor.stats.cueFill == 48_000 - 3 * 480)         // still read: dropped, not held
    }

    @Test func nothingIsPlayedWhileDetached() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        #expect(!r.monitor.isAttached)                               // no use: not attached
        #expect(await r.monitor.playCue { _ in [1] } == false)
        #expect(!r.cycle())
        r.use(.cues, true)
        #expect(r.monitor.isAttached)
        r.use(.cues, false)
        #expect(!r.monitor.isAttached && r.monitor.stats.attachments == 1)
    }

    // MARK: refusals, retries, input streams, channels

    @Test func talkTalksOwnDevicesAreRefusedWithoutRetry() async throws {
        for uid in [DriverPins.feedUID, DriverPins.micUID, DriverPins.testMicUID] {
            let d = OutputRouteClassifier.Device(uid: uid, name: "TalkTalk", transport: .virtual)
            #expect(MonitorOutput.refusal(d) != nil, "\(uid)")
        }
        #expect(MonitorOutput.refusal(OfflineMonitor.headphones().device) == nil)
        let r = try OfflineMonitor()
        var feed = OfflineMonitor.headphones()
        feed.device.uid = DriverPins.feedUID
        r.setDefault(feed)
        r.use(.cues, true)
        #expect(!r.monitor.isAttached)
        #expect(r.monitor.stats.lastFailure?.contains("TalkTalk") == true)
        #expect(r.monitor.pendingRetry == nil)
        #expect(await !r.monitor.isAuditionAvailable)
        let (t, out) = audition(r.monitor, [0.5])
        #expect(try await ended(t, out))
        #expect(out.error is MonitorOutput.AuditionError)
    }

    @Test func aTransientFailureIsRetriedWithBackoffUntilItAttaches() throws {
        let r = try OfflineMonitor()
        let hp = OfflineMonitor.headphones()
        r.fake.fail(hp.id, .init(status: 0, what: "默认输出没有采样率"))
        r.fake.setDefault(hp.id)
        r.use(.cues, true)
        #expect(!r.monitor.isAttached && r.monitor.stats.lastFailure == "默认输出没有采样率")
        #expect(r.monitor.pendingRetry == 0.5)
        r.monitor.fireRetry()
        #expect(r.monitor.pendingRetry == 1)
        r.monitor.fireRetry()
        #expect(r.monitor.pendingRetry == 2)
        r.fake.set(hp)                                               // the device is ready now
        r.monitor.fireRetry()
        #expect(r.monitor.isAttached && r.monitor.stats.lastFailure == nil)
        #expect(r.monitor.pendingRetry == nil)

        // Bounded: 0.5, 1, 2, 4, 5, 5, 5, 5 s, then nothing until something changes.
        #expect((0..<9).map { MonitorOutput.retryDelay(attempt: $0) } == [0.5, 1, 2, 4, 5, 5, 5, 5, nil])
        r.fake.fail(hp.id, .init(status: 0, what: "默认输出没有采样率"))
        r.monitor.deliverSystemChange(kAudioHardwarePropertyDefaultOutputDevice, epoch: r.monitor.systemListenerEpoch)
        #expect(!r.monitor.isAttached)
        var delays: [Double] = []
        for _ in 0..<20 {                                            // bounded: a broken build fails, not hangs
            guard let d = r.monitor.pendingRetry else { break }
            delays.append(d)
            r.monitor.fireRetry()
        }
        #expect(delays == [0.5, 1, 2, 4, 5, 5, 5, 5])
        r.use(.selfListen, true)                                     // a new trigger starts them again
        #expect(r.monitor.pendingRetry == 0.5)
        r.use(.selfListen, false); r.use(.cues, false)               // not wanted: no retry
        #expect(r.monitor.pendingRetry == nil)
    }

    @Test func inputStreamsCountFromTheReadBackAndANewCountRebuilds() throws {
        let r = try OfflineMonitor()
        var bt = OfflineMonitor.airpods()
        r.setDefault(bt)
        r.use(.cues, true)
        #expect(r.monitor.isAttached && r.monitor.stats.inputStreamsDisabled == 1)
        bt.inputStreams = 2
        r.change(bt, kAudioDevicePropertyStreams)
        #expect(r.monitor.stats.attachments == 2 && r.monitor.stats.inputStreamsDisabled == 2)
        #expect(r.fake.turnOffCalls == [1, 2])

        r.fake.setInputsOff(.only(1))                                // the read-back confirms one of three
        bt.inputStreams = 3
        r.change(bt, kAudioDevicePropertyStreams)
        #expect(!r.monitor.isAttached)
        #expect(r.monitor.stats.lastFailure?.contains("只确认关掉 1 条") == true)
        #expect(r.monitor.pendingRetry == nil)                       // permanent

        r.fake.setInputsOff(.refused)
        r.use(.selfListen, true)
        #expect(!r.monitor.isAttached && r.monitor.stats.lastFailure?.contains("IOProcStreamUsage") == true)
        #expect(r.monitor.pendingRetry == nil)

        r.fake.setInputsOff(.all)
        r.fake.fail(bt.id, .init(status: 0, what: "默认输出的输入流读不出来（不知道要关几条）"))
        r.use(.selfListen, false)
        #expect(!r.monitor.isAttached && r.monitor.pendingRetry == 0.5)  // a read failure is no 0: retried
        r.fake.set(bt)
        r.monitor.fireRetry()
        #expect(r.monitor.isAttached && r.monitor.stats.inputStreamsDisabled == 3)
    }

    @Test func stereoSlotsFollowThePreferredPairThroughTheBufferLayout() {
        typealias S = MonitorOutput.StereoSlots
        func s(_ layout: [Int], _ p: (UInt32, UInt32)?) -> S? { MonitorOutput.stereoSlots(channelsPerBuffer: layout, preferred: p) }
        #expect(s([2], (1, 2)) == nil)                               // ≤ 2 channels: every channel
        #expect(s([1, 1], nil) == nil)
        #expect(s([1], (1, 1)) == nil)
        #expect(s([8], (3, 4)) == S(leftBuffer: 0, leftChannel: 2, rightBuffer: 0, rightChannel: 3))
        #expect(s([2, 2], (2, 3)) == S(leftBuffer: 0, leftChannel: 1, rightBuffer: 1, rightChannel: 0))
        #expect(s([4], nil) == S(leftBuffer: 0, leftChannel: 0, rightBuffer: 0, rightChannel: 1))
        #expect(s([4], (0, 9)) == S(leftBuffer: 0, leftChannel: 0, rightBuffer: 0, rightChannel: 1))   // invalid: 1, 2
        #expect(s([6], (5, 5)) == S(leftBuffer: 0, leftChannel: 4, rightBuffer: 0, rightChannel: 4))
        #expect(s([0, 4], (1, 2)) == S(leftBuffer: 1, leftChannel: 0, rightBuffer: 1, rightChannel: 1))
        #expect(s([1, 1, 1, 1], (4, 3)) == S(leftBuffer: 3, leftChannel: 0, rightBuffer: 2, rightChannel: 0))
    }

    @Test func aMultichannelDeviceGetsOnlyItsStereoPairAndANewPairRebuilds() async throws {
        let r = try OfflineMonitor()
        var hp = OfflineMonitor.headphones()
        hp.stereo = .init(leftBuffer: 0, leftChannel: 2, rightBuffer: 0, rightChannel: 3)
        r.setDefault(hp)
        r.use(.cues, true)
        #expect(r.monitor.stats.channelSlots == [0, 2, 0, 3])
        #expect(await r.monitor.playCue { [Float](repeating: 0.25, count: Int($0 * 0.03)) })
        #expect(r.cycle4() == [0, 0, 0.25, 0.25])
        hp.stereo = .init(leftBuffer: 0, leftChannel: 0, rightBuffer: 0, rightChannel: 1)
        r.change(hp, kAudioDevicePropertyPreferredChannelsForStereo)
        #expect(r.monitor.stats.attachments == 2 && r.monitor.stats.channelSlots == [0, 0, 0, 1])
    }

    @Test func disablingCuesWaitsForDeviceLatencyAfterTheRingIsEmpty() async throws {
        let r = try OfflineMonitor()
        var target = OfflineMonitor.headphones()
        target.latencyFrames = 4800
        r.setDefault(target); r.use(.cues, true)
        #expect(await r.monitor.playCue { _ in [Float](repeating: 0.25, count: 1440) })
        r.use(.cues, false)
        #expect(r.monitor.isAttached)
        r.cycle(1440); r.cycle(); r.cycle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(r.monitor.isAttached, "ring empty is not device drained")
        #expect(try await wait { r.cycle(); return !r.monitor.isAttached })
    }

    // MARK: audition

    @Test func theAuditionIsResampledToTheDeviceRatePlayedAtUnityAndEndsWhenRead() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.speakers(rate: 44_100))          // any device class
        #expect(await r.monitor.isAuditionAvailable)
        let x = [Float](repeating: 0.5, count: 6000)                // 250 ms at 24 kHz
        let (task, out) = audition(r.monitor, x)
        #expect(try await ended(task, out, step: { r.cycle(512) }))
        #expect(out.error == nil)
        let s = r.monitor.stats
        #expect(abs(Int(s.cueFrames) - 11_025) <= 64, "\(s.cueFrames)")   // 6000 × 44.1 / 24
        let played = r.ch0.filter { $0 != 0 }
        let mid = played[played.count / 4 ..< 3 * played.count / 4]
        #expect(mid.allSatisfy { abs($0 - 0.5) < 0.01 })
        #expect(try await wait { r.cycle(); return !r.monitor.isAttached })            // held only by the audition
    }

    /// Stop: the next 5 ms are queued faded out, it stays attached until they have played, then
    /// detaches. The output never steps from 0.5 to 0.
    @Test func stoppingTheAuditionFadesItOutAndDrainsBeforeDetaching() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        let (t, out) = audition(r.monitor, [Float](repeating: 0.5, count: 48_000), rate: 48_000)
        #expect(try await wait { r.monitor.stats.cueFill > 0 })
        r.cycle(); r.cycle()
        r.monitor.stopAudition()
        #expect(try await ended(t, out))
        #expect(out.error == nil)
        #expect(r.monitor.isAttached && r.monitor.isDraining)
        for _ in 0..<100 where r.monitor.stats.cueFill > 0 { r.cycle() }
        let last = try #require(r.ch0.lastIndex { $0 != 0 })
        let fade = MonitorOutput.fadeFrames(rate: 48_000)
        #expect(r.ch0[last] < 0.001, "\(r.ch0[last])")
        let tail = r.ch0[(last - fade + 1)...last]
        #expect(zip(tail, tail.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(abs(r.ch0[last - fade] - 0.5) < 1e-6)                // full level right before the fade
        #expect(try await wait { r.cycle(); return !r.monitor.isAttached })
        #expect(!r.monitor.isDraining)
    }

    @Test func aCueInterruptsTheAuditionAfterItsFade() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        r.use(.cues, true)
        let long = [Float](repeating: 0.5, count: 48_000)
        let (t, out) = audition(r.monitor, long, rate: 48_000)
        #expect(try await wait { r.monitor.stats.cueFill > 0 })
        let queued = Int(r.monitor.stats.cueFill)
        #expect(await r.monitor.playCue { rate in [Float](repeating: 0.125, count: Int(rate * 0.03)) })
        #expect(try await ended(t, out))
        #expect(out.error as? MonitorOutput.AuditionError == .interrupted("提示音"))
        r.clearOutput()
        for _ in 0..<100 where r.monitor.stats.cueFill > 0 { r.cycle(480) }
        let first = try #require(r.ch0.firstIndex { $0 == 0.125 })
        #expect(r.ch0.filter { $0 == 0.125 }.count == 1440)           // the cue plays after what was queued
        #expect(r.ch0[first - 1] < 0.001 && r.ch0[first - 1] > 0)     // … and after the audition's fade
        #expect(queued <= r.monitor.cueLeadFrames ?? 0)
        #expect(r.monitor.isAttached)                                // the .cues use keeps it
    }

    @Test func aNewAuditionReplacesTheRunningOneAndCancellationEndsIt() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        let long = [Float](repeating: 0.5, count: 48_000)
        let (t1, first) = audition(r.monitor, long)
        #expect(try await wait { r.monitor.stats.cueFill > 0 })
        let (t2, second) = audition(r.monitor, long)
        #expect(try await ended(t1, first))
        #expect(first.error == nil)
        t2.cancel()
        #expect(try await ended(t2, second))
        #expect(second.error is CancellationError)
        for _ in 0..<100 where r.monitor.stats.cueFill > 0 { r.cycle() }
        #expect(try await wait { r.cycle(); return !r.monitor.isAttached })
    }

    @Test func aDefaultOutputChangeRebuildsAndInterruptsTheAudition() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        r.speakerMode(false)
        r.use(.selfListen, true)
        let (t, out) = audition(r.monitor, [Float](repeating: 0.5, count: 48_000))
        #expect(try await wait { r.monitor.stats.cueFill > 0 })
        r.setDefault(OfflineMonitor.speakers())
        #expect(try await ended(t, out))
        #expect(out.error as? MonitorOutput.AuditionError == .interrupted("输出设备变了"))
        #expect(r.monitor.device?.uid == OfflineMonitor.speakers().device.uid)
        #expect(r.monitor.stats.attachments == 2 && r.monitor.stats.cueFill == 0)   // a new, empty cue ring
        #expect(r.monitor.selfListen == .notHeadphones)

        // The same device with a new data source (headphones plugged into the jack): no rebuild.
        var jack = OfflineMonitor.speakers()
        jack.device.dataSource = OutputRouteClassifier.dataSourceHeadphones
        r.change(jack, kAudioDevicePropertyDataSource)
        #expect(r.monitor.stats.attachments == 2)
        #expect(r.monitor.selfListen == .audible)
        #expect(try await wait { r.changes.all.filter { $0 == .route }.count >= 3 })
    }

    /// §3.4: in meeting mode the default output may be the speaker or a share-sound device.
    @Test func meetingModeBlocksTheAuditionAndInterruptsAPlayingOne() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.speakers())
        let (t, out) = audition(r.monitor, [Float](repeating: 0.5, count: 48_000), rate: 48_000)
        #expect(try await wait { r.monitor.stats.cueFill > 0 })
        r.meetingMode(true)
        #expect(try await ended(t, out))
        #expect(out.error as? MonitorOutput.AuditionError == .interrupted("会议模式"))
        #expect(r.monitor.stats.cueGain == 0)                        // the rest is muted within a cycle
        #expect(await !r.monitor.isAuditionAvailable)
        let (t2, out2) = audition(r.monitor, [0.5])
        #expect(try await ended(t2, out2))
        #expect(out2.error as? MonitorOutput.AuditionError == .unavailable(MonitorOutput.meetingModeReason))
        r.meetingMode(false)
        #expect(await r.monitor.isAuditionAvailable)
    }

    // MARK: suspension, listeners

    @Test func suspendHoldsItDetachedUntilResumeAndAServiceRestartSuspends() async throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        r.use(.selfListen, true)
        r.monitor.suspend()
        #expect(!r.monitor.isAttached && r.monitor.selfListen == .noOutput)
        r.use(.cues, true)
        #expect(await !r.monitor.isAuditionAvailable)
        #expect(!r.monitor.isAttached)
        r.resume()
        #expect(r.monitor.isAttached && r.monitor.cuesAudible)

        r.monitor.deliverServiceRestart()
        #expect(!r.monitor.isAttached)
        #expect(try await wait { r.changes.all.contains(.serviceRestarted) })
        let (t, out) = audition(r.monitor, [0.5])
        #expect(try await ended(t, out))
        #expect(out.error is MonitorOutput.AuditionError)
        r.resume()
        #expect(r.monitor.isAttached)
    }

    /// §3.3 restart rule: the owner's suspend → reset → resume can run before this object's own
    /// ServiceRestarted callback is delivered. That late callback belongs to the old registration
    /// and must not suspend it again.
    @Test func aLateServiceRestartFromTheOldRegistrationIsIgnoredAfterTheOwnersResume() throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        r.use(.cues, true)
        let old = r.monitor.systemListenerEpoch
        r.monitor.suspend()
        r.resume()
        #expect(r.monitor.isAttached && r.monitor.systemListenerEpoch != old)
        r.monitor.deliverSystemChange(kAudioHardwarePropertyServiceRestarted, epoch: old)
        #expect(r.monitor.isAttached)
    }

    @Test func aStaleListenerCallbackLeavesANewAttachmentAlone() throws {
        let r = try OfflineMonitor()
        r.setDefault(OfflineMonitor.headphones())
        r.use(.cues, true)
        let old = r.monitor.listenerEpoch
        r.setDefault(OfflineMonitor.airpods())
        let current = r.monitor.listenerEpoch
        #expect(current != old)
        r.fake.kill(OfflineMonitor.airpods().id)                     // the AirPods go away
        r.monitor.deliverPropertyChange(kAudioDevicePropertyDeviceIsAlive, epoch: old)
        #expect(r.monitor.isAttached)
        r.monitor.deliverPropertyChange(kAudioDevicePropertyDeviceIsAlive, epoch: current)
        #expect(!r.monitor.isAttached)
        #expect(r.monitor.stats.lastFailure == "没有默认输出")
        #expect(r.monitor.pendingRetry == nil)                       // the DefaultOutputDevice listener tells
    }

    // MARK: pure helpers

    @Test func streamUsageListsEveryStreamOffAndTheReadBackIsCounted() {
        let proc = UnsafeRawPointer(bitPattern: 0x1234_5678_9ABC)!
        for n in [1, 2, 5] {
            let b = MonitorOutput.streamUsageBytes(proc: proc, streams: n, on: 0)
            #expect(b.count == max(12 + 4 * n, MemoryLayout<AudioHardwareIOProcStreamUsage>.size))
            b.withUnsafeBytes { raw in
                #expect(raw.load(fromByteOffset: 0, as: UInt.self) == 0x1234_5678_9ABC)
                #expect(raw.load(fromByteOffset: 8, as: UInt32.self) == UInt32(n))
                for i in 0..<n { #expect(raw.load(fromByteOffset: 12 + 4 * i, as: UInt32.self) == 0) }
            }
            let on = MonitorOutput.streamUsageBytes(proc: proc, streams: n, on: 1)
            on.withUnsafeBytes { raw in for i in 0..<n { #expect(raw.load(fromByteOffset: 12 + 4 * i, as: UInt32.self) == 1) } }
            #expect(MonitorOutput.streamsOff(b, expected: n) == n)
            #expect(MonitorOutput.streamsOff(on, expected: n) == 0)
            #expect(MonitorOutput.streamsOff(b, expected: n + 1) == 0)   // a read-back listing other streams
        }
        var one = MonitorOutput.streamUsageBytes(proc: proc, streams: 3, on: 0)
        one.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(1), toByteOffset: 16, as: UInt32.self) }
        #expect(MonitorOutput.streamsOff(one, expected: 3) == 2)
        var miscounted = MonitorOutput.streamUsageBytes(proc: proc, streams: 3, on: 0)
        miscounted.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(2), toByteOffset: 8, as: UInt32.self) }
        #expect(MonitorOutput.streamsOff(miscounted, expected: 3) == 0)  // long enough, lists 2 of 3: none trusted
    }

    /// A stream list the HAL does not answer is nil, not "no streams" (a bogus object id).
    @Test func anUnreadableStreamListIsNotEmpty() {
        #expect(MonitorOutput.streams(0xDEAD_BEEF, kAudioObjectPropertyScopeInput) == nil)
        #expect(MonitorOutput.channelsPerBuffer(0xDEAD_BEEF, kAudioObjectPropertyScopeOutput) == nil)
        #expect(throws: MonitorOutput.Failure.self) { try MonitorOutput.describe(0xDEAD_BEEF) }
    }

    @Test func onlyNativeFloat32IsPlayable() {
        var f = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        #expect(MonitorOutput.isPlayableFormat(f))
        f.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        #expect(MonitorOutput.isPlayableFormat(f))
        var g = f; g.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        #expect(!MonitorOutput.isPlayableFormat(g))
        g = f; g.mBitsPerChannel = 64
        #expect(!MonitorOutput.isPlayableFormat(g))
        g = f; g.mFormatFlags |= kAudioFormatFlagIsBigEndian
        #expect(!MonitorOutput.isPlayableFormat(g))
        g = f; g.mFormatID = kAudioFormatAppleLossless
        #expect(!MonitorOutput.isPlayableFormat(g))
    }

    @Test func leadResampleAndFade() throws {
        #expect(MonitorOutput.leadFrames(rate: 48_000, bufferFrames: 512, capacity: 65_536) == 4800)
        #expect(MonitorOutput.leadFrames(rate: 48_000, bufferFrames: 4096, capacity: 65_536) == 9152)
        #expect(MonitorOutput.leadFrames(rate: 48_000, bufferFrames: 4096, capacity: 8192) == 4096)
        let x = [Float](repeating: 0.5, count: 2400)
        let y = try MonitorOutput.resample(x, from: 24_000, to: 48_000)
        #expect(abs(y.count - 4800) <= 32)
        #expect(y[1200..<3600].allSatisfy { abs($0 - 0.5) < 0.005 })
        #expect(try MonitorOutput.resample([2, -3, 0.25], from: 48_000, to: 48_000) == [1, -1, 0.25])
        #expect(MonitorOutput.fadeFrames(rate: 48_000) == 240 && MonitorOutput.fadeFrames(rate: 44_100) == 221)
        let f = MonitorOutput.fadeOut([Float](repeating: 1, count: 240))
        #expect(f[0] > 0.999 && f[239] < 0.001 && f[239] > 0)
        #expect(zip(f, f.dropFirst()).allSatisfy { $0 > $1 })
    }
}
