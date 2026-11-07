// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkCore
import CDriverSelfTest
import CoreAudio
import Foundation
import TalkTalkAudio

/// The result of one driver self-test run (ARCHITECTURE.md §8.4 "校验").
public struct DriverSelfTestReport: Codable, Sendable, Equatable {
    public struct Check: Codable, Sendable, Equatable {
        public enum Name: String, Codable, Sendable, CaseIterable {
            case properties, loopback, isolation, replay, gate, meetingPath

            /// The check's name with what it proves (§7.12 详情): "回环（第 2 声道 → Test Mic）".
            public var title: String {
                switch self {
                case .properties: String(appLocalized: "设备属性")
                case .loopback: String(appLocalized: "回环（第 2 声道 → Test Mic）")
                case .isolation: String(appLocalized: "隔离（TalkTalk Mic 全零）")
                case .replay: String(appLocalized: "防重放")
                case .gate: String(appLocalized: "门禁（其他 App 写不进 Feed）")
                case .meetingPath: String(appLocalized: "会议声道（第 1 声道 → TalkTalk Mic）")
                }
            }

            /// The bare name, for lists in a sentence: "回环、隔离".
            public var shortTitle: String {
                switch self {
                case .properties: String(appLocalized: "设备属性")
                case .loopback: String(appLocalized: "回环")
                case .isolation: String(appLocalized: "隔离")
                case .replay: String(appLocalized: "防重放")
                case .gate: String(appLocalized: "门禁")
                case .meetingPath: String(appLocalized: "会议声道")
                }
            }

            /// Stored names (driver.json keeps the raw values) in words; an unknown one as is.
            public static func shortTitles(_ stored: [String]) -> String {
                stored.map { Name(rawValue: $0)?.shortTitle ?? $0 }.joined(separator: String(appLocalized: "、"))
            }
        }
        public var name: Name
        /// nil = skipped (see `detail`).
        public var passed: Bool?
        public var detail: String
        public var metrics: [String: Double]

        public init(_ name: Name, passed: Bool?, detail: String = "", metrics: [String: Double] = [:]) {
            self.name = name
            self.passed = passed
            self.detail = detail
            self.metrics = metrics
        }
    }

    public var version: String?
    public var startedAt: Date
    public var checks: [Check]
    /// Why the IO checks did not run at all (e.g. "没有麦克风授权"); nil when they ran.
    public var skipReason: String?

    public init(version: String?, startedAt: Date = Date(), checks: [Check] = [], skipReason: String? = nil) {
        self.version = version
        self.startedAt = startedAt
        self.checks = checks
        self.skipReason = skipReason
    }

    /// The checks that must have run and passed before the driver counts as tested. isolation (skipped
    /// while TalkTalk plays on channel 1) and meetingPath (§8.4's conditions) may be skipped.
    public static let required: [Check.Name] = [.properties, .loopback, .replay, .gate]

    public var failed: [Check.Name] { checks.filter { $0.passed == false }.map(\.name) }
    /// Required checks that did not run (skipped, or never reached).
    public var notRun: [Check.Name] { Self.required.filter { check($0)?.passed == nil } }
    /// Every required check ran and passed, and nothing failed.
    public var passed: Bool { failed.isEmpty && notRun.isEmpty }
    /// A verdict worth writing to driver.json: passed, or something failed. A run that skipped a
    /// required check without any failure (no microphone permission, say) proves nothing, and must
    /// neither mark the driver as tested nor clear an earlier failure.
    public var isConclusive: Bool { passed || !failed.isEmpty }

    /// One line for an inconclusive run: "跳过：没有麦克风授权", "跳过：门禁没有跑（…）".
    public var incompleteText: String {
        if let skipReason { return String(appLocalized: "跳过：\(skipReason)") }
        let names = Check.Name.shortTitles(notRun.map(\.rawValue))
        let why = notRun.compactMap { n in check(n).map(\.detail).flatMap { $0.isEmpty ? nil : $0 } }.first
        guard let why else { return String(appLocalized: "跳过：\(names)没有跑") }
        return String(appLocalized: "跳过：\(names)没有跑（\(why)）")
    }

    public func check(_ n: Check.Name) -> Check? { checks.first { $0.name == n } }
}

