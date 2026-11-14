import Darwin
import Foundation
import TalkTalkCore

/// One row of a self-test report. `ok == nil` means skipped (e.g. no ASR role on compact16).
public struct SelfTestCheck: Codable, Sendable, Equatable {
    public let name: String
    public let ok: Bool?
    public let detail: String?
    public let values: [String: Double]

    public init(_ name: String, ok: Bool?, detail: String? = nil, values: [String: Double] = [:]) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.values = values
    }
}

/// `--self-test` output: one JSON line (§12.3). Never contains audio, transcripts of the user, paths or keys.
public struct SelfTestReport: Codable, Sendable, Equatable {
    public var suite: String
    public var checks: [SelfTestCheck]
    public var ok: Bool { checks.contains { $0.ok == true } && checks.allSatisfy { $0.ok != false } }

    public init(suite: String, checks: [SelfTestCheck] = []) {
        self.suite = suite
        self.checks = checks
    }

    enum CodingKeys: String, CodingKey { case suite, checks, ok }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suite = try c.decode(String.self, forKey: .suite)
        checks = try c.decode([SelfTestCheck].self, forKey: .checks)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(suite, forKey: .suite)
        try c.encode(checks, forKey: .checks)
        try c.encode(ok, forKey: .ok)
    }

    public func jsonLine() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? e.encode(self)) ?? Data(#"{"ok":false,"suite":"encode-failed","checks":[]}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// CER / WER the way smoke_engine.py and the bench compute them.
public enum TextMetrics {
    /// Characters after NFKC, without punctuation (P*) and separators (Z*).
    public static func cerUnits(_ s: String) -> [Character] {
        s.precomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !isPunctOrSpace($0) }
            .map { Character($0) }
    }

    /// Lowercased words after NFKC; punctuation is dropped, apostrophes inside words kept.
    public static func werUnits(_ s: String) -> [String] {
        let t = s.precomposedStringWithCompatibilityMapping.lowercased()
        var words: [String] = [], cur = ""
        for u in t.unicodeScalars {
            if u.properties.generalCategory == .spaceSeparator || u == "\n" || u == "\t" {
                if !cur.isEmpty { words.append(cur); cur = "" }
            } else if u == "'" || u == "’" || !isPunctOrSpace(u) {
                cur.unicodeScalars.append(u)
            } else if !cur.isEmpty {
                // punctuation ends nothing by itself ("well," -> "well"); hyphens join
                if u == "-" { cur.unicodeScalars.append(u) }
            }
        }
        if !cur.isEmpty { words.append(cur) }
        return words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’-")) }.filter { !$0.isEmpty }
    }

    public static func cer(reference: String, hypothesis: String) -> Double {
        let r = cerUnits(reference)
        return Double(distance(r, cerUnits(hypothesis))) / Double(max(1, r.count))
    }

    public static func wer(reference: String, hypothesis: String) -> Double {
        let r = werUnits(reference)
        return Double(distance(r, werUnits(hypothesis))) / Double(max(1, r.count))
    }

    static func isPunctOrSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .spaceSeparator, .lineSeparator, .paragraphSeparator:
            true
        default:
            u == "\n" || u == "\t" || u == "\r"
        }
    }

    static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        var d = Array(0...b.count)
        for i in 1...a.count {
            var prev = d[0]
            d[0] = i
            if b.isEmpty { continue }
            for j in 1...b.count {
                let cur = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return d[b.count]
    }
}

/// §7.3 smoke step 6 / §12.3: the engine has exactly one listening socket, `127.0.0.1:<port>`,
/// and every other inet socket is a loopback connection (no outbound connection, no IPv6, no UDP).
public enum SocketAudit {
    public struct Socket: Sendable, Equatable {
        public let name: String
        public let state: String?
        public let proto: String?
    }

    /// Parses `lsof -nP -a -i -p <pid> -F nPT` (field output: `f<fd>`, `P<proto>`, `n<name>`, `TST=<state>`).
    public static func parse(_ output: String) -> [Socket] {
        var out: [Socket] = []
        var name: String?, state: String?, proto: String?
        func flush() {
            if let n = name { out.append(Socket(name: n, state: state, proto: proto)) }
            name = nil; state = nil; proto = nil
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "f": flush()
            case "p": flush()
            case "n": name = value
            case "P": proto = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return out
    }

    public static func problems(_ sockets: [Socket], port: Int) -> [String] {
        var bad: [String] = []
        let listening = sockets.filter { $0.state == "LISTEN" }
        if listening.map(\.name) != ["127.0.0.1:\(port)"] {
            bad.append("listening: " + (listening.isEmpty ? "none" : listening.map(\.name).joined(separator: " ")))
        }
        for s in sockets where s.state != "LISTEN" {
            let ends = s.name.components(separatedBy: "->")
            let loopback = ends.count == 2 && ends.allSatisfy { $0.hasPrefix("127.0.0.1:") }
            if !loopback || s.proto != "TCP" { bad.append("socket: \(s.proto ?? "?") \(s.name)") }
        }
        return bad
    }

    /// Runs `/usr/sbin/lsof` (read-only). nil if it could not be run.
    public static func current(pid: Int32) -> [Socket]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-a", "-i", "-p", String(pid), "-F", "nPT"]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // lsof exits 1 when it finds nothing; that is a valid (empty) answer.
        return parse(String(decoding: data, as: UTF8.self))
    }
}

