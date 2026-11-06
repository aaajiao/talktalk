import CAudioCore
import CoreAudio
import Foundation
import Testing
@testable import TalkTalkAudio

@Suite struct TapIOProcTests {
    private func withBufferList(_ buffers: [(UInt32, [Float])], _ body: (UnsafePointer<AudioBufferList>) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        var storages: [UnsafeMutablePointer<Float>] = []
        for (i, (ch, samples)) in buffers.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            p.initialize(from: samples, count: samples.count)
            storages.append(p)
            list[i] = AudioBuffer(mNumberChannels: ch, mDataByteSize: UInt32(samples.count * 4), mData: p)
        }
        body(UnsafePointer(list.unsafePointer))
        storages.forEach { $0.deallocate() }
    }

    private func drain(_ r: OpaquePointer, _ n: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: n)
        let got = out.withUnsafeMutableBufferPointer { tt_ring_read(r, $0.baseAddress!, UInt32(n)) }
        return Array(out[0..<Int(got)])
    }

    @Test func stereoInterleavedSplitsIntoTwoRingsWithStamps() throws {
        let l = try #require(tt_ring_create(1024)), r = try #require(tt_ring_create(1024))
        let ctx = try #require(tt_tap_ctx_create(l, r))
        defer { tt_tap_ctx_destroy(ctx); tt_ring_destroy(l); tt_ring_destroy(r) }
        var inter = [Float]()
        for i in 0..<4 { inter += [Float(i), Float(10 + i)] }
        withBufferList([(2, inter)]) { tt_tap_process(ctx, $0, 4, 777) }
        #expect(drain(l, 8) == [0, 1, 2, 3])
        #expect(drain(r, 8) == [10, 11, 12, 13])
        var stamps = [tt_tap_stamp](repeating: tt_tap_stamp(), count: 4)
        let n = stamps.withUnsafeMutableBufferPointer { tt_tap_read_stamps(ctx, $0.baseAddress!, 4) }
        #expect(n == 1)
        #expect(stamps[0].host_time == 777 && stamps[0].frames == 4 && stamps[0].nonzero == 1)
        #expect(tt_tap_last_nonzero_host_time(ctx) == 777)
    }

    @Test func exactZerosDoNotUpdateTheNonZeroTime() throws {
        let l = try #require(tt_ring_create(1024)), r = try #require(tt_ring_create(1024))
        let ctx = try #require(tt_tap_ctx_create(l, r))
        defer { tt_tap_ctx_destroy(ctx); tt_ring_destroy(l); tt_ring_destroy(r) }
        withBufferList([(1, [0.5, 0]), (1, [0, 0])]) { tt_tap_process(ctx, $0, 2, 100) }
        withBufferList([(1, [0, 0]), (1, [0, 0])]) { tt_tap_process(ctx, $0, 2, 200) }
        #expect(tt_tap_last_nonzero_host_time(ctx) == 100)
        #expect(drain(l, 8) == [0.5, 0, 0, 0])
    }

    @Test func monoTapIsDuplicated() throws {
        let l = try #require(tt_ring_create(1024)), r = try #require(tt_ring_create(1024))
        let ctx = try #require(tt_tap_ctx_create(l, r))
        defer { tt_tap_ctx_destroy(ctx); tt_ring_destroy(l); tt_ring_destroy(r) }
        withBufferList([(1, [1, 2, 3])]) { tt_tap_process(ctx, $0, 3, 1) }
        #expect(drain(l, 8) == [1, 2, 3])
        #expect(drain(r, 8) == [1, 2, 3])
    }

    @Test func stampRingDropsWhenTheWorkerFallsBehind() throws {
        let l = try #require(tt_ring_create(1 << 16)), r = try #require(tt_ring_create(1 << 16))
        let ctx = try #require(tt_tap_ctx_create(l, r))
        defer { tt_tap_ctx_destroy(ctx); tt_ring_destroy(l); tt_ring_destroy(r) }
        for i in 0..<(Int(TT_TAP_STAMPS) + 5) { withBufferList([(2, [0, 0])]) { tt_tap_process(ctx, $0, 1, UInt64(i + 1)) } }
        #expect(tt_tap_dropped_stamps(ctx) == 5)
    }
}