/// Runs the self-test checks against the installed driver. Only Feed channel 2 is written and only
/// Test Mic is read for the signal, so TalkTalk Mic (the meeting) never hears the sweep or the
/// tone; TalkTalk Mic is read only to prove it stays silent. The channel 1 → TalkTalk Mic path
/// runs only when asked for and the caller checked §8.4's conditions (nobody else on the Mic, the
/// default input is not the Mic, no restore record).
///
/// Never call it on the main thread's behalf synchronously: input IO waits on the microphone
/// permission (M0-T8: minutes while a TCC prompt is pending). `run` hops to a detached task and
/// checks the permission first.
public struct DriverSelfTest: Sendable {
    public struct Options: Sendable, Equatable {
        public var includeMeetingPath: Bool
        public var replayCycles: Int
        public var replayOn: Duration
        public var replayOff: Duration
        /// `Contents/Resources/driver/feedprobe` (nil: the gate check is skipped).
        public var feedProbe: URL?
        /// The app's own Feed output is playing on channel 1 right now: the isolation check (which
        /// expects zeros on TalkTalk Mic) is skipped.
        public var channel1Busy: Bool
        /// Ask for the microphone permission when it is undetermined (onboarding); otherwise skip.
        public var requestPermission: Bool

        public init(includeMeetingPath: Bool = false, replayCycles: Int = 20, replayOn: Duration = .milliseconds(300),
                    replayOff: Duration = .milliseconds(300), feedProbe: URL? = nil, channel1Busy: Bool = false,
                    requestPermission: Bool = false) {
            self.includeMeetingPath = includeMeetingPath
            self.replayCycles = replayCycles
            self.replayOn = replayOn
            self.replayOff = replayOff
            self.feedProbe = feedProbe
            self.channel1Busy = channel1Busy
            self.requestPermission = requestPermission
        }
    }

    public let hal: any DriverHAL
    public let expectedVersion: String?
    /// sysinput's restore record exists (`SysInputRecordStore.exists`); asked again right before
    /// the meeting path starts.
    public let restoreRecordExists: @Sendable () -> Bool

    public init(hal: any DriverHAL = CoreAudioDriverHAL(), expectedVersion: String?,
                restoreRecordExists: @escaping @Sendable () -> Bool = { false }) {
        self.hal = hal
        self.expectedVersion = expectedVersion
        self.restoreRecordExists = restoreRecordExists
    }

    public func run(_ options: Options = .init()) async -> DriverSelfTestReport {
        var report = DriverSelfTestReport(version: hal.loadedVersion())
        // TalkTalk Mic joins the device list ~150 ms after this process becomes a HAL client
        // (M0-T8); a headless `--self-test` may have just touched Core Audio for the first time.
        for _ in 0..<20 where hal.device(uid: DriverIdentity.micUID)?.inDeviceList != true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let props = propertiesCheck()
        report.checks.append(props)
        guard props.passed == true else { return report }

        var auth = MicrophoneAuthorization.current
        if auth == .notDetermined, options.requestPermission { auth = await MicrophoneAuthorization.request() }
        guard auth == .authorized else {
            let why = String(appLocalized: "需要麦克风权限（读 Test Mic 也算麦克风访问）：\(Self.words(auth))")
            for n in [DriverSelfTestReport.Check.Name.loopback, .isolation, .replay, .gate] {
                report.checks.append(.init(n, passed: nil, detail: why))
            }
            report.skipReason = String(appLocalized: "没有麦克风授权")
            return report
        }
        let runner = IORunner(hal: hal, restoreRecordExists: restoreRecordExists)
        let checks = await Task.detached(priority: .userInitiated) {
            await runner.runAll(options)
        }.value
        report.checks.append(contentsOf: checks)
        return report
    }

    /// The microphone permission in words, for the skipped checks' detail.
    static func words(_ auth: MicrophoneAuthorization) -> String {
        switch auth {
        case .authorized: String(appLocalized: "已允许")
        case .denied: String(appLocalized: "已拒绝")
        case .restricted: String(appLocalized: "受限")
        case .notDetermined: String(appLocalized: "未决定")
        }
    }

