import CAudioCore
import CoreAudio
import Foundation
import Synchronization
import Testing
import TalkTalkCore
@testable import TalkTalkAudio

/// CueTones: the passthrough pair (rising / falling sweep) and MeetingMicGuard's two beeps.
@Suite struct CueTonesTests {
    /// Zero crossings per frame in `x[r]`: a rough instantaneous frequency.
    private func crossings(_ x: [Float], _ r: Range<Int>) -> Int {
        var n = 0
        for i in r.lowerBound + 1 ..< r.upperBound where (x[i - 1] < 0) != (x[i] < 0) { n += 1 }
        return n
    }

    @Test func thePassthroughPairIsThirtyMillisecondsAtTheDeviceRateRisingThenFalling() {
        for rate in [44_100.0, 48_000, 96_000] {
            let up = CueTones.render(.passthroughOpen, sampleRate: rate)
            let down = CueTones.render(.passthroughClose, sampleRate: rate)
            let n = Int((0.03 * rate).rounded())
            #expect(up.count == n && down.count == n, "\(rate)")
            let half = n / 2
            #expect(crossings(up, 0..<half) < crossings(up, half..<n), "\(rate) rising")
            #expect(crossings(down, 0..<half) > crossings(down, half..<n), "\(rate) falling")
        }
    }

    @Test func peakIsTheGivenLevelAndBothEndsAreSilent() {
        for kind in [CueTones.Kind.passthroughOpen, .passthroughClose, .meetingMicAlert] {
            for dbfs in [-45.0, -30, -15] {
                let x = CueTones.render(kind, sampleRate: 48_000, dbfs: dbfs)
                let peak = Double(x.map { abs($0) }.max() ?? 0)
                let want = pow(10, dbfs / 20)
                #expect(peak <= want * (1 + 1e-6) && peak >= want * 0.98, "\(kind) \(dbfs): \(peak)")
                #expect(x.first == 0 && abs(x.last ?? 1) < Float(want) * 1e-3, "\(kind) \(dbfs)")
            }
        }
        // 5 ms raised-cosine fade: nothing near full level in the first and last 2 ms.
        let x = CueTones.render(.passthroughOpen, sampleRate: 48_000)
        let edge = Float(pow(10, -30.0 / 20)) * 0.5
        #expect(x[..<96].allSatisfy { abs($0) < edge } && x[(x.count - 96)...].allSatisfy { abs($0) < edge })
    }

    @Test func theMeetingMicAlertIsTwoBeepsWithAGap() {
        let x = CueTones.render(.meetingMicAlert, sampleRate: 48_000)
        #expect(x.count == 4800)                                     // 40 + 20 + 40 ms
        #expect(x[1920..<2880].allSatisfy { $0 == 0 })
        #expect(x[..<1920].contains { $0 != 0 } && x[2880...].contains { $0 != 0 })
        #expect(Array(x[..<1920]) == Array(x[2880...]))
    }

    @Test func levelsAreClampedAndBadRatesGiveNothing() {
        let peak = { (db: Double) in Double(CueTones.render(.passthroughOpen, sampleRate: 48_000, dbfs: db).map { abs($0) }.max() ?? 0) }
        #expect(peak(-100) <= 0.001 * (1 + 1e-6))
        #expect(peak(0) <= 0.5012 && peak(0) > 0.49)
        #expect(abs(peak(.nan) - peak(-30)) < 1e-9)
        #expect(CueTones.render(.passthroughOpen, sampleRate: 0).isEmpty)
        #expect(CueTones.render(.passthroughOpen, sampleRate: .nan).isEmpty)
    }

    @Test func monitorOutputPlaysTheRenderedCueAtItsRate() async throws {
        let hp = MonitorOutput.Target(id: 41, device: .init(uid: "hp", name: OutputRouteClassifier.externalHeadphonesName, transport: .builtIn),
                                      sampleRate: 44_100, inputStreams: 0)
        let hal = MonitorOutput.HAL(realIO: false, defaultOutput: { 41 }, describe: { _ in hp }, isAlive: { _ in true },
                                    turnOffInputStreams: { _, _, n in n }, bufferFrames: { _ in 512 })
        let m = MonitorOutput(ringO2: try #require(RingO()), events: try #require(EventRing()), hal: hal)
        #expect(await m.playCue(.passthroughOpen) == false)          // no .cues use
        m.setUse(.cues, true)
        let played = Mutex<Bool?>(nil)
        m.playCue(.passthroughOpen, dbfs: -20) { ok in played.withLock { $0 = ok } }   // returns at once
        let end = Date().addingTimeInterval(20)
        while played.withLock({ $0 }) == nil, Date() < end { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(played.withLock { $0 } == true)
        let want = CueTones.render(.passthroughOpen, sampleRate: 44_100, dbfs: -20)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        var out = [Float](repeating: 9, count: want.count)
        out.withUnsafeMutableBufferPointer { b in
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(b.count * 4), mData: b.baseAddress)
            m.processOffline(list.unsafeMutablePointer, frames: UInt32(b.count))
        }
        #expect(out == want)
    }
}
