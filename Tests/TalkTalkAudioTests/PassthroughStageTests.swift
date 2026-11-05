import CAudioCore
import Foundation
import Testing
import TalkTalkCore
@testable import TalkTalkAudio

@Suite struct PassthroughStageTests {
    private func rig() throws -> (PassthroughStage, PassthroughRing, PassthroughGate) {
        let ring = try #require(PassthroughRing(hostTicksPerFrame: FeedOutput.hostTicksPerFrame))
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/PolicyProfile.default.json")
        let p = try PolicyProfile.load(from: url)
        let gate = PassthroughGate(config: .init(profile: p.speak.passthrough), sink: InMemoryPassthroughStateSink())
        gate.updateFacts(at: 0) { $0 = .allGood }
        gate.setMicWarm(true); gate.setCueAudible(false)
        _ = gate.beginHold(pressedAt: 0, armedAt: 400_000_000)
        _ = gate.confirmHold(at: 420_000_000)
        #expect(gate.state.open)
        return (PassthroughStage(ring: ring), ring, gate)
    }

    @Test(arguments: [44_100.0, 48_000.0]) func rateConversionPreservesCaptureAndFixedGain(rate: Double) throws {
        let (stage, ring, gate) = try rig()
        var written = 0
        for i in 0..<4 {
            let at = UInt64(430 + i * 10) * 1_000_000
            _ = gate.confirmHold(at: at)
            written += try stage.offer(.init(origin: .mic, hostTime: at, sampleRate: rate,
                samples: [Float](repeating: 0.1, count: Int(rate / 100))), gate: gate, now: at + 10_000_000, gainDb: 6)
        }
        #expect(abs(written - (1920 - 248)) < 128)
        var result = [Float](repeating: 0, count: 1920), report = tt_ringp_report()
        result.withUnsafeMutableBufferPointer {
            _ = tt_ringp_read(ring.raw, $0.baseAddress!, UInt32($0.count), gate.state.generation,
                HostClock.machTicks(fromNanos: gate.state.openAt), HostClock.machTicks(fromNanos: gate.state.leaseUntil), &report)
        }
        #expect(report.out_of_interval == 0 && report.stale == 0)
        #expect(HostClock.ms(430_000_000, to: HostClock.nanos(fromMachTicks: report.first_src_ticks)) == 0)
        let plateau = result[400..<800]
        #expect(plateau.allSatisfy { abs($0 - 0.1995) < 0.004 })
    }

    @Test func closedGateWritesNothingAndNewGenerationResetsLimiter() throws {
        let (stage, ring, gate) = try rig()
        _ = try stage.offer(.init(origin: .mic, hostTime: 430_000_000, sampleRate: 48_000,
            samples: [Float](repeating: 3, count: 1920)), gate: gate, now: 470_000_000, gainDb: 0)
        var result = [Float](repeating: 0, count: 1920), report = tt_ringp_report()
        result.withUnsafeMutableBufferPointer {
            _ = tt_ringp_read(ring.raw, $0.baseAddress!, UInt32($0.count), gate.state.generation, 0, UInt64.max, &report)
        }
        #expect(result.allSatisfy { abs($0) <= Float(pow(10, -1.0 / 20)) })
        gate.release(at: 480_000_000, reason: .keyReleased)
        let before = ring.writtenFrames
        #expect(try stage.offer(.init(origin: .mic, hostTime: 480_000_000, sampleRate: 48_000,
            samples: [1, 1]), gate: gate, now: 480_000_000, gainDb: 0) == 0)
        #expect(ring.writtenFrames == before)
        _ = gate.beginHold(pressedAt: 500_000_000, armedAt: 900_000_000)
        _ = gate.confirmHold(at: 920_000_000)
        tt_ringp_flush(ring.raw)
        _ = try stage.offer(.init(origin: .mic, hostTime: 930_000_000, sampleRate: 48_000,
            samples: [Float](repeating: 0.1, count: 1920)), gate: gate, now: 970_000_000, gainDb: 0)
        result.withUnsafeMutableBufferPointer {
            _ = tt_ringp_read(ring.raw, $0.baseAddress!, UInt32($0.count), gate.state.generation, 0, UInt64.max, &report)
        }
        #expect(result[400..<800].allSatisfy { abs($0 - 0.1) < 0.001 })
    }
}