    /// §8.4: the channel 1 → TalkTalk Mic path is tested only when nobody else uses the Mic, the
    /// default input is not the Mic and there is no restore record. nil = allowed, else why not.
    public static func meetingPathBlocker(hal: any DriverHAL, restoreRecordExists: Bool) -> String? {
        if restoreRecordExists { return String(appLocalized: "有默认输入还原记录") }
        if hal.defaultInputUID() == DriverIdentity.micUID { return String(appLocalized: "系统默认输入是 TalkTalk Mic") }
        if let users = hal.diagnostics()?.micUsers.filter({ $0.pid != getpid() }), !users.isEmpty {
            return String(appLocalized: "有 App 正在读 TalkTalk Mic")
        }
        if hal.diagnostics() == nil, hal.device(uid: DriverIdentity.micUID)?.isRunningSomewhere == true {
            return String(appLocalized: "TalkTalk Mic 正在被使用")
        }
        return nil
    }

    /// §8.4 校验 1: the HAL properties of the three devices.
    func propertiesCheck() -> DriverSelfTestReport.Check {
        guard let feed = hal.device(uid: DriverIdentity.feedUID) else {
            return .init(.properties, passed: false, detail: "TalkTalk Feed not found by UID")
        }
        let testMic = hal.device(uid: DriverIdentity.testMicUID)
        var problems = DriverInstallation.deviceProblems(feed: feed, testMic: testMic)
        let loaded = hal.loadedVersion()
        if let v = expectedVersion, loaded != v {
            problems.append("driver reports version \(loaded ?? "?"), app carries \(v)")
        }
        if let mic = hal.device(uid: DriverIdentity.micUID) {
            if !mic.inDeviceList { problems.append("TalkTalk Mic is not in the device list") }
            if mic.inputChannels != 1 || mic.outputChannels != 0 {
                problems.append("TalkTalk Mic has \(mic.inputChannels) in / \(mic.outputChannels) out")
            }
            if mic.sampleRate != DriverIdentity.sampleRate { problems.append("TalkTalk Mic runs at \(mic.sampleRate) Hz") }
        } else {
            problems.append("TalkTalk Mic not found (it appears while TalkTalk runs)")
        }
        return .init(.properties, passed: problems.isEmpty, detail: problems.joined(separator: "; "))
    }
}

/// The IO part, on a background task. Owns the C contexts for the duration of one run.
struct IORunner: Sendable {
    let hal: any DriverHAL
    let restoreRecordExists: @Sendable () -> Bool

    func runAll(_ o: DriverSelfTest.Options) async -> [DriverSelfTestReport.Check] {
        var out: [DriverSelfTestReport.Check] = []
        guard let feed = hal.device(uid: DriverIdentity.feedUID)?.objectID,
              let testMic = hal.device(uid: DriverIdentity.testMicUID)?.objectID else {
            return [.init(.loopback, passed: false, detail: "Feed or Test Mic vanished")]
        }
        let mic = hal.device(uid: DriverIdentity.micUID)?.objectID
        let (loop, iso) = await loopback(feed: feed, signalDevice: testMic, otherDevice: mic, channel: 1,
                                         name: .loopback, isolationName: .isolation, skipIsolation: o.channel1Busy)
        out.append(loop)
        out.append(iso)
        out.append(await replay(feed: feed, testMic: testMic, o))
        out.append(await gate(testMic: testMic, probe: o.feedProbe))
        if o.includeMeetingPath, let mic {
            out.append(await meetingPath(feed: feed, mic: mic, testMic: testMic))
        }
        return out
    }

    /// §8.4: the sweep goes into TalkTalk Mic, so the conditions the caller checked before the run
    /// (~16 s earlier: loopback, replay, gate) are checked again right before it starts.
    func meetingPath(feed: AudioObjectID, mic: AudioObjectID, testMic: AudioObjectID) async -> DriverSelfTestReport.Check {
        if let why = DriverSelfTest.meetingPathBlocker(hal: hal, restoreRecordExists: restoreRecordExists()) {
            return .init(.meetingPath, passed: nil, detail: why)
        }
        let (path, _) = await loopback(feed: feed, signalDevice: mic, otherDevice: testMic, channel: 0,
                                       name: .meetingPath, isolationName: .isolation, skipIsolation: false)
        return path
    }