@Suite struct MeetingSourceResolverTests {
    /// pid → (parent, bundle id); 1 = launchd.
    static let table: [pid_t: (pid_t, String?)] = [
        100: (1, "us.zoom.xos"),
        101: (100, nil),                                // Zoom's caphost, no bundle id
        200: (1, "com.google.Chrome"),
        201: (200, "com.google.Chrome.helper"),
        300: (1, "com.apple.WebKit.GPU"),               // XPC: responsible is 400
        400: (1, "com.readread.app"),
        500: (1, "com.apple.WebKit.GPU"),               // XPC with no responsible process known
        600: (1, "com.tencent.meeting"),
        700: (1, "com.apple.mobilephone"),
        701: (700, nil),                              // Phone's child with no bundle id
        702: (1, "com.apple.avconferenced"),           // XPC explicitly owned by Phone
        800: (1, "com.apple.FaceTime"),
        900: (1, "com.apple.TelephonyUtilities"),
        901: (1, "com.apple.avconferenced"),           // Shared service with no known owner
    ]
    static let responsible: [pid_t: pid_t] = [300: 400, 702: 700]

    let resolver = MeetingSourceResolver(lookup: .init(
        parentPID: { table[$0]?.0 }, bundleID: { table[$0]?.1 }, responsiblePID: { responsible[$0] }))

    func proc(_ id: UInt32, _ pid: pid_t, _ bundle: String?, input: Bool = false, output: Bool = true) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: pid, bundleID: bundle, isRunningInput: input, isRunningOutput: output)
    }

    @Test func bundlePrefixAndParentChain() {
        #expect(resolver.ownerBundleID(proc(1, 201, "com.google.Chrome.helper")) == "com.google.Chrome")
        #expect(resolver.ownerBundleID(proc(2, 101, nil)) == "us.zoom.xos")
    }

    @Test func phoneIsAKnownSourceWithItsOwnApplicationIdentity() {
        #expect(MeetingApp.named("com.apple.mobilephone")?.name == "Phone")
        #expect(resolver.ownerBundleID(proc(20, 700, "com.apple.mobilephone")) == "com.apple.mobilephone")
    }

    @Test func phoneRuntimeIdentityOverridesLegacyFaceTimeAudioIdentity() {
        #expect(resolver.ownerBundleID(proc(20, 700, "com.apple.FaceTime")) == "com.apple.mobilephone")
        #expect(resolver.ownerBundleID(proc(22, 800, "com.apple.FaceTime")) == "com.apple.FaceTime")
    }

    @Test func phoneHelpersFollowTheirVerifiedParentOrResponsibleProcess() {
        #expect(resolver.ownerBundleID(proc(21, 701, nil)) == "com.apple.mobilephone")
        #expect(resolver.ownerBundleID(proc(23, 702, "com.apple.avconferenced")) == "com.apple.mobilephone")
    }

    @Test func phoneAndFaceTimeRemainDistinctCandidates() throws {
        let c = resolver.candidates([
            proc(20, 700, "com.apple.FaceTime", input: true, output: false),
            proc(21, 701, nil),
            proc(22, 800, "com.apple.FaceTime"),
        ])
        #expect(c.count == 2)
        let phone = try #require(c.first { $0.app.id == "com.apple.mobilephone" })
        let faceTime = try #require(c.first { $0.app.id == "com.apple.FaceTime" })
        #expect(phone.app.name == "Phone")
        #expect(phone.objectIDs == [20, 21])
        #expect(phone.isRunningInput && phone.isRunningOutput)
        #expect(faceTime.app.name == "FaceTime")
        #expect(faceTime.objectIDs == [22])
        #expect(MeetingSourceResolver.defaultSource(c)?.app.id == phone.app.id)
        #expect(MeetingSourceResolver.defaultSource(c, preferred: faceTime.app.id)?.app.id == phone.app.id)
    }

    @Test func sharedCallServicesAreNotAssignedToAnOpenPhoneWithoutAnOwner() throws {
        let c = resolver.candidates([
            proc(20, 700, "com.apple.mobilephone", output: false),
            proc(24, 900, "com.apple.TelephonyUtilities", input: true),
            proc(25, 901, "com.apple.avconferenced", input: true),
        ])
        #expect(c.count == 1)
        let phone = try #require(c.first)
        #expect(phone.app.id == "com.apple.mobilephone")
        #expect(phone.objectIDs == [20])
        #expect(!phone.isRunningInput && !phone.isRunningOutput)
        #expect(MeetingSourceResolver.defaultSource(c) == nil)
    }

    @Test func audioIdentityRemainsTheFallbackWithoutARuntimeApplication() {
        #expect(resolver.ownerBundleID(proc(26, 999, "com.apple.mobilephone")) == "com.apple.mobilephone")
        #expect(resolver.ownerBundleID(proc(27, 999, "com.apple.FaceTime")) == "com.apple.FaceTime")
    }

    /// A WKWebView app's audio must not count as Safari's (here: readread's WebKit process).
    @Test func xpcServicesBelongToTheirResponsibleProcess() {
        #expect(resolver.ownerBundleID(proc(3, 300, "com.apple.WebKit.GPU")) == "com.readread.app")
        #expect(resolver.ownerBundleID(proc(4, 500, "com.apple.WebKit.GPU")) == "com.apple.Safari")
    }

    @Test func candidatesGroupKnownAppsAndDefaultIsTheOneReadingTheMic() {
        let ps = [proc(1, 100, "us.zoom.xos", input: true), proc(2, 101, nil), proc(3, 201, "com.google.Chrome.helper"),
                  proc(4, 300, "com.apple.WebKit.GPU"), proc(5, 600, "com.tencent.meeting", output: false)]
        let c = resolver.candidates(ps)
        #expect(c.map(\.app.id) == ["us.zoom.xos", "com.tencent.meeting", "com.google.Chrome"])
        #expect(c[0].objectIDs == [1, 2])
        #expect(MeetingSourceResolver.defaultSource(c)?.app.id == "us.zoom.xos")
    }

    @Test func twoCallsNeedTheUsersChoiceUnlessOneWasPreferred() {
        let ps = [proc(1, 100, "us.zoom.xos", input: true), proc(5, 600, "com.tencent.meeting", input: true)]
        let c = resolver.candidates(ps)
        #expect(MeetingSourceResolver.defaultSource(c) == nil)
        #expect(MeetingSourceResolver.defaultSource(c, preferred: "com.tencent.meeting")?.app.id == "com.tencent.meeting")
    }

    @Test func readreadIsNeverACandidate() {
        let c = resolver.candidates([proc(9, 400, "com.readread.app"), proc(4, 300, "com.apple.WebKit.GPU")])
        #expect(c.isEmpty)
    }
}