/// `TalkTalk --self-test --engine` (§12.3): install.json and pins; READY with the installed models
/// and API 2; the engine PID is not a Core Audio process object; only the one loopback listener;
/// ASR CER on the `say` sample; en/de TTS with "my voice" (else the synthetic reference): duration
/// sanity, RTF, and a Qwen3-ASR read-back WER. Audio inputs are passed in so this module stays free
/// of audio-file and resampling code.
public struct EngineSelfTest: Sendable {
    public struct Sample: Sendable {
        public let samples: [Float]
        public let text: String
        public init(samples: [Float], text: String) {
            self.samples = samples
            self.text = text
        }
    }

    /// The thresholds (§7.3 smoke, §9.5 audition sanity).
    public struct Limits: Sendable {
        public var asrCER = 0.15
        public var durationRatio = 0.7...1.4
        public var readbackWER = 0.15
        public var asrReadyTimeout: Duration = .seconds(180)
        public var voiceReadyTimeout: Duration = .seconds(60)
        public init() {}
    }

    public static let sentences: [(lang: String, text: String)] = [
        ("en", "Thanks, everyone. Let me quickly walk you through where the project stands today."),
        ("de", "Danke Ihnen allen. Ich gebe Ihnen kurz einen Überblick über den aktuellen Stand des Projekts."),
    ]

    public var install: EngineInstallation.State
    public var engine: EngineProcess
    /// 16 kHz Chinese sample with its text (`warmup/sample-zh.*`).
    public var asrSample: Sample?
    /// 24 kHz reference and its text: "my voice", else `warmup/ref-zh.*`.
    public var reference: Sample?
    public var referenceSource: String
    /// nil when the process list could not be read.
    public var isAudioProcess: @Sendable (Int32) -> Bool?
    public var sockets: @Sendable (Int32) -> [SocketAudit.Socket]?
    public var to16k: @Sendable ([Float]) -> [Float]
    public var limits = Limits()

    public init(install: EngineInstallation.State, engine: EngineProcess, asrSample: Sample?, reference: Sample?,
                referenceSource: String, isAudioProcess: @escaping @Sendable (Int32) -> Bool?,
                sockets: @escaping @Sendable (Int32) -> [SocketAudit.Socket]? = SocketAudit.current,
                to16k: @escaping @Sendable ([Float]) -> [Float]) {
        self.install = install
        self.engine = engine
        self.asrSample = asrSample
        self.reference = reference
        self.referenceSource = referenceSource
        self.isAudioProcess = isAudioProcess
        self.sockets = sockets
        self.to16k = to16k
    }

    /// Runs every check; stops the engine at the end.
    public func run() async -> SelfTestReport {
        var report = SelfTestReport(suite: "engine")
        func add(_ c: SelfTestCheck) { report.checks.append(c) }

        guard install.canStartEngine else {
            add(SelfTestCheck("install", ok: false, detail: String(describing: install)))
            return report
        }
        add(SelfTestCheck("install", ok: true, detail: String(describing: install)))

        let t0 = ContinuousClock.now
        let ready: ReadyInfo
        do {
            ready = try await engine.start()
        } catch {
            add(SelfTestCheck("ready", ok: false, detail: String(describing: error)))
            await engine.stop()
            return report
        }
        let models = ready.models.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.id)@\($0.value.rev.prefix(12))" }
        add(SelfTestCheck("ready", ok: ready.api == EnginePins.engineAPI,
                          detail: "api \(ready.api); " + models.joined(separator: " "),
                          values: ["ready_s": Self.round((ContinuousClock.now - t0).seconds, 2)]))
        guard let client = await engine.client else {
            add(SelfTestCheck("client", ok: false, detail: "no client after READY"))
            await engine.stop()
            return report
        }

        switch isAudioProcess(ready.pid) {
        case .some(false): add(SelfTestCheck("not_audio_process", ok: true))
        case .some(true): add(SelfTestCheck("not_audio_process", ok: false, detail: "engine pid is a Core Audio process object"))
        case .none: add(SelfTestCheck("not_audio_process", ok: false, detail: "process list unavailable"))
        }

        if let s = sockets(ready.pid) {
            let bad = SocketAudit.problems(s, port: ready.port)
            add(SelfTestCheck("sockets", ok: bad.isEmpty, detail: bad.isEmpty ? "only 127.0.0.1:\(ready.port)" : bad.joined(separator: "; ")))
        } else {
            add(SelfTestCheck("sockets", ok: false, detail: "lsof could not be run"))
        }