    /// Writes the sweep on `channel` (0-based) and records `signalDevice` (expects the sweep)
    /// and `otherDevice` (expects zeros).
    func loopback(feed: AudioObjectID, signalDevice: AudioObjectID, otherDevice: AudioObjectID?, channel: UInt32,
                  name: DriverSelfTestReport.Check.Name, isolationName: DriverSelfTestReport.Check.Name,
                  skipIsolation: Bool) async -> (DriverSelfTestReport.Check, DriverSelfTestReport.Check) {
        let sweep = DriverLoopbackAnalysis.sweep()
        guard let w = sweep.withUnsafeBufferPointer({
            tt_st_writer_create($0.baseAddress, UInt32($0.count), channel, UInt32(DriverLoopbackAnalysis.leadFrames), 8)
        }), let rs = tt_st_recorder_create(48_000 * 5, 4_000), let ro = tt_st_recorder_create(48_000 * 5, 4_000) else {
            return (.init(name, passed: false, detail: "out of memory"), .init(isolationName, passed: nil, detail: "out of memory"))
        }
        defer { tt_st_writer_destroy(w); tt_st_recorder_destroy(rs); tt_st_recorder_destroy(ro) }
        let recS = IOProc(device: signalDevice, proc: tt_st_recorder_ioproc, context: UnsafeMutableRawPointer(rs))
        let recO = otherDevice.map { IOProc(device: $0, proc: tt_st_recorder_ioproc, context: UnsafeMutableRawPointer(ro)) }
        let wr = IOProc(device: feed, proc: tt_st_writer_ioproc, context: UnsafeMutableRawPointer(w))
        tt_st_writer_set_mode(w, TT_ST_MODE_SIGNAL)
        let sS = recS.start()
        let sO = recO?.start() ?? noErr
        try? await Task.sleep(for: .milliseconds(200))
        let sW = wr.start()
        try? await Task.sleep(for: .milliseconds(1_250 + 1_000))   // lead + sweep + margin
        wr.stop()
        try? await Task.sleep(for: .milliseconds(200))
        recS.stop()
        recO?.stop()
        guard sS == noErr, sW == noErr else {
            let d = "IO start failed: recorder \(fourCC(sS)), Feed \(fourCC(sW))"
            return (.init(name, passed: false, detail: d), .init(isolationName, passed: nil, detail: d))
        }
        let start = tt_st_writer_signal_start(w)
        let st = DriverLoopbackAnalysis.analyze(Self.recording(rs), signal: sweep,
                                                signalStart: start == Int64.min ? nil : start)
        var m: [String: Double] = ["lagFrames": Double(st.bestLag), "peak": st.peak,
                                   "nonzeroOutside": Double(st.nonzeroOutside), "samples": Double(st.samples),
                                   "writerDiscontinuities": Double(tt_st_writer_discontinuities(w)),
                                   "recorderDiscontinuities": Double(tt_st_recorder_discontinuities(rs))]
        if let l = st.levelDeltaDB { m["levelDeltaDB"] = l }
        var detail = st.passes ? "" : String(format: "lag %d, peak %.3f, level %@ dB, %d nonzero outside the sweep",
                                             st.bestLag, st.peak, st.levelDeltaDB.map { String(format: "%.2f", $0) } ?? "–",
                                             st.nonzeroOutside)
        if st.samples > 0, st.nonzero == 0 { detail += "; recorded only zeros (microphone permission?)" }
        let loop = DriverSelfTestReport.Check(name, passed: st.passes, detail: detail, metrics: m)

        let iso: DriverSelfTestReport.Check
        if skipIsolation {
            iso = .init(isolationName, passed: nil, detail: String(appLocalized: "TalkTalk 正在往会议声道播放，跳过隔离检查"))
        } else if otherDevice == nil {
            iso = .init(isolationName, passed: nil, detail: "TalkTalk Mic not found")
        } else if sO != noErr {
            iso = .init(isolationName, passed: false, detail: "IO start failed: \(fourCC(sO))")
        } else {
            let frames = Int(tt_st_recorder_frames(ro)), nz = Int(tt_st_recorder_nonzero(ro))
            iso = .init(isolationName, passed: frames > 0 && nz == 0,
                        detail: frames == 0 ? "no frames recorded" : (nz == 0 ? "" : "\(nz) nonzero frames on the other device"),
                        metrics: ["frames": Double(frames), "nonzero": Double(nz)])
        }
        return (loop, iso)
    }

