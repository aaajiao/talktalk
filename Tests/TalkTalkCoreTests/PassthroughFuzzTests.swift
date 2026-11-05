import Foundation
import Synchronization
import Testing
@testable import TalkTalkCore

/// File-private like the other suites' helpers (an internal one would clash with theirs).
private func ms(_ v: Int) -> HostTime { HostTime(v) * 1_000_000 }

/// Seeded random simulations of the passthrough key, gate and push-to-talk on a virtual clock
/// (ARCHITECTURE.md §3.8 "测试"). Each seed builds a physical timeline (key presses with lost
/// key-ups, duplicate downs and non-HID sources, shortcuts, mouse buttons/scroll/moves, press-and-
/// speak, push-to-talk interleavings, tap failures, key-thread stalls, sleep/lock/coreaudiod/device
/// events, MeetingMicGuard and speaker-mode flips, unknown facts, the self-test source), delivers
/// it the way KeyTap, the poll timer, VAD, the control plane and the worker would (0–20 ms random
/// delivery delay, FIFO per thread, nothing during a stall, random mic block sizes and rates),
/// and checks every interval the gate opened against an oracle written from the rules, not from
/// the gate:
///   - every admitted sample lies in its generation's [open, close), and mic samples never in a
///     self-test interval;
///   - every mic interval follows a qualifying clean HID hold (clean at the press, held through,
///     ≥ 400 ms, nothing else in it, no speech known before the open, every fact known and good,
///     push-to-talk not active, tap healthy), the press being the last right ⌘ down delivered
///     before the open (a duplicate down is a re-press whose key-up was lost);
///   - it closed no later than the first closing input or event after the open, 130 ms after a
///     key-thread stall began, and 30 s after the open;
///   - push-to-talk and the passthrough never overlap.
/// `scripts/check.sh` runs 20,000 fresh seeds per run (8 parallel chunks); a failing seed is
/// appended to `Tests/Golden/passthrough_fuzz_regressions.json` and every seed there is replayed.
@Suite struct PassthroughFuzzTests {
    static let chunks = 8
    static var seedsPerRun: Int {
        Int(ProcessInfo.processInfo.environment["TALKTALK_FUZZ_SEEDS"] ?? "") ?? 20_000
    }
    static let base: UInt64 = {
        if let s = ProcessInfo.processInfo.environment["TALKTALK_FUZZ_BASE"], let v = UInt64(s, radix: 16) { return v }
        return UInt64.random(in: 0..<(1 << 48))
    }()

    @Test(arguments: 0..<PassthroughFuzzTests.chunks)
    func fuzz(chunk: Int) throws {
        let profile = try TestResources.profile()
        let per = (Self.seedsPerRun + Self.chunks - 1) / Self.chunks
        // A crash cannot save its seed: the base reproduces the run (TALKTALK_FUZZ_BASE=<hex>).
        if chunk == 0 { print("passthrough fuzz: base 0x\(String(Self.base, radix: 16)), \(per * Self.chunks) seeds") }
        var failures: [(UInt64, [String])] = []
        for i in 0..<per {
            let seed = Self.base &+ UInt64(chunk * per + i)
            var sim = FuzzSim(seed: seed, profile: profile)
            let problems = sim.run()
            if !problems.isEmpty { failures.append((seed, problems)) }
        }
        if !failures.isEmpty {
            try FuzzRegressions.add(failures.map(\.0))
            for (seed, p) in failures.prefix(5) {
                Issue.record("seed 0x\(String(seed, radix: 16)) (saved to the regression file): \(p.prefix(3).joined(separator: "; "))")
            }
        }
    }

    @Test func regressionSeedsReplay() throws {
        let profile = try TestResources.profile()
        let seeds = try FuzzRegressions.load()
        for seed in seeds {
            var sim = FuzzSim(seed: seed, profile: profile)
            let problems = sim.run()
            #expect(problems.isEmpty, "regression seed 0x\(String(seed, radix: 16)): \(problems.prefix(3))")
        }
    }

    /// The oracle is not vacuous: the simulations do open, close for every reason class, and refuse.
    @Test func coverage() throws {
        let profile = try TestResources.profile()
        var opens = 0, refusals = 0, ptt = 0, selfTest = 0, admitted = 0
        var reasons: Set<String> = []
        for seed in UInt64(0)..<400 {
            var sim = FuzzSim(seed: seed, profile: profile)
            let problems = sim.run()
            #expect(problems.isEmpty, "seed \(seed): \(problems.prefix(3))")
            opens += sim.intervals.filter { !$0.selfTest }.count
            selfTest += sim.intervals.filter(\.selfTest).count
            refusals += sim.refusals
            ptt += sim.pttIntervals.count
            admitted += sim.admits.count
            reasons.formUnion(sim.closeReasons)
        }
        #expect(opens > 200 && refusals > 50 && ptt > 100 && selfTest > 0 && admitted > 1000)
        for r in ["key_up", "other_key", "modifier", "mouse_button", "scroll", "lost_key_up", "lease_expired",
                  "max_hold", "spoke_before_open"] {
            #expect(reasons.contains(r), "no close with reason \(r)")
        }
        #expect(reasons.contains { $0.hasPrefix("tap_") })
        #expect(reasons.contains { PassthroughSystemEvent(rawValue: $0) != nil })
    }
}