        let hasASR = engine.config.roles.contains("asr") && ready.models["asr"] != nil
        var asrReady = false
        if hasASR {
            asrReady = await waitFor(client, limits.asrReadyTimeout) { $0.models["asr"]?.state == "ready" }
            if !asrReady {
                add(SelfTestCheck("asr", ok: false, detail: "ASR model not ready"))
            } else if let sample = asrSample {
                do {
                    let t = ContinuousClock.now
                    let r = try await client.asr(samples16k: sample.samples, hint: "zh", priority: 1)
                    let cer = TextMetrics.cer(reference: sample.text, hypothesis: r.text)
                    add(SelfTestCheck("asr", ok: cer <= limits.asrCER, detail: cer <= limits.asrCER ? nil : "CER above \(limits.asrCER)",
                                      values: ["cer": Self.round(cer, 3), "ms": Self.round((ContinuousClock.now - t).seconds * 1000, 1)]))
                } catch {
                    add(SelfTestCheck("asr", ok: false, detail: String(describing: error)))
                }
            } else {
                add(SelfTestCheck("asr", ok: false, detail: "warmup sample missing"))
            }
        } else {
            add(SelfTestCheck("asr", ok: nil, detail: "no ASR role in this profile"))
        }

        if !engine.config.roles.contains("tts") {
            add(SelfTestCheck("voice", ok: nil, detail: "no TTS role in this installation"))
        } else if let ref = reference {
            do {
                let client = try await engine.readyTTSClient()
                let built = try await client.buildVoice(reference24k: ref.samples, refText: ref.text, model: engine.config.tts)
                try await client.loadVoice(blob: built.blob, model: engine.config.tts)
                let ok = await waitFor(client, limits.voiceReadyTimeout) { $0.voice.state == "ready" }
                add(SelfTestCheck("voice", ok: ok, detail: referenceSource + (ok ? "" : ": voice did not become ready")))
                if ok {
                    for (lang, text) in Self.sentences {
                        await tts(client, lang: lang, text: text, readback: hasASR && asrReady, add: add)
                    }
                }
            } catch {
                add(SelfTestCheck("voice", ok: false, detail: "\(referenceSource): \(error)"))
            }
        } else {
            add(SelfTestCheck("voice", ok: false, detail: "no reference (warmup files missing)"))
        }

        let s = ContinuousClock.now
        await engine.stop()
        add(SelfTestCheck("stop", ok: true, values: ["ms": Self.round((ContinuousClock.now - s).seconds * 1000, 0)]))
        return report
    }

    func tts(_ client: EngineClient, lang: String, text: String, readback: Bool, add: (SelfTestCheck) -> Void) async {
        do {
            let started = ContinuousClock.now
            let stream = client.tts(EngineTTSRequest(text: text, lang: lang, seed: 0))
            let r = try await stream.collect(started: started)
            if let f = r.failure {
                add(SelfTestCheck("tts_\(lang)", ok: false, detail: f))
                return
            }
            let expected = r.tail?.expectedS ?? Self.expectedSeconds(text, lang: lang)
            let ratio = r.audioSeconds / max(1e-6, expected)
            let runaway = r.tail?.runaway == true
            let ok = limits.durationRatio.contains(ratio) && !runaway
            var v = ["audio_s": Self.round(r.audioSeconds, 2), "ratio": Self.round(ratio, 2)]
            if let rtf = r.rtf { v["rtf"] = Self.round(rtf, 3) }
            if let f = r.firstAudibleMs { v["ttfa_ms"] = Self.round(f, 0) }
            add(SelfTestCheck("tts_\(lang)", ok: ok,
                              detail: ok ? nil : (runaway ? "runaway" : "duration ratio outside \(limits.durationRatio)"), values: v))
            guard readback else {
                add(SelfTestCheck("readback_\(lang)", ok: nil, detail: "no ASR role"))
                return
            }
            let a = try await client.asr(samples16k: to16k(r.samples), hint: lang, priority: 1)
            let wer = TextMetrics.wer(reference: text, hypothesis: a.text)
            add(SelfTestCheck("readback_\(lang)", ok: wer <= limits.readbackWER,
                              detail: wer <= limits.readbackWER ? nil : "WER above \(limits.readbackWER)",
                              values: ["wer": Self.round(wer, 3)]))
        } catch {
            add(SelfTestCheck("tts_\(lang)", ok: false, detail: String(describing: error)))
        }
    }

    func waitFor(_ client: EngineClient, _ timeout: Duration, _ cond: (EngineHealth) -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if let h = try? await client.health(timeout: 2), cond(h) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// talktalk_engine/tts.py `expected_seconds` (used when the tail does not carry `expected_s`).
    public static func expectedSeconds(_ text: String, lang: String) -> Double {
        let words = max(1, text.split(whereSeparator: \.isWhitespace).count)
        return lang == "en" ? 0.391 + 0.340 * Double(words) : 0.134 + 0.430 * Double(words)
    }

    static func round(_ x: Double, _ digits: Int) -> Double {
        let p = pow(10.0, Double(digits))
        return (x * p).rounded() / p
    }
}