    /// §8.4 校验 4 on channel 2: the tone writer stops and restarts `cycles` times while Test Mic is
    /// read; while it is stopped Test Mic must read exact zeros (no stale TTS replayed).
    func replay(feed: AudioObjectID, testMic: AudioObjectID, _ o: DriverSelfTest.Options) async -> DriverSelfTestReport.Check {
        let cycles = max(1, o.replayCycles)
        let seconds = Double(cycles) * (o.replayOn + o.replayOff).seconds + 1.5
        guard let w = tt_st_writer_create(nil, 0, 1, 0, UInt32(cycles + 4)),
              let r = tt_st_recorder_create(UInt32(48_000 * seconds), UInt32(seconds * 200)) else {
            return .init(.replay, passed: false, detail: "out of memory")
        }
        defer { tt_st_writer_destroy(w); tt_st_recorder_destroy(r) }
        tt_st_writer_set_mode(w, TT_ST_MODE_TONE)
        let rec = IOProc(device: testMic, proc: tt_st_recorder_ioproc, context: UnsafeMutableRawPointer(r))
        guard rec.start() == noErr else { return .init(.replay, passed: false, detail: "Test Mic IO failed") }
        try? await Task.sleep(for: .milliseconds(300))
        var startFailures = 0
        for _ in 0..<cycles {
            tt_st_writer_break_range(w)
            let wr = IOProc(device: feed, proc: tt_st_writer_ioproc, context: UnsafeMutableRawPointer(w))
            if wr.start() != noErr { startFailures += 1 }
            try? await Task.sleep(for: o.replayOn)
            wr.stop()   // AudioDeviceStop + DestroyIOProcID: the driver sees StopIO
            try? await Task.sleep(for: o.replayOff)
        }
        try? await Task.sleep(for: .milliseconds(200))
        rec.stop()
        var raw = [tt_st_range](repeating: tt_st_range(), count: cycles + 4)
        let n = Int(tt_st_writer_ranges(w, &raw, UInt32(raw.count)))
        let ranges = raw.prefix(min(n, raw.count)).filter { $0.end > $0.begin }.map { $0.begin...($0.end - 1) }
        let stats = DriverLoopbackAnalysis.replay(Self.recording(r), ranges: ranges,
                                                  lag: Int64(DriverIdentity.loopbackLagFrames),
                                                  tone: { tt_st_tone(w, $0) })
        let pass = stats.passes(cycles: cycles) && startFailures == 0
        let detail = pass ? "" : "\(stats.silentNonzero) nonzero frames while stopped, \(stats.playedBad) wrong frames, "
            + "\(stats.ranges)/\(cycles) runs, \(startFailures) start failures"
        return .init(.replay, passed: pass, detail: detail, metrics: [
            "cycles": Double(cycles), "checked": Double(stats.checked), "playedOK": Double(stats.playedOK),
            "playedBad": Double(stats.playedBad), "silentOK": Double(stats.silentOK),
            "silentNonzero": Double(stats.silentNonzero), "ranges": Double(stats.ranges),
        ])
    }