@Suite struct TapWatchdogTests {
    @Test func neverRebuildsWithoutPriorSound() {
        var w = TapWatchdog()
        for t in stride(from: 0, through: 60_000, by: 1000) {
            #expect(w.observe(nowMs: t, runningOutput: true, lastNonZeroMs: nil) == .noAudioYet)
        }
    }

    @Test func rebuildsAfterTenSecondsOfZerosThenBacksOff() {
        var w = TapWatchdog()
        #expect(w.observe(nowMs: 0, runningOutput: true, lastNonZeroMs: 0) == .ok)
        var verdicts: [(Int, TapWatchdog.Verdict)] = []
        for t in stride(from: 1000, through: 200_000, by: 1000) {
            let v = w.observe(nowMs: t, runningOutput: true, lastNonZeroMs: 0)
            if case .rebuild = v { verdicts.append((t, v)) }
        }
        #expect(verdicts.map(\.0) == [10_000, 70_000, 190_000])   // +60 s, +120 s
        #expect(w.rebuilds == 3)
    }

    @Test func outputStoppingResetsTheZeroCount() {
        var w = TapWatchdog()
        _ = w.observe(nowMs: 0, runningOutput: true, lastNonZeroMs: 0)
        for t in stride(from: 1000, through: 8000, by: 1000) { _ = w.observe(nowMs: t, runningOutput: true, lastNonZeroMs: 0) }
        _ = w.observe(nowMs: 9000, runningOutput: false, lastNonZeroMs: 0)
        // Output restarts at 30 s: the 10 s count starts there, not at the last sound.
        #expect(w.observe(nowMs: 30_000, runningOutput: true, lastNonZeroMs: 0) == .ok)
        #expect(w.observe(nowMs: 39_000, runningOutput: true, lastNonZeroMs: 0) == .ok)
        #expect(w.observe(nowMs: 40_000, runningOutput: true, lastNonZeroMs: 0) == .rebuild(attempt: 1))
    }
}

@Suite struct TCCProbeToneTests {
    @Test func toneIsQuietAndHasALeadIn() {
        let wav = TCCProbe.toneWAV(seconds: 0.3, leadSilence: 0.25, dbfs: -40, frequency: 880)
        #expect(wav.count == 44 + Int(0.55 * 48_000) * 2)
        let samples = wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples.prefix(12_000).allSatisfy { $0 == 0 })
        let peak = samples.map { abs(Int($0)) }.max()!
        #expect(peak <= 328 && peak >= 300)   // −40 dBFS ≈ 327.7
    }
}