// MARK: - Regression file

enum FuzzRegressions {
    struct File: Codable { var note: String; var seeds: [String] }
    static let lock = Mutex(())
    static var url: URL { TestResources.golden("passthrough_fuzz_regressions.json") }

    static func load() throws -> [UInt64] {
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return f.seeds.compactMap { UInt64($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) }
    }

    static func add(_ seeds: [UInt64]) throws {
        try lock.withLock { _ in
            var f = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            for s in seeds {
                let hex = "0x" + String(s, radix: 16)
                if !f.seeds.contains(hex) { f.seeds.append(hex) }
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (enc.encode(f) + Data("\n".utf8)).write(to: url)
        }
    }
}

// MARK: - The simulation

struct FuzzSim {
    enum FactValue { case good, bad, unknown }
    enum Ctl {
        case fact(PassthroughPolicy.Fact, FactValue)
        case system(PassthroughSystemEvent)
        case speechOn(onset: HostTime)
        case speechOff(end: HostTime)
        case source(PassthroughSource)
        case selfTestOpen(ms: Int)
    }
    enum Phys {
        case key(code: UInt16, down: Bool, source: KeyEventSource, lose: Bool)
        case mouseButton(down: Bool)
        case scroll
        case move(dx: Double, dy: Double)
        case tapFail(TapFailure)
        case tapOK
        case speech(on: Bool)
        case ctl(Ctl)
        case commit
    }
    enum Item {
        case phys(Phys)
        case tap(KeyInputEvent, physIndex: Int? = nil)
        case ctl(Ctl)
        case micStarted
        case playoutAnswer
    }
    struct PhysRecord {
        var t: HostTime
        var phys: Phys
        var delivered: HostTime?
        var cleanBefore: Bool      // nothing else held just before (for right ⌘ downs)
        var duplicate: Bool
        var ignored = false        // changed no physical state (an up of a key that was not down)
        var keyLogIndex: Int?      // where its delivery landed in keyLog
        var happenedAt = 0         // keyLog.count when it happened (orders a lost event against an open)
    }
    struct Interval {
        var open: HostTime
        var close: HostTime?
        var generation: UInt32
        var selfTest: Bool
        var keyLogIndex: Int
        var ctlLogIndex: Int
        var facts: PassthroughPolicy.Facts
        var tapHealthy: Bool
        var pttActive: Bool
        var source: PassthroughSource
    }
    struct Admit { var generation: UInt32; var source: PassthroughSource; var first: HostTime; var last: HostTime }
    struct SpeechSeg {
        var onset: HostTime; var onsetReport: HostTime; var end: HostTime?; var endReport: HostTime?
        /// Where the reports sit in ctlLog: the order they reached the gate relative to an open
        /// (a report at the open's own instant may come before or after it).
        var onsetLogIndex: Int; var endLogIndex: Int?
    }
    enum CtlRecord { case closer; case facts(allGood: Bool); case lateOnset(onset: HostTime); case speechEnd }

    static let toggleable: [PassthroughPolicy.Fact] = [.meetingModeActive, .settingEnabled, .micGuard, .speakerMode,
                                                       .awaitingAudioConfirmation, .secureInput, .physicalMicPassesRule2]
    static let modifierBits: [UInt16: ModifierFlags] = [
        KeyCode.rightCommand: [.deviceRightCommand, .command], KeyCode.command: [.deviceLeftCommand, .command],
        KeyCode.shift: [.deviceLeftShift, .shift], KeyCode.rightShift: [.deviceRightShift, .shift],
        KeyCode.option: [.deviceLeftOption, .option], KeyCode.rightOption: [.deviceRightOption, .option],
        KeyCode.control: [.deviceLeftControl, .control], KeyCode.rightControl: [.deviceRightControl, .control],
        KeyCode.function: [.function],
    ]

    let seed: UInt64
    let pt: PolicyProfile.Speak.Passthrough
    let speakProfile: PolicyProfile.Speak
    var rng: PTSplitMix64

    // scenario
    var physEvents: [(t: HostTime, p: Phys)] = []
    var stalls: [(start: HostTime, end: HostTime)] = []
    var end: HostTime = 0
    var rate: Double = 48_000
    var micWarm = true
    var cueAudible = false
    var playoutMode = 0          // 0 none, 1 answers at once, 2 random delay, 3 sometimes never
    var initialFacts = PassthroughPolicy.Facts.allGood
    var sampleCache: [Int: [Float]] = [:]

    // results
    var intervals: [Interval] = []
    var admits: [Admit] = []
    var pttIntervals: [(begin: HostTime, end: HostTime)] = []
    var refusals = 0
    var closeReasons: Set<String> = []

    init(seed: UInt64, profile: PolicyProfile) {
        self.seed = seed
        pt = profile.speak.passthrough
        speakProfile = profile.speak
        rng = PTSplitMix64(seed: seed)
    }

