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
    @Test func faintMarksLibfvadVoiceJustUnderTheEnergyThreshold() throws {
        let frame = { (value: Float) in Array(repeating: value, count: 320) }
        let vad = SpeakVAD(classify: { _ in true })
        var now: HostTime = 1_000_000_000
        func push(_ value: Float) -> SpeakVAD.Result { defer { now += 20_000_000 }; return vad.push(frame(value), at: now) }
        for _ in 0..<150 { _ = push(0.001) }   // -60 dBFS: the threshold becomes -48
        // -52 dBFS is faint, never voiced: four in a row raise no onset and move no voice end.
        for _ in 0..<4 {
            let faint = push(0.0025)
            #expect(faint.frames.map(\.faint) == [true] && faint.frames.map(\.voiced) == [false] && faint.events.isEmpty)
        }
        #expect(abs(vad.thresholdDb - (-48)) < 0.01 && !vad.speechActive && vad.lastVoiceEnd == nil)
        #expect(push(0.005).frames.map { [$0.voiced, $0.faint] } == [[true, false]])    // -46 dBFS
        #expect(push(0.0015).frames.map { [$0.voiced, $0.faint] } == [[false, false]])  // -56.5 dBFS
        // Without libfvad voice the same energy is neither.
        let noise = SpeakVAD(classify: { _ in false })
        for i in 0..<150 { _ = noise.push(frame(0.001), at: UInt64(i) * 20_000_000) }
        #expect(noise.push(frame(0.0025), at: 3_000_000_000).frames.map { [$0.voiced, $0.faint] } == [[false, false]])
    }
    /// The warm-up threshold is a fixed -55 dBFS, so faint also needs 6 dB over the 10th-percentile level
    /// seen so far: steady noise libfvad calls voice from the first frame on is not faint at the start of
    /// a cold press. Once warm, that level is sorted[14], the one thresholdDb uses.
    @Test func warmUpFaintNeedsAMarginOverTheQuietestLevels() throws {
        var now: HostTime = 1_000_000_000
        func push(_ vad: SpeakVAD, _ value: Float, _ count: Int) -> [SpeakVAD.Frame] {
            (0..<count).flatMap { _ in defer { now += 20_000_000 }; return vad.push(Array(repeating: value, count: 320), at: now).frames }
        }
        // -58 dBFS noise lies in [-61, -55) but not 6 dB above its own level.
        #expect(push(SpeakVAD(classify: { _ in true }), 0.00126, 40).allSatisfy { !$0.faint && !$0.voiced })
        // After a -63 dBFS room, -56.5 dBFS soft speech is faint, not voiced.
        let vad = SpeakVAD(classify: { _ in true })
        _ = push(vad, 0.000708, 40)
        #expect(push(vad, 0.0015, 5).allSatisfy { $0.faint && !$0.voiced })
        // None in the first 10 frames after a reset: the 10th sees nine levels, the 11th ten.
        vad.reset(); _ = push(vad, 0.000708, 9)
        #expect(push(vad, 0.0015, 2).map(\.faint) == [false, true])
        // Warm with 15 frames at -80 dBFS and 135 at -62: the threshold is -55 and -58 dBFS is faint
        // (the 16th-quietest level, -62, would leave it out).
        let warm = SpeakVAD(classify: { _ in true })
        _ = push(warm, 0.0001, 15); _ = push(warm, 0.000794, 135)
        #expect(push(warm, 0.00126, 1).map(\.faint) == [true] && abs(warm.thresholdDb - (-55)) < 0.01)
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

    /// Device enumeration runs on the queue that delivers mic chunks, so an open capture is
    /// re-checked only on a device notification, never on each setHot or cadence change.
    @Test func openCaptureEnumeratesDevicesOnlyOnADeviceNotification() async throws {
        let rig = FakeMicRig(), lookups = Mutex(0)
        let mic = try MicIngest(profile: profile, onBlock: { rig.block($0) },
                                devices: { lookups.withLock { $0 += 1 }; return rig.devices },
                                makeCapture: { rig.make($0) }, watchHAL: false)
        defer { mic.stop() }
        mic.setHot(true)
        #expect(await eventuallyMic { mic.state.capture == .open })
        let capture = try #require(rig.latest)
        let opened = lookups.withLock { $0 }
        for _ in 0..<20 { mic.setHot(true) }
        mic.setPassthroughCadence(true)
        capture.feed(at: 1_000_000_000, frame: 0)   // delivered after the calls above
        #expect(await eventuallyMic { rig.blockCount == 1 })
        #expect(lookups.withLock { $0 } == opened)
        mic.refreshDevices()
        #expect(await eventuallyMic { lookups.withLock { $0 } == opened + 1 })
        #expect(rig.latest === capture)   // the same device stays open
        #expect(mic.stats.chunkFramesMin == 320 && mic.stats.chunkFramesMax == 320)
    }

    /// Each capture's figures are reported as it closes, on the mic queue: the session log
    /// closes before SpeakController.end() runs, so a record written there was lost.
    @Test func eachClosingCaptureReportsItsChunkSizes() async throws {
        let rig = FakeMicRig(), ends = Mutex<[MicIngest.Stats]>([])
        let mic = try MicIngest(profile: profile, onBlock: { rig.block($0) },
                                onCaptureEnd: { stats in ends.withLock { $0.append(stats) } },
                                devices: { rig.devices }, makeCapture: { rig.make($0) }, watchHAL: false)
        defer { mic.stop() }
        mic.setHot(true)
        #expect(await eventuallyMic { mic.state.capture == .open })
        let first = try #require(rig.latest)
        first.feed(at: 1_000_000_000, frame: 0)
        #expect(await eventuallyMic { rig.blockCount == 1 })
        #expect(ends.withLock { $0.isEmpty })
        mic.setHot(false)
        #expect(await eventuallyMic { mic.state.capture == .closed && ends.withLock { $0.count } == 1 })
        #expect(ends.withLock { $0[0].chunkFramesMin == 320 && $0[0].chunkFramesMax == 320 && $0[0].blocks == 1 })
        // A capture that fails to start ends with no chunk sizes, not the previous one's.
        rig.failStarts(true)
        mic.setHot(true)
        #expect(await eventuallyMic { mic.state.capture == .noDevice && ends.withLock { $0.count } == 2 })
        #expect(ends.withLock { $0[1].chunkFramesMin == 0 && $0[1].chunkFramesMax == 0 && $0[1].blocks == 1 })
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
        // 2 s of speech, a 160 ms pause, more speech: the cut lands in the pause, never on a voiced frame.
        for i in 0..<140 {
            capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: i < 100 || i >= 108 ? 0.1 : 0)
        }
        #expect(await eventuallyMic { !clips.withLock { $0.isEmpty } })
        let clip = try #require(clips.withLock { $0.first })
        #expect(!clip.isFinal && clip.pcm.start >= start - 300_000_000 && clip.cutDetail == .clauseDip)
        #expect(clip.speechLastMs == 2_000 && clip.pcm.end == start + 2_080_000_000 && clip.previewsIgnored == 0)
        press.cancel(); mic.stop(); await reader.value
    }

    /// A cold press reopens the capture, which erases the pre-roll a closed capture left behind.
    /// The segmenter and preview must start at the new capture, or they count, time from and cut
    /// on audio no clip can carry, and the preview shows its words. Host times start at the real
    /// clock, so the idle eraser (ring audio over 1 s old) keeps the warm audio until the press; on a
    /// machine too slow for that the preview check passes without testing anything. Each VAD instance
    /// sees fewer than 150 frames (no threshold adaptation).
    @Test(arguments: [false, true]) func coldPressIgnoresPrerollTheReopenErases(longOpen: Bool) async throws {
        let rig = FakeMicRig(), clips = Mutex<[SpeakClip]>([]), previews = Mutex<[HostTime]>([])
        let mic = try MicIngest(profile: profile, devices: { rig.devices }, makeCapture: { rig.make($0) },
                                watchHAL: false, vad: SpeakVAD(classify: { _ in true }))
        defer { mic.stop() }
        let preroll: HostTime = 300_000_000, start = HostClock.now() + preroll
        mic.setHot(true)
        #expect(await eventuallyMic { mic.state.capture == .open })
        let warm = try #require(rig.latest)
        for i in 0..<15 { warm.feed(at: start - preroll + UInt64(i) * 20_000_000, frame: UInt64(i * 320)) }
        #expect(await eventuallyMic { mic.stats.frames16k == 4800 })
        mic.setHot(false)   // VAD history still holds the 300 ms of speech.
        #expect(await eventuallyMic { mic.state.capture == .closed })
        let press = try #require(mic.beginPress(id: 1, keyDownAt: start, passthroughClosedAt: nil))
        let viewer = Task { for await frame in press.preview { previews.withLock { $0.append(frame.at) } } }
        #expect(await eventuallyMic { rig.latest.map { $0 !== warm } ?? false })
        let fresh = try #require(rig.latest)
        let reader = Task { for await clip in press.clips { clips.withLock { $0.append(clip) } } }
        let first = start + (longOpen ? 4_600_000_000 : 200_000_000)
        // Invented text standing for the pre-roll's words.
        press.updatePreview(stableText: "明天", through: start, at: start, isFinal: false,
                            boundary: .init(from: start - preroll, fullyStable: false))
        for i in 0..<120 {
            if i == 50 {   // What the pipeline sends while its preview floor has not moved.
                // Drained so far, so the 100-frame preview buffer drops none.
                #expect(await eventuallyMic { previews.withLock { $0.count } >= 50 })
                press.updatePreview(stableText: "后来我们", through: first + 900_000_000, at: first + 1_000_000_000,
                                    isFinal: false, boundary: .init(from: start - preroll, fullyStable: false))
            }
            fresh.feed(at: first + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: i < 100 ? 0.1 : 0)
        }
        #expect(await eventuallyMic { mic.stats.frames16k == 4800 + 120 * 320 && !clips.withLock { $0.isEmpty } })
        press.cancel(); await reader.value; await viewer.value
        let captured = clips.withLock { $0 }, shown = previews.withLock { $0 }
        let clip = try #require(captured.first)
        #expect(captured.count == 1 && clip.index == 0 && clip.cutDetail == .silence)
        #expect(clip.pcm.start == first && clip.pcm.end == first + 2_180_000_000)
        #expect(clip.speechMs == 2000 && clip.previewsIgnored == 0 && clip.previewCjk == 4)
        #expect(shown.first == first && shown.allSatisfy { $0 >= first })
    }

    /// Soft speech in the faint band (libfvad voice at -58.4 dBFS, under the -55 dBFS threshold) before
    /// the first voiced frame reaches the clip, unless the controller does not trust faint frames.
    @Test(arguments: [true, false]) func faintLeadReachesTheClip(trustsFaint: Bool) async throws {
        let rig = FakeMicRig(), clips = Mutex<[SpeakClip]>([])
        let mic = try MicIngest(profile: profile, trustsFaint: { trustsFaint }, devices: { rig.devices },
                                makeCapture: { rig.make($0) }, watchHAL: false, vad: SpeakVAD(classify: { _ in true }))
        defer { mic.stop() }
        let start: HostTime = 1_000_000_000
        let press = try #require(mic.beginPress(id: 1, keyDownAt: start, passthroughClosedAt: start))
        #expect(await eventuallyMic { rig.latest != nil })
        let reader = Task { for await clip in press.clips { clips.withLock { $0.append(clip) } } }
        let capture = try #require(rig.latest)
        for i in 0..<230 {
            let value: Float = (30..<90).contains(i) ? 0.0012 : (105..<205).contains(i) ? 0.1 : 0
            capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: value)
        }
        #expect(await eventuallyMic { !clips.withLock { $0.isEmpty } })
        press.cancel(); await reader.value
        let captured = clips.withLock { $0 }
        let clip = try #require(captured.first)
        #expect(captured.count == 1 && clip.cutDetail == .silence && clip.pcm.end == start + 4_280_000_000)
        if trustsFaint {
            #expect(clip.pcm.start == start + 300_000_000 && clip.speechFirstMs == 1800 && clip.speechLastMs == 3800)
            #expect(clip.faintLeadMs == 1200 && clip.faintTrimmedMs == 0 && clip.faintCutMs == 0)
        } else {
            // The 1 s rule: the faint audio before it is counted as left out.
            #expect(clip.pcm.start == start + 1_100_000_000 && clip.speechFirstMs == 1000)
            #expect(clip.faintLeadMs == 700 && clip.faintTrimmedMs == 500)
        }
    }

    /// Faint frames (libfvad voice at -56.5 dBFS, under the -55 dBFS threshold) reach the segmenter: the
    /// textSilence cut waits for quiet after them, and a faint-only remainder dropped at key-up is counted.
    /// The press opens with 200 ms of quiet, so the 10th-percentile level is the room's, not the speech's.
    @Test func faintReachesTheTextSilenceCutAndTheStats() async throws {
        let rig = FakeMicRig(), clips = Mutex<[SpeakClip]>([])
        let mic = try MicIngest(profile: profile, devices: { rig.devices }, makeCapture: { rig.make($0) },
                                watchHAL: false, vad: SpeakVAD(classify: { _ in true }))
        defer { mic.stop() }
        let start: HostTime = 1_000_000_000
        let press = try #require(mic.beginPress(id: 1, keyDownAt: start, passthroughClosedAt: start))
        #expect(await eventuallyMic { rig.latest != nil })
        let reader = Task { for await clip in press.clips { clips.withLock { $0.append(clip) } } }
        let capture = try #require(rig.latest)
        let feed = { (frames: Range<Int>) in
            for i in frames {
                let value: Float = (10..<45).contains(i) ? 0.1 : (45..<70).contains(i) || (90..<105).contains(i) ? 0.0015 : 0
                capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: value)
            }
        }
        feed(0..<46)
        #expect(await eventuallyMic { mic.stats.frames16k == 14_720 })
        press.updatePreview(stableText: "明天下午三点开会吧", through: start + 900_000_000, at: start + 920_000_000,
                            isFinal: false, boundary: .init(from: start, fullyStable: true))
        feed(46..<105)
        #expect(await eventuallyMic { mic.stats.frames16k == 33_600 })
        press.release(at: start + 2_100_000_000, reason: .keyUp)
        feed(105..<120)
        await reader.value
        let captured = clips.withLock { $0 }
        let clip = try #require(captured.first)
        #expect(captured.count == 1 && clip.cutDetail == .textSilence && clip.pcm.end == start + 1_580_000_000)
        #expect(clip.speechMs == 700 && clip.faintTailMs == 500 && clip.faintHeldMs == 500)
        #expect(mic.stats.faintOnlyDropped == 1)
    }

    /// Speech resuming while faint frames hold the textSilence cut: the release clip holds both clauses
    /// and is marked merged (the mark passes through MicIngest to the clip).
    @Test func faintHoldMergeReachesTheClip() async throws {
        let rig = FakeMicRig(), clips = Mutex<[SpeakClip]>([])
        let mic = try MicIngest(profile: profile, devices: { rig.devices }, makeCapture: { rig.make($0) },
                                watchHAL: false, vad: SpeakVAD(classify: { _ in true }))
        defer { mic.stop() }
        let start: HostTime = 1_000_000_000
        let press = try #require(mic.beginPress(id: 1, keyDownAt: start, passthroughClosedAt: start))
        #expect(await eventuallyMic { rig.latest != nil })
        let reader = Task { for await clip in press.clips { clips.withLock { $0.append(clip) } } }
        let capture = try #require(rig.latest)
        let feed = { (frames: Range<Int>) in
            for i in frames {
                let value: Float = (10..<45).contains(i) || (75..<90).contains(i) ? 0.1 : (45..<70).contains(i) ? 0.0015 : 0
                capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: value)
            }
        }
        feed(0..<46)
        #expect(await eventuallyMic { mic.stats.frames16k == 14_720 })
        press.updatePreview(stableText: "明天下午三点开会吧", through: start + 900_000_000, at: start + 920_000_000,
                            isFinal: false, boundary: .init(from: start, fullyStable: true))
        feed(46..<105)
        #expect(await eventuallyMic { mic.stats.frames16k == 33_600 })
        press.release(at: start + 2_100_000_000, reason: .keyUp)
        feed(105..<120)
        await reader.value
        let captured = clips.withLock { $0 }
        let clip = try #require(captured.first)
        #expect(captured.count == 1 && clip.cutDetail == .release && clip.speechMs == 1000)
        #expect(clip.faintHeldMs == 840 && clip.faintHeldMerged)
        #expect(mic.stats.faintOnlyDropped == 0)
    }

    /// The cap-restart marks reach the clip: an 80 ms blip, then a phrase voiced across the 4.5 s cap
    /// (4.40-6.00 s); the cut moves back to 3.40 s and the blip is dropped.
    @Test func capRestartDiagnosticsReachTheClip() async throws {
        let rig = FakeMicRig(), clips = Mutex<[SpeakClip]>([])
        let mic = try MicIngest(profile: profile, devices: { rig.devices }, makeCapture: { rig.make($0) },
                                watchHAL: false, vad: SpeakVAD(classify: { _ in true }))
        defer { mic.stop() }
        let start: HostTime = 1_000_000_000
        let press = try #require(mic.beginPress(id: 1, keyDownAt: start, passthroughClosedAt: start))
        #expect(await eventuallyMic { rig.latest != nil })
        let reader = Task { for await clip in press.clips { clips.withLock { $0.append(clip) } } }
        let capture = try #require(rig.latest)
        let feed = { (frames: Range<Int>) in
            for i in frames {
                let value: Float = (20..<24).contains(i) || (220..<300).contains(i) ? 0.1 : 0
                capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: value)
            }
        }
        feed(0..<330)
        #expect(await eventuallyMic { mic.stats.frames16k == 330 * 320 })
        press.release(at: start + 6_600_000_000, reason: .keyUp)
        feed(330..<345)
        await reader.value
        let captured = clips.withLock { $0 }
        let clip = try #require(captured.first)
        #expect(captured.count == 1 && clip.cutDetail == .release && clip.pcm.start == start + 3_400_000_000)
        #expect(clip.speechMs == 1600 && clip.droppedSpeechMs == 80 && clip.capRestart)
    }

    @Test func completeShortReplyEvidenceReachesMicAndKeepsFullPCM() async throws {
        let rig = FakeMicRig(), clips = Mutex<[SpeakClip]>([])
        let mic = try MicIngest(profile: profile, devices: { rig.devices }, makeCapture: { rig.make($0) },
                                watchHAL: false, vad: SpeakVAD(classify: { _ in true }))
        let start: HostTime = 1_000_000_000
        let press: any SpeakPressAudio = try #require(mic.beginPress(id: 1, keyDownAt: start, passthroughClosedAt: start))
        #expect(await eventuallyMic { rig.latest != nil })
        let reader = Task { for await clip in press.clips { clips.withLock { $0.append(clip) } } }
        let capture = try #require(rig.latest)
        for i in 0..<40 { capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320)) }
        #expect(await eventuallyMic { mic.stats.frames16k == 12_800 })
        press.updatePreview(stableText: "谢谢。", through: start + 800_000_000,
                            at: start + 800_000_000, isFinal: false,
                            boundary: .init(from: start, fullyStable: true))
        for i in 40..<70 { capture.feed(at: start + UInt64(i) * 20_000_000, frame: UInt64(i * 320), value: 0) }
        #expect(await eventuallyMic { clips.withLock { !$0.isEmpty } })
        press.cancel(); mic.stop(); await reader.value
        let captured = clips.withLock { $0 }
        let clip = try #require(captured.first)
        #expect(captured.count == 1 && clip.cutReason == .shortReply && !clip.isFinal)
        #expect(clip.cutDetail == .shortReply && clip.speechFirstMs == 0 && clip.speechLastMs == 800)
        #expect(clip.pcm.start == start && clip.pcm.end >= start + 1_050_000_000)
        #expect(clip.pcm.samples.prefix(12_800).allSatisfy { abs($0 - 0.1) < 0.0001 })
        #expect(clip.pcm.samples.dropFirst(12_800).allSatisfy { $0 == 0 })
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
    private var failStarts = false
    var finished: Bool { lock.withLock { didFinish } }
    func markFinished() { lock.withLock { didFinish = true } }
    var devices: [InputDeviceInfo] { lock.withLock { [.init(objectID: 9, uid: uid, name: "Microphone", transport: "bltn", nominalSampleRate: rate, inputChannels: 1, isAlive: true, isAggregate: false)] } }
    /// The newest capture once MicIngest has started it. make() runs before start() installs the
    /// chunk callback; a test that fed chunks in between lost them (a flake under parallel load).
    var latest: FakeSpeakCapture? { lock.withLock { capture }.flatMap { $0.isStarted ? $0 : nil } }
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
            let next = FakeSpeakCapture(device, failsToStart: failStarts); capture = next; createdAfter.append(systemEvents.last); return next
        }
    }
    /// Captures made from now on throw from start().
    func failStarts(_ on: Bool) { lock.withLock { failStarts = on } }
}
private final class FakeSpeakCapture: SpeakCapture, @unchecked Sendable {
    let device: InputDeviceInfo
    var sampleRate: Double { device.nominalSampleRate }
    private let lock = NSLock()
    private var chunk: (@Sendable (MicCapture.Chunk) -> Void)?
    private var interruption: (@Sendable (MicCapture.Interruption) -> Void)?
    private let failsToStart: Bool
    private struct StartFailure: Error {}
    init(_ device: InputDeviceInfo, failsToStart: Bool = false) { self.device = device; self.failsToStart = failsToStart }
    var isStarted: Bool { lock.withLock { chunk != nil } }
    func start(onChunk: @escaping @Sendable (MicCapture.Chunk) -> Void, onInterruption: @escaping @Sendable (MicCapture.Interruption) -> Void) throws {
        if failsToStart { throw StartFailure() }
        lock.withLock { chunk = onChunk; interruption = onInterruption }
    }
    func stop() { lock.withLock { chunk = nil; interruption = nil } }
    func setDrainCadence(milliseconds: Int) {}
    func feed(at: HostTime, frame: UInt64, count: Int = 320, value: Float = 0.1) { lock.withLock { chunk }?(.init(samples: Array(repeating: value, count: count), startFrame: frame, hostTime: at)) }
    func interrupt(_ event: MicCapture.Interruption) { lock.withLock { interruption }?(event) }
}
