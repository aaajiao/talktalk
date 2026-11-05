import Foundation
import TalkTalkAudio
import TalkTalkCore
import TalkTalkDriverSupport
import TalkTalkEngineHost

/// Exclusive CLI self-test: synthetic pulses → real gate/stage/ringP/feedIOProc → channel 2 → Test Mic.
func passthroughSelfTest() async -> SelfTestReport {
    var report = SelfTestReport(suite: "passthrough")
    guard Bundle.main.bundleIdentifier != nil, SingleInstance.acquire(requireLock: true) else {
        report.checks.append(.init("passthrough.exclusive", ok: nil, detail: "skipped: quit the running app of this build and launch the bundled self-test")); return report
    }
    let hal = CoreAudioDriverHAL()
    guard hal.meetingMode() == false, hal.device(uid: DriverIdentity.feedUID)?.isRunningSomewhere == false else {
        report.checks.append(.init("passthrough.exclusive", ok: nil, detail: "skipped: another TalkTalk meeting or Feed owner is active, or driver state is unknown")); return report
    }
    guard MicrophoneAuthorization.current == .authorized else {
        report.checks.append(.init("passthrough.permission", ok: nil, detail: "skipped: Test Mic needs the app's microphone grant")); return report
    }
    do {
        let profile = try PolicyProfile.loadDefault()
        guard let ring = RingO(), let events = EventRing() else { throw PulseFailure.allocation }
        let feed = try FeedOutput(ringO: ring, events: events)
        let stage = PassthroughStage(feed: feed)
        let gate = PassthroughGate(config: .init(profile: profile.speak.passthrough), sink: feed.passthroughState)
        gate.setSource(.selfTest, at: HostClock.now())
        let recorder = try DriverTestMicRecorder()
        try recorder.start(hal: hal)
        defer { feed.detach(); _ = recorder.stopAndRead() }
        try feed.attach { _ in }
        try await Task.sleep(for: .milliseconds(100))
        let opened = HostClock.now()
        guard gate.openSelfTest(at: opened, durationMs: 1000) else { throw PulseFailure.open }
        var cursor = opened > 20_000_000 ? opened - 20_000_000 : 0
        func offerUntil(_ now: HostTime) throws {
            while cursor + 10_000_000 <= now {
                let samples = (0..<480).map { i -> Float in i % 96 < 48 ? 0.2 : -0.2 }
                _ = try stage.offer(.init(origin: .selfTest, hostTime: cursor, sampleRate: 48_000, samples: samples),
                                    gate: gate, now: now, gainDb: 0)
                cursor += 10_000_000
            }
        }
        while HostClock.ms(opened, to: HostClock.now()) < 350 { try offerUntil(HostClock.now()); try await Task.sleep(for: .milliseconds(5)) }
        let closed = HostClock.now()
        gate.systemEvent(.meetingModeEnded, at: closed)
        try await Task.sleep(for: .milliseconds(150))
        let second = HostClock.now()
        guard gate.openSelfTest(at: second, durationMs: 300) else { throw PulseFailure.open }
        cursor = second
        while HostClock.ms(second, to: HostClock.now()) < 200 { try offerUntil(HostClock.now()); try await Task.sleep(for: .milliseconds(5)) }
        // No gate/worker calls at expiry: the IOProc must enforce the lease by itself.
        try await Task.sleep(for: .milliseconds(250))
        let stats = feed.stats
        feed.detach()
        let recording = recorder.stopAndRead()
        let first = recording.samples.first { abs($0.value) > 0.0001 }
        let closeQuiet = recording.samples.filter { $0.host >= closed + 40_000_000 && $0.host < second }
        let leaseEnd = second + 300_000_000
        let leaseQuiet = recording.samples.filter { $0.host >= leaseEnd + 40_000_000 }
        let secondHeard = recording.samples.contains { $0.host >= second && $0.host < leaseEnd && abs($0.value) > 0.0001 }
        report.checks.append(.init("passthrough.firstSample", ok: first.map { $0.host >= opened } ?? false,
                                  values: ["openToFirstMs": first.map { Double(HostClock.ms(opened, to: $0.host)) } ?? -1]))
        report.checks.append(.init("passthrough.closeZeros", ok: !closeQuiet.isEmpty && closeQuiet.allSatisfy { abs($0.value) < 0.0001 }))
        report.checks.append(.init("passthrough.leaseZeros", ok: secondHeard && stats.ptLeaseExpiries > 0 && !leaseQuiet.isEmpty && leaseQuiet.allSatisfy { abs($0.value) < 0.0001 },
                                  values: ["leaseExpiries": Double(stats.ptLeaseExpiries)]))
        report.checks.append(.init("passthrough.sourceIsolation", ok: stats.mixedCycles == 0 && stats.ringOAudioFrames == 0 && stats.ringPAudioFrames > 0,
                                  detail: "synthetic source uses channel 2; ringO remains empty",
                                  values: ["mixedCycles": Double(stats.mixedCycles), "ringOFrames": Double(stats.ringOAudioFrames), "ringPFrames": Double(stats.ringPAudioFrames)]))
        report.checks.append(.init("passthrough.capture", ok: recording.callbacks > 0 && recording.overflows == 0,
                                  values: ["callbacks": Double(recording.callbacks), "overflows": Double(recording.overflows)]))
    } catch { report.checks.append(.init("passthrough.run", ok: false, detail: String(describing: type(of: error)))) }
    return report
}
private enum PulseFailure: Error { case allocation, open }