    // MARK: random helpers

    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &rng) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }

    // MARK: scenario

    mutating func addKey(_ t: HostTime, _ code: UInt16, down: Bool, source: KeyEventSource = .hidSystem, lose: Bool = false) {
        physEvents.append((t, .key(code: code, down: down, source: source, lose: lose)))
    }

    mutating func generate() {
        rate = pick([16_000, 44_100, 48_000])
        micWarm = chance(0.8)
        cueAudible = chance(0.5)
        playoutMode = chance(0.6) ? 0 : pick([1, 1, 2, 3])
        if chance(0.05) {
            let f = pick(Self.toggleable)
            set(&initialFacts, f, unknown: true)
            let restore = ms(int(200...2000)) + ms(500)
            physEvents.append((restore, .ctl(.fact(f, .good))))
        }
        let long = chance(0.04)
        var t = ms(1000)
        if long {
            // one clean hold past maxHoldS, with renewals all the way
            addKey(t, KeyCode.rightCommand, down: true)
            let hold = int(30_500...32_000)
            if chance(0.5) { physEvents.append((t + ms(int(600...2000)), .speech(on: true)))
                             physEvents.append((t + ms(int(3000...6000)), .speech(on: false))) }
            addKey(t + ms(hold), KeyCode.rightCommand, down: false)
            t += ms(hold + 500)
            end = t + ms(int(1500...3000))
        } else {
            end = t + ms(int(3000...8000))
        }
        while t < end - ms(300) {
            let start = t
            let len = episode(at: t)
            t = chance(0.2) ? start + ms(int(0...max(0, len))) : start + ms(len + int(0...400))
        }
        physEvents = physEvents.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        stalls.sort { $0.start < $1.start }
    }

    /// One episode starting at `t`; returns its length in ms.
    mutating func episode(at t: HostTime) -> Int {
        let r = int(0...99)
        switch r {
        case 0..<34: return passthroughHold(at: t, stall: false)
        case 34..<42:   // not a clean press
            let other = pick([KeyCode.shift, KeyCode.rightOption, KeyCode.command, KeyCode.control, 0x00, 0x08])
            addKey(t, other, down: true)
            let p = int(10...200), hold = int(100...1500)
            addKey(t + ms(p), KeyCode.rightCommand, down: true)
            addKey(t + ms(p + hold), KeyCode.rightCommand, down: false)
            addKey(t + ms(p + int(20...hold + 200)), other, down: false)
            return p + hold
        case 42..<57: return pushToTalk(at: t)
        case 57..<62:
            physEvents.append((t, .tapFail(pick([.disabledByTimeout, .disabledByUserInput, .notEnabled, .portInvalid]))))
            let d = int(20...500)
            physEvents.append((t + ms(d), .tapOK))
            return d
        case 62..<67:
            physEvents.append((t, .ctl(.system(pick(PassthroughSystemEvent.allCases)))))
            return 0
        case 67..<77:
            let f = pick(Self.toggleable)
            physEvents.append((t, .ctl(.fact(f, chance(0.5) ? .bad : .unknown))))
            let d = int(50...1500)
            physEvents.append((t + ms(d), .ctl(.fact(f, .good))))
            return d
        case 77..<82:
            if chance(0.3) {
                let d = int(100...1500)
                stalls.append((t, t + ms(d)))
                return d
            }
            return passthroughHold(at: t, stall: true)
        case 82..<84:
            physEvents.append((t, .ctl(.source(.selfTest))))
            physEvents.append((t + ms(50), .ctl(.selfTestOpen(ms: int(100...500)))))
            physEvents.append((t + ms(700), .ctl(.source(.mic))))
            return 700
        case 84..<92:
            let d = int(100...2000)
            physEvents.append((t, .speech(on: true)))
            physEvents.append((t + ms(d), .speech(on: false)))
            return d
        default:
            return int(0...600)
        }
    }

    mutating func passthroughHold(at t: HostTime, stall: Bool) -> Int {
        let src: KeyEventSource = chance(0.92) ? .hidSystem : .other
        addKey(t, KeyCode.rightCommand, down: true, source: src)
        let hold: Int = stall ? int(1500...4000)
            : pick([int(0...390), int(400...1500), int(400...1500), int(1500...4000)])
        if stall {
            let s = t + ms(int(450...1200))
            stalls.append((s, s + ms(int(100...1500))))
        } else if chance(0.4) {
            let o = int(0...max(0, hold))
            let at = t + ms(o)
            switch int(0...5) {
            case 0:
                let k = pick([UInt16(0x08), 0x09, 0x30, 0x31, 0x00])
                addKey(at, k, down: true)
                addKey(at + ms(int(30...120)), k, down: false)
            case 1:
                let k = pick([KeyCode.shift, KeyCode.rightShift, KeyCode.rightOption, KeyCode.option, KeyCode.control,
                              KeyCode.command, KeyCode.function, KeyCode.capsLock])
                addKey(at, k, down: true)
                addKey(at + ms(int(30...200)), k, down: false)
            case 2:
                physEvents.append((at, .mouseButton(down: true)))
                physEvents.append((at + ms(int(50...150)), .mouseButton(down: false)))
            case 3:
                physEvents.append((at, .scroll))
            case 4:   // big moves
                for j in 0..<int(1...4) { physEvents.append((at + ms(j * 15), .move(dx: Double(int(4...12)), dy: Double(int(0...8))))) }
            default:  // small moves, ≤ 9 pt in all
                for j in 0..<3 { physEvents.append((at + ms(j * 20), .move(dx: 1.5, dy: 2))) }
            }
        }
        if !stall && chance(0.3) {
            let o = chance(0.5) ? int(0...350) : int(420...1200)
            physEvents.append((t + ms(o), .speech(on: true)))
            physEvents.append((t + ms(o + int(100...1500)), .speech(on: false)))
        }
        if chance(0.1) { addKey(t + ms(int(0...max(0, hold))), KeyCode.rightCommand, down: true) }   // duplicate down
        if chance(0.1) {   // push-to-talk pressed during the hold
            let o = int(0...max(0, hold))
            addKey(t + ms(o), KeyCode.rightOption, down: true)
            addKey(t + ms(o + int(50...500)), KeyCode.rightOption, down: false)
        }
        addKey(t + ms(hold), KeyCode.rightCommand, down: false, lose: chance(0.1))
        return hold
    }

    mutating func pushToTalk(at t: HostTime) -> Int {
        if chance(0.2) {   // double tap
            let a = int(20...149), gap = int(50...350), b = int(20...149)
            addKey(t, KeyCode.rightOption, down: true)
            addKey(t + ms(a), KeyCode.rightOption, down: false)
            addKey(t + ms(a + gap), KeyCode.rightOption, down: true)
            addKey(t + ms(a + gap + b), KeyCode.rightOption, down: false)
            return a + gap + b
        }
        let hold = chance(0.3) ? int(20...149) : int(150...3000)
        addKey(t, KeyCode.rightOption, down: true)
        if chance(0.3) {
            let o = int(0...hold)
            addKey(t + ms(o), KeyCode.rightCommand, down: true)
            addKey(t + ms(o + int(50...1500)), KeyCode.rightCommand, down: false)
        }
        if chance(0.4) {
            let o = int(0...hold)
            physEvents.append((t + ms(o), .speech(on: true)))
            physEvents.append((t + ms(o + int(100...1500)), .speech(on: false)))
        }
        if hold > 1200 && chance(0.6) { physEvents.append((t + ms(int(1200...hold)), .commit)) }
        if chance(0.15) { addKey(t + ms(int(0...hold)), 0x08, down: true); addKey(t + ms(hold + 10), 0x08, down: false) }
        addKey(t + ms(hold), KeyCode.rightOption, down: false, lose: chance(0.1))
        return hold
    }

    // MARK: run

    /// Runs the seed; returns the oracle's complaints (empty = pass).
    mutating func run() -> [String] {
        generate()
        return simulate()
    }

    final class Env: @unchecked Sendable {
        var now: HostTime = 0
        var notices: [(HostTime, PassthroughNotice)] = []
        var pending: [(HostTime, Item)] = []
    }

    mutating func simulate() -> [String] {
        let env = Env()
        let playout = playoutMode == 0 ? nil : FakePlayout()
        let gate = PassthroughGate(config: .init(profile: pt), sink: InMemoryPassthroughStateSink(), playout: playout,
                                   onNotice: { n in env.notices.append((env.now, n)) })
        let mcfg = PassthroughKeyMachine.Config(profile: pt)!
        let ctl = PassthroughController(machine: PassthroughKeyMachine(config: mcfg), gate: gate)
        var ptt = PushToTalkMachine(config: .init(speak: speakProfile))
        let mode = playoutMode
        var answerRng = PTSplitMix64(seed: seed ^ 0xA5A5)
        playout?.onRequest = { req, cut in
            let d: Int?
            switch mode {
            case 1: d = 0
            case 2: d = Int.random(in: 0...1530, using: &answerRng)
            default: d = Int.random(in: 0...9, using: &answerRng) == 0 ? nil : Int.random(in: 0...1530, using: &answerRng)
            }
            if let d { env.pending.append((req + ms(d), .playoutAnswer)) }
            _ = cut
        }

        var heap = Heap()
        for e in physEvents { heap.push(e.t, .phys(e.p)) }

        // physical state
        var mods: Set<UInt16> = [], keys: Set<UInt16> = [], mouse = false, caps = false
        func flags() -> ModifierFlags {
            var f: ModifierFlags = caps ? .capsLock : []
            for m in mods { f.formUnion(Self.modifierBits[m] ?? []) }
            return f
        }
        var physLog: [PhysRecord] = []
        var keyLog: [KeyInputEvent] = []
        var ctlLog: [(t: HostTime, r: CtlRecord)] = []
        var speech: [SpeechSeg] = []
        var oracleFacts = initialFacts
        var tapHealthy = false
        var source: PassthroughSource = .mic
        var lastTapDelivery: HostTime = 0
        var lastVadDelivery: HostTime = 0
        var openInterval: Int?
        var pttOpenAt: HostTime?
        var lastPTTFact = false
        var physSpeechOnset: HostTime?

        let t0 = ms(500)
        env.now = t0
        oracleFacts.tapHealthy = true
        oracleFacts.pushToTalkActive = false
        oracleFacts.selfTestRunning = false
        let initial = oracleFacts
        gate.updateFacts(at: t0) { $0 = initial }
        gate.setMicWarm(micWarm)
        gate.setCueAudible(cueAudible)

        func keyThreadDelivery(_ t: HostTime) -> HostTime {
            var d = max(t + ms(Int.random(in: 0...20, using: &rng)), lastTapDelivery)
            for s in stalls where d >= s.start && d < s.end { d = s.end }
            lastTapDelivery = d
            return d
        }
        func inStall(_ t: HostTime) -> (start: HostTime, end: HostTime)? { stalls.first { t >= $0.start && t < $0.end } }

        func processNotices() {
            for (t, n) in env.notices {
                switch n {
                case let .opened(at, _, g):
                    intervals.append(Interval(open: at, close: nil, generation: g, selfTest: source == .selfTest,
                                              keyLogIndex: keyLog.count, ctlLogIndex: ctlLog.count, facts: oracleFacts,
                                              tapHealthy: tapHealthy, pttActive: ptt.isActive, source: source))
                    openInterval = intervals.count - 1
                case let .closed(at, reason, _):
                    if let i = openInterval { intervals[i].close = at; openInterval = nil }
                    closeReasons.insert(reason.tag)
                case .refused:
                    refusals += 1
                case .startMic:
                    heap.push(t + ms(Int.random(in: 30...150, using: &rng)), .micStarted)
                default: break
                }
            }
            env.notices.removeAll()
            for (t, item) in env.pending { heap.push(t, item) }
            env.pending.removeAll()
        }

        func deliverKey(_ e: KeyInputEvent, physIndex: Int? = nil) {
            env.now = e.time
            if let i = physIndex { physLog[i].keyLogIndex = keyLog.count }
            keyLog.append(e)
            for a in ptt.handle(e) {
                switch a {
                case let .began(at): pttOpenAt = at
                case let .released(at, _), let .cancelled(at), let .tapped(at), let .doubleTapped(at):
                    if let b = pttOpenAt { pttIntervals.append((b, at)) }
                    pttOpenAt = nil
                }
            }
            ctl.handle(e)
            // KeyTap reports tap health and PushToTalkKey its state to the policy after the machines ran
            if case .tapDisabled = e.kind { tapHealthy = false; gate.updateFacts(at: e.time) { $0.tapHealthy = false }; oracleFacts.tapHealthy = false }
            if case .tapEnabled = e.kind { tapHealthy = true; gate.updateFacts(at: e.time) { $0.tapHealthy = true }; oracleFacts.tapHealthy = true }
            if ptt.isActive != lastPTTFact {
                lastPTTFact = ptt.isActive
                let v = lastPTTFact
                oracleFacts.pushToTalkActive = v
                gate.updateFacts(at: e.time) { $0.pushToTalkActive = v }
                ctlLog.append((e.time, .facts(allGood: Self.allGood(oracleFacts))))
            }
            processNotices()
        }

        func applyCtl(_ c: Ctl, at t: HostTime) {
            env.now = t
            switch c {
            case let .fact(f, v):
                switch v {
                case .good: Self.restore(&oracleFacts, f)
                case .bad: set(&oracleFacts, f, unknown: false)
                case .unknown: set(&oracleFacts, f, unknown: true)
                }
                let snapshot = oracleFacts
                gate.updateFacts(at: t) { $0 = snapshot }
                ctlLog.append((t, .facts(allGood: Self.allGood(oracleFacts))))
            case let .system(e):
                gate.systemEvent(e, at: t)
                ctlLog.append((t, .closer))
            case let .speechOn(onset):
                speech.append(SpeechSeg(onset: onset, onsetReport: t, end: nil, endReport: nil, onsetLogIndex: ctlLog.count))
                ptt.vad(speech: true, at: t)
                gate.vadSpeechStarted(onset: onset, now: t)
                ctlLog.append((t, .lateOnset(onset: onset)))
            case let .speechOff(endT):
                if let i = speech.lastIndex(where: { $0.endReport == nil }) {
                    speech[i].end = endT; speech[i].endReport = t; speech[i].endLogIndex = ctlLog.count
                }
                ptt.vad(speech: false, at: t)
                gate.vadSpeechEnded(at: endT)
                ctlLog.append((t, .speechEnd))
            case let .source(s):
                // Only a switch between .mic and .selfTest closes (§3.8 规则 7); setting the source it
                // already has is a no-op (two overlapping self-test episodes both restore .mic).
                let switched = s != source
                source = s
                oracleFacts.selfTestRunning = s == .selfTest
                let v = s == .selfTest
                gate.setSource(s, at: t)
                gate.updateFacts(at: t) { $0.selfTestRunning = v }
                if switched { ctlLog.append((t, .closer)) }
                ctlLog.append((t, .facts(allGood: Self.allGood(oracleFacts))))
            case let .selfTestOpen(d):
                _ = gate.openSelfTest(at: t, durationMs: d)
            }
            processNotices()
        }

        // initial tap enable
        deliverKey(KeyInputEvent(time: t0, kind: .tapEnabled))

        var nextPoll = t0 + ms(pt.keyPollMs)
        var blockStart = ms(400)
        var lastBlockDelivery: HostTime = 0
        func nextBlock() -> (MicBlock, HostTime) {
            let frames = max(1, Int(rate * Double(Int.random(in: 1...20, using: &rng)) / 1000))
            let samples: [Float]
            if let s = sampleCache[frames] { samples = s } else {
                samples = [Float](repeating: 0.25, count: frames); sampleCache[frames] = samples
            }
            let b = MicBlock(origin: .mic, hostTime: blockStart, sampleRate: rate, samples: samples)
            let deliver = max(b.sampleTime(frames) + ms(Int.random(in: 0...10, using: &rng)), lastBlockDelivery)
            lastBlockDelivery = deliver
            blockStart = b.sampleTime(frames)
            return (b, deliver)
        }
        var pendingBlock = nextBlock()

        while true {
            let th = heap.peekTime ?? .max
            if pendingBlock.1 <= min(th, nextPoll), pendingBlock.1 < end {
                let (b, now) = pendingBlock
                env.now = now
                for block in source == .selfTest
                    ? [b, MicBlock(origin: .selfTest, hostTime: b.hostTime, sampleRate: b.sampleRate, samples: b.samples)] : [b] {
                    if let f = gate.admit(block, now: now) {
                        admits.append(Admit(generation: f.generation, source: f.source,
                                            first: block.sampleTime(f.blockRange.lowerBound),
                                            last: block.sampleTime(f.blockRange.upperBound - 1)))
                    }
                }
                processNotices()
                pendingBlock = nextBlock()
                continue
            }
            if nextPoll <= th, nextPoll < end {
                if let s = inStall(nextPoll) { nextPoll = s.end; continue }
                let needs = !mods.isEmpty || !keys.isEmpty || ctl.machine.phase != .idle || ptt.phase != .idle
                if needs {
                    let snap = KeyStateSnapshot(keysDown: mods.union(keys), flags: flags(), mouseButtonDown: mouse)
                    lastTapDelivery = max(lastTapDelivery, nextPoll)
                    deliverKey(KeyInputEvent(time: nextPoll, kind: .poll(snap)))
                }
                nextPoll += ms(pt.keyPollMs)
                continue
            }
            guard th < end, let popped = heap.pop() else { break }
            let (t, item) = popped
            env.now = t
            switch item {
            case let .phys(p):
                var rec = PhysRecord(t: t, phys: p, delivered: nil, cleanBefore: false, duplicate: false, happenedAt: keyLog.count)
                switch p {
                case let .key(code, down, src, lose):
                    let isMod = Self.modifierBits[code] != nil || code == KeyCode.capsLock
                    if code == KeyCode.rightCommand && down {
                        // keys and modifiers (§3.8 打开条件 1); a duplicate down's own key does not count
                        rec.cleanBefore = mods.subtracting([KeyCode.rightCommand]).isEmpty && keys.isEmpty
                    }
                    var kind: KeyInputEvent.Kind?
                    if isMod {
                        if code == KeyCode.capsLock {
                            if down { caps.toggle(); kind = .flagsChanged(keyCode: code, flags: flags()) }
                        } else if down {
                            rec.duplicate = mods.contains(code)
                            mods.insert(code)
                            kind = .flagsChanged(keyCode: code, flags: flags())
                        } else if mods.contains(code) {
                            mods.remove(code)
                            kind = .flagsChanged(keyCode: code, flags: flags())
                        }
                    } else if down {
                        rec.duplicate = keys.contains(code)
                        keys.insert(code)
                        kind = .keyDown(keyCode: code, isRepeat: rec.duplicate)
                    } else if keys.contains(code) {
                        keys.remove(code)
                        kind = .keyUp(keyCode: code)
                    }
                    rec.ignored = kind == nil
                    if let k = kind, !lose {
                        let d = keyThreadDelivery(t)
                        rec.delivered = d
                        heap.push(d, .tap(KeyInputEvent(time: d, kind: k, source: src), physIndex: physLog.count))
                    }
                case let .mouseButton(down):
                    mouse = down
                    if down {
                        let d = keyThreadDelivery(t); rec.delivered = d
                        heap.push(d, .tap(KeyInputEvent(time: d, kind: .mouseDown)))
                    }
                case .scroll:
                    let d = keyThreadDelivery(t); rec.delivered = d
                    heap.push(d, .tap(KeyInputEvent(time: d, kind: .scroll)))
                case let .move(dx, dy):
                    let d = keyThreadDelivery(t); rec.delivered = d
                    heap.push(d, .tap(KeyInputEvent(time: d, kind: .mouseMoved(dx: dx, dy: dy))))
                case let .tapFail(f):
                    let d = keyThreadDelivery(t); rec.delivered = d
                    heap.push(d, .tap(KeyInputEvent(time: d, kind: .tapDisabled(f))))
                case .tapOK:
                    let d = keyThreadDelivery(t); rec.delivered = d
                    heap.push(d, .tap(KeyInputEvent(time: d, kind: .tapEnabled)))
                case let .speech(on):
                    // one VAD, so its reports arrive in order
                    let d = max(t + ms(Int.random(in: 20...60, using: &rng)), lastVadDelivery)
                    lastVadDelivery = d
                    if on {
                        if physSpeechOnset == nil { physSpeechOnset = t; heap.push(d, .ctl(.speechOn(onset: t))) }
                    } else if physSpeechOnset != nil {
                        physSpeechOnset = nil
                        heap.push(d, .ctl(.speechOff(end: t)))
                    }
                case let .ctl(c):
                    heap.push(t + ms(Int.random(in: 0...20, using: &rng)), .ctl(c))
                case .commit:
                    ptt.didCommit()
                }
                physLog.append(rec)
            case let .tap(e, i):
                deliverKey(e, physIndex: i)
            case let .ctl(c):
                applyCtl(c, at: t)
            case .micStarted:
                gate.micStreamStarted(at: t)
                processNotices()
            case .playoutAnswer:
                gate.playoutYielded(at: t)
                processNotices()
            }
        }
        env.now = end
        gate.release(at: end, reason: .keyReleased)
        processNotices()
        if let b = pttOpenAt { pttIntervals.append((b, end)) }

        return verify(physLog: physLog, keyLog: keyLog, ctlLog: ctlLog, speech: speech)
    }

    // MARK: oracle

    static func allGood(_ f: PassthroughPolicy.Facts) -> Bool {
        f.meetingModeActive == true && f.settingEnabled == true && f.micGuard == .green && f.speakerMode == false
            && f.tapHealthy == true && f.awaitingAudioConfirmation == false && f.secureInput == false
            && f.pushToTalkActive == false && f.selfTestRunning == false && f.physicalMicPassesRule2 == true
    }

    static func restore(_ f: inout PassthroughPolicy.Facts, _ fact: PassthroughPolicy.Fact) {
        let g = PassthroughPolicy.Facts.allGood
        switch fact {
        case .meetingModeActive: f.meetingModeActive = g.meetingModeActive
        case .settingEnabled: f.settingEnabled = g.settingEnabled
        case .micGuard: f.micGuard = g.micGuard
        case .speakerMode: f.speakerMode = g.speakerMode
        case .tapHealthy: f.tapHealthy = g.tapHealthy
        case .awaitingAudioConfirmation: f.awaitingAudioConfirmation = g.awaitingAudioConfirmation
        case .secureInput: f.secureInput = g.secureInput
        case .pushToTalkActive: f.pushToTalkActive = g.pushToTalkActive
        case .selfTestRunning: f.selfTestRunning = g.selfTestRunning
        case .physicalMicPassesRule2: f.physicalMicPassesRule2 = g.physicalMicPassesRule2
        }
    }

    func verify(physLog: [PhysRecord], keyLog: [KeyInputEvent], ctlLog: [(t: HostTime, r: CtlRecord)],
                speech: [SpeechSeg]) -> [String] {
        var bad: [String] = []
        let arm = ms(pt.armHoldMs), maxHold = ms(pt.maxHoldS * 1000)
        let rc = ModifierKey.rightCommand
        var byGen: [UInt32: Interval] = [:]
        for i in intervals { byGen[i.generation] = i }

        for a in admits {
            guard let i = byGen[a.generation], let c = i.close else { bad.append("admit of unknown generation \(a.generation)"); continue }
            if a.first < i.open || a.last >= c { bad.append("admitted [\(a.first), \(a.last)] outside [\(i.open), \(c))") }
            if (a.source == .selfTest) != i.selfTest { bad.append("admit source \(a.source) in a \(i.selfTest ? "self-test" : "mic") interval") }
        }

        for i in intervals {
            guard let c = i.close else { bad.append("interval at \(i.open) never closed"); continue }
            if c < i.open || c - i.open > maxHold { bad.append("interval [\(i.open), \(c)) longer than maxHold") }
            if i.selfTest { if i.source != .selfTest { bad.append("self-test interval on .mic") }; continue }
            if i.source != .mic { bad.append("mic interval while source \(i.source)") }

            // The qualifying hold: the last right ⌘ down delivered before the open. A duplicate down
            // is a new press (a key-up was lost, PassthroughKeyMachine restarts the hold from it).
            // A release and re-press inside one delivery delay (≤ 20 ms, no poll between) is still
            // on its way at the open; nothing can know it yet, and its key-up closes when it arrives
            // (checked below).
            let seenByOpen = { (r: PhysRecord) -> Bool in r.keyLogIndex.map { $0 < i.keyLogIndex } ?? (r.happenedAt < i.keyLogIndex) }
            guard let pIdx = physLog.lastIndex(where: { r in
                if case let .key(code, down, _, _) = r.phys, code == KeyCode.rightCommand, down,
                   let k = r.keyLogIndex { return r.t <= i.open && k < i.keyLogIndex }
                return false
            }) else { bad.append("open at \(i.open) without a right ⌘ press"); continue }
            let p = physLog[pIdx]
            guard case let .key(_, _, src, _) = p.phys, let pDeliv = p.delivered, let pressIdx = p.keyLogIndex else {
                bad.append("open at \(i.open): its press was never delivered"); continue
            }
            var why: [String] = []
            // A lost key-up and a re-press inside one poll period, the re-press still in flight at
            // the open: the poll saw the key down and nothing could have known. Its duplicate down
            // must close the interval when it lands.
            var closeByInFlightRepress: HostTime?
            if src != .hidSystem { why.append("non-HID press") }
            if !p.cleanBefore { why.append("press not clean") }
            if i.open < p.t + arm { why.append("opened \(HostClock.ms(p.t, to: i.open)) ms after the press") }
            var moved = 0.0
            for r in physLog[(pIdx + 1)...] where r.t <= i.open && !r.ignored {
                switch r.phys {
                case let .key(code, down, _, _):
                    if code == KeyCode.rightCommand && !down {
                        let repress = r.keyLogIndex == nil ? physLog.first(where: { r2 in
                            if case let .key(c2, d2, _, _) = r2.phys, c2 == KeyCode.rightCommand, d2, r2.t >= r.t, r2.t <= i.open,
                               let k2 = r2.keyLogIndex, k2 >= i.keyLogIndex { return true }
                            return false
                        }) : nil
                        if let rp = repress, let d = rp.delivered { closeByInFlightRepress = min(closeByInFlightRepress ?? d, d) }
                        else if seenByOpen(r) { why.append("right ⌘ released at \(r.t) before the open") }
                    }
                    else if code != KeyCode.rightCommand && r.t <= p.t + arm { why.append("key \(code) inside the hold") }
                case .mouseButton(down: true), .scroll:
                    if r.t <= p.t + arm { why.append("mouse button/scroll inside the hold") }
                case let .move(dx, dy):
                    if r.t <= p.t + arm { moved += (dx * dx + dy * dy).squareRoot() }
                default: break
                }
            }
            if moved > Double(pt.mouseMoveMaxPt) { why.append("moved \(moved) pt inside the hold") }
            // nothing delivered between the press and the open but clean polls, small moves, duplicate downs
            var lastFlags: ModifierFlags = []
            var deliveredMoves = 0.0
            // A duplicate down restarts the hold (a key-up was lost): the press the machine counts,
            // and the one "speech between press and open" is measured from, is the last down delivered.
            var countedPress = pDeliv
            for e in keyLog[pressIdx..<i.keyLogIndex] {
                switch e.kind {
                case let .flagsChanged(code, f):
                    if !(code == KeyCode.rightCommand && rc.isSoleHeldModifier(in: f)) { why.append("flags change delivered at \(e.time)") }
                    else { countedPress = e.time }
                    lastFlags = f
                case .keyDown, .keyUp, .mouseDown, .scroll: why.append("input delivered at \(e.time) before the open")
                case let .mouseMoved(dx, dy): deliveredMoves += (dx * dx + dy * dy).squareRoot()
                case .tapDisabled: why.append("tap failed at \(e.time)")
                case let .poll(s): if !s.isSoleHeld(rc) { why.append("unclean poll at \(e.time)") }
                case .tapEnabled: break
                }
            }
            _ = lastFlags
            if deliveredMoves > Double(pt.mouseMoveMaxPt) { why.append("delivered moves \(deliveredMoves) pt") }
            if !Self.allGood(i.facts) { why.append("facts not all known and good: \(i.facts)") }
            if !i.tapHealthy { why.append("tap unhealthy") }
            if pttIntervals.contains(where: { $0.begin <= i.open && i.open < $0.end }) || i.pttActive { why.append("push-to-talk active") }
            for s in speech where s.onsetLogIndex < i.ctlLogIndex {
                let endKnown = s.endLogIndex.map { $0 < i.ctlLogIndex } ?? false
                if !endKnown || (s.end ?? .max) >= countedPress {
                    why.append("speech [\(s.onset), \(s.end.map(String.init) ?? "-")) reported at \(s.onsetReport)/\(s.endReport.map(String.init) ?? "-") known before the open (press \(countedPress))")
                }
            }
            if !why.isEmpty { bad.append("open at \(i.open): " + why.prefix(3).joined(separator: ", ")) }

            // closed in time
            var due = min(i.open + maxHold, closeByInFlightRepress ?? .max)
            var prevFlags = rcmdFlags
            for e in keyLog[i.keyLogIndex...] where e.time >= i.open {
                var closer = false
                switch e.kind {
                case let .flagsChanged(code, f):
                    closer = !(code == KeyCode.rightCommand && rc.isDown(in: f) && f.intersection(.held) == prevFlags.intersection(.held))
                    prevFlags = f
                case .keyDown, .keyUp, .mouseDown, .scroll, .tapDisabled: closer = true
                case let .poll(s): closer = !s.isSoleHeld(rc)
                case .mouseMoved, .tapEnabled: break
                }
                if closer { due = min(due, e.time); break }
            }
            for (t, r) in ctlLog[i.ctlLogIndex...] where t >= i.open {
                switch r {
                case .closer: due = min(due, t)
                case let .facts(good): if !good { due = min(due, t) }
                case let .lateOnset(onset): if onset < i.open { due = min(due, t) }
                case .speechEnd: break
                }
            }
            for s in stalls where s.start >= i.open { due = min(due, s.start + ms(130)) }
            if c > due { bad.append("interval [\(i.open), \(c)) closed \(HostClock.ms(due, to: c)) ms late") }
            for q in pttIntervals where q.begin < c && i.open < q.end {
                bad.append("push-to-talk [\(q.begin), \(q.end)) overlaps passthrough [\(i.open), \(c))")
            }
        }
        return bad
    }
}

/// Min-heap of timed items, FIFO among equal times.
struct Heap {
    private var a: [(t: HostTime, seq: Int, item: FuzzSim.Item)] = []
    private var seq = 0
    var peekTime: HostTime? { a.first?.t }
    private func less(_ i: Int, _ j: Int) -> Bool { a[i].t != a[j].t ? a[i].t < a[j].t : a[i].seq < a[j].seq }
    mutating func push(_ t: HostTime, _ item: FuzzSim.Item) {
        seq += 1
        a.append((t, seq, item))
        var i = a.count - 1
        while i > 0 { let p = (i - 1) / 2; if less(i, p) { a.swapAt(i, p); i = p } else { break } }
    }
    mutating func pop() -> (HostTime, FuzzSim.Item)? {
        guard !a.isEmpty else { return nil }
        a.swapAt(0, a.count - 1)
        let top = a.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < a.count && less(l, m) { m = l }
            if r < a.count && less(r, m) { m = r }
            if m == i { break }
            a.swapAt(i, m); i = m
        }
        return (top.t, top.item)
    }
}