    /// §8.4 校验 3: the bare `feedprobe` (no bundle id) must be refused by the gate, and Test Mic
    /// must stay silent while it tries (the probe writes only channel 2). With the M2 driver the
    /// probe also tries to write 'ttmm' (the value it read, so nothing changes even if accepted):
    /// the driver must refuse it and count the refusal.
    func gate(testMic: AudioObjectID, probe: URL?) async -> DriverSelfTestReport.Check {
        guard let probe, FileManager.default.isExecutableFile(atPath: probe.path) else {
            return .init(.gate, passed: nil, detail: "feedprobe is not in this build")
        }
        let before = hal.diagnostics()
        guard let r = tt_st_recorder_create(48_000 * 4, 2_000) else { return .init(.gate, passed: false, detail: "out of memory") }
        defer { tt_st_recorder_destroy(r) }
        let rec = IOProc(device: testMic, proc: tt_st_recorder_ioproc, context: UnsafeMutableRawPointer(r))
        _ = rec.start()
        let result = Self.runProbe(probe)
        try? await Task.sleep(for: .milliseconds(200))
        rec.stop()
        let after = hal.diagnostics()
        let denied = (after?.feedStartIODenied ?? 0) - (before?.feedStartIODenied ?? 0)
            + (after?.feedAddClientDenied ?? 0) - (before?.feedAddClientDenied ?? 0)
        let nz = Int(tt_st_recorder_nonzero(r))
        guard let result else { return .init(.gate, passed: false, detail: "feedprobe did not report") }
        let found = result["found"] as? Bool ?? false
        let refused = result["refused"] as? Bool ?? false
        let cycles = (result["ioCycles"] as? NSNumber)?.doubleValue ?? -1
        // M2 'ttmm': the probe writes back the value it read, so a broken gate changes nothing.
        // A driver without 'ttmm' (before M2) fails the read: that half is then skipped.
        let ttmmRead = (result["ttmmRead"] as? NSNumber)?.int32Value
        let ttmmStatus = (result["ttmmStatus"] as? NSNumber)?.int32Value
        let ttmmChecked = ttmmRead == noErr
        let ttmmDenied = (after?.ttmmDenied ?? 0) - (before?.ttmmDenied ?? 0)
        let ttmmRefused = !ttmmChecked || (ttmmStatus != noErr && ttmmDenied > 0)
        let pass = found && refused && nz == 0 && ttmmRefused
        var detail = ""
        if !found { detail = "feedprobe could not find the Feed" }
        else if !refused { detail = "feedprobe was NOT refused (\(Int(cycles)) IO cycles)" }
        else if nz > 0 { detail = "Test Mic heard \(nz) nonzero frames while the probe ran" }
        else if !ttmmRefused { detail = "the driver accepted feedprobe's 'ttmm' write (status \(ttmmStatus ?? 0))" }
        else if !ttmmChecked { detail = "'ttmm' not checked: the driver has no meeting-mode switch" }
        return .init(.gate, passed: pass, detail: detail, metrics: [
            "probeIOCycles": cycles, "driverDenied": Double(denied), "testMicNonzero": Double(nz),
            "startStatus": (result["startStatus"] as? NSNumber)?.doubleValue ?? 0,
            "ttmmStatus": Double(ttmmStatus ?? 0), "ttmmDenied": Double(ttmmDenied),
        ])
    }

    static func runProbe(_ url: URL) -> [String: Any]? {
        let p = Process()
        p.executableURL = url
        p.arguments = ["--uid", DriverIdentity.feedUID, "--ms", "800", "--ttmm"]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func recording(_ r: OpaquePointer) -> DriverLoopbackAnalysis.Recording {
        let nc = Int(tt_st_recorder_chunk_count(r))
        var chunks = [tt_st_chunk](repeating: tt_st_chunk(), count: nc)
        _ = tt_st_recorder_chunks(r, &chunks, UInt32(nc))
        let ns = Int(tt_st_recorder_sample_count(r))
        var samples = [Float](repeating: 0, count: ns)
        _ = tt_st_recorder_samples(r, &samples, UInt32(ns))
        return .init(chunks: chunks.map { .init(sampleTime: $0.sample_time, frames: Int($0.frames), offset: Int($0.offset)) },
                     samples: samples)
    }
}

/// One IOProc on one device; `stop` stops and destroys it.
final class IOProc {
    let device: AudioObjectID
    let proc: AudioDeviceIOProc
    let context: UnsafeMutableRawPointer
    private var id: AudioDeviceIOProcID?

    init(device: AudioObjectID, proc: AudioDeviceIOProc, context: UnsafeMutableRawPointer) {
        self.device = device
        self.proc = proc
        self.context = context
    }

    deinit { stop() }

    func start(bufferFrames: UInt32 = 480) -> OSStatus {
        var frames = bufferFrames
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        var newID: AudioDeviceIOProcID?
        let c = AudioDeviceCreateIOProcID(device, proc, context, &newID)
        guard c == noErr, let newID else { return c == noErr ? OSStatus(kAudioHardwareUnspecifiedError) : c }
        id = newID
        return AudioDeviceStart(device, newID)
    }

    func stop() {
        guard let id else { return }
        AudioDeviceStop(device, id)
        AudioDeviceDestroyIOProcID(device, id)
        self.id = nil
    }
}

func fourCC(_ s: OSStatus) -> String {
    if s == noErr { return "noErr" }
    let u = UInt32(bitPattern: s)
    let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) { return "'" + String(decoding: bytes, as: UTF8.self) + "'" }
    return String(s)
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
