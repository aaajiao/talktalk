@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import TalkTalkCore

/// T10 (ARCHITECTURE.md) with Apple SpeechAnalyzer / SpeechTranscriber, configured as LISTEN
/// uses it (`.volatileResults + .fastResults`, `.processLifetime`, prepareToAnalyze,
/// 16 kHz Int16 mono).
///
/// ④ finalizeToFinal: `say`-synthesized en-US / de-DE sentences are fed to one long-lived
/// analyzer per language in real time (20 ms buffers paced by the clock, then silence), the §5.1
/// rules (FinalizeTrigger) decide the finalize trigger, and the bench measures from the
/// `finalize(through:)` call to the final result. Deviation from the T10 text: the audio is fed
/// directly instead of being played with `afplay` and captured with a process tap; the capture
/// path is measured separately (T9).
/// With a `load` (the engine synthesizing without pause, TalkTalkApp's EngineTTSLoad), ④ runs
/// half its sentences under MLX load, alternating in blocks (T10Analysis.loaded).
/// ② presses: N consecutive zh-CN "key presses", each new analyzer first `cancelAndFinishNow`s the
/// previous one (under the load when given); errors (insufficientResources) and setup/cancel times
/// are recorded.
/// ① soak: a zh-CN and an en-US analyzer fed at once, in real time, on one clock, for
/// `soakMinutes` (with the load on when given). Each chunk's hand-over time goes into a feed table;
/// a sentence's lag is the first result holding its last word minus the hand-over time of the chunk
/// holding that result's own word end (T10Analysis.clipLags), bucketed by T10Analysis.LagDrift.
public struct SpeechBench: Sendable {
    public struct Options: Sendable {
        public var parts: [String] = ["finalize"]
        public var sentencesPerVoice = 50
        public var presses = 200
        public var tailSilenceMs = 4000
        /// ①: feed time, and the lag bucket / baseline window / statistic (rule C5, §14 T10 ①;
        /// shorter buckets for a smoke run).
        public var soakMinutes = 60.0
        public var lagBucketS = 600.0
        public var lagBaselineBuckets = 1
        public var lagStat = T10Analysis.LagDrift.Stat.p90
        /// ①: extra silence between sentences, uniform 0…this (seeded), to break the grid phase lock.
        public var soakJitterMs = 940
        /// ④: sentences per loaded / idle block.
        public var loadBlock = 10
        /// startup: fresh analyzers per language and case.
        public var startupReps = 3
        public init() {}
    }

    public let options: Options
    public let finalize: PolicyProfile.Listen.Finalize
    public let corpus: [Lang: [String]]
    public let zhSentences: [String]
    public let records: JSONLWriter
    public let load: (any BenchLoad)?
    /// Where the `say` audio goes while the run lasts (removed afterwards); nil: the temp dir.
    public let audioDir: URL?

    public init(options: Options, finalize: PolicyProfile.Listen.Finalize, corpus: [Lang: [String]], zhSentences: [String],
                records: JSONLWriter, load: (any BenchLoad)? = nil, audioDir: URL? = nil) {
        self.options = options; self.finalize = finalize; self.corpus = corpus; self.zhSentences = zhSentences; self.records = records
        self.load = load; self.audioDir = audioDir
    }

    static let voices: [Lang: [String]] = [
        .en: ["Samantha (Enhanced)", "Ava (Premium)"],
        .de: ["Anna (German (Germany))", "Flo (German (Germany))"],
    ]
    static let zhVoice = "Eddy (Chinese (China mainland))"
    static let localeID = Dictionary(uniqueKeysWithValues: Lang.allCases.map { ($0, AppleSpeechASR.localeIdentifier($0)) })
    static let sampleRate = 16_000.0
    static let chunkFrames = 320   // 20 ms

    public func run() async -> [String: Any] {
        var out: [String: Any] = ["op": "bench-speech", "parts": options.parts]
        out["speech_auth"] = await Self.authorize()
        out["transcriber_available"] = SpeechTranscriber.isAvailable
        // Keep App Nap and timer coalescing off the real-time feed for the whole run.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "T10 speech bench")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let tmp = (audioDir ?? FileManager.default.temporaryDirectory).appendingPathComponent("talktalk-t10-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if options.parts.contains("finalize") {
            var langs: [String: Any] = [:]
            for lang in [Lang.en, .de] { langs[Self.localeID[lang]!] = await finalizeRun(lang, tmp: tmp) }
            out["finalize_to_final"] = langs
        }
        if options.parts.contains("presses") {
            out["presses"] = await pressesRun(tmp: tmp)
        }
        if options.parts.contains("startup") {
            out["startup"] = await startupRun(tmp: tmp)
        }
        if options.parts.contains("soak") {
            out["soak"] = await soakRun(tmp: tmp)
        }
        if let load {
            await load.setActive(false)
            out["mlx_load"] = await load.summary()
        }
        return out
    }

    static func authorize() async -> String {
        let s: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            if SFSpeechRecognizer.authorizationStatus() != .notDetermined { c.resume(returning: SFSpeechRecognizer.authorizationStatus()); return }
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func makeTranscriber(_ lang: Lang) -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: localeID[lang]!), transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }

    /// Installs the locale's assets when needed; returns a description for the summary.
    static func ensureAssets(_ t: SpeechTranscriber) async -> [String: Any] {
        var r: [String: Any] = [:]
        let before = await AssetInventory.status(forModules: [t])
        r["status_before"] = "\(before)"
        if before != .installed {
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                    try await req.downloadAndInstall()
                    r["installed_now"] = true
                }
            } catch { r["install_error"] = "\(error)" }
            r["status_after"] = "\(await AssetInventory.status(forModules: [t]))"
        }
        return r
    }

    // MARK: audio

    struct Clip {
        var chunks: [AVAudioPCMBuffer]
        var voiced: [Bool]
        var speechStartChunk: Int
        var speechEndChunk: Int
    }

    static let int16Mono = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    /// Loads a 16 kHz Int16 WAV, converts to `format`, cuts 20 ms chunks and marks voiced chunks.
    static func load(_ url: URL, format: AVAudioFormat) throws -> Clip {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(file.length)
        let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
        try file.read(into: src)
        let samples = UnsafeBufferPointer(start: src.floatChannelData![0], count: Int(src.frameLength))
        var voiced: [Bool] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + chunkFrames)
            var e: Float = 0
            for k in i..<end { e += samples[k] * samples[k] }
            voiced.append((e / Float(end - i)).squareRoot() > 0.004)   // about -48 dBFS
            i = end
        }
        let converted = try convert(src, to: format)
        var chunks: [AVAudioPCMBuffer] = []
        var start = 0
        while start < Int(converted.frameLength) {
            let len = min(chunkFrames, Int(converted.frameLength) - start)
            chunks.append(slice(converted, start, len))
            start += len
        }
        let first = voiced.firstIndex(of: true) ?? 0
        let last = voiced.lastIndex(of: true) ?? max(0, voiced.count - 1)
        return Clip(chunks: chunks, voiced: Array(voiced.prefix(chunks.count)), speechStartChunk: first, speechEndChunk: last)
    }

    static func convert(_ b: AVAudioPCMBuffer, to f: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if b.format == f { return b }
        guard let conv = AVAudioConverter(from: b.format, to: f) else { throw NSError(domain: "convert", code: 1) }
        let cap = AVAudioFrameCount(Double(b.frameLength) * f.sampleRate / b.format.sampleRate) + 1024
        let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: cap)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return b
        }
        if let err { throw err }
        return out
    }

    /// Always a full 20 ms chunk: a short last piece is padded with zeros, as a microphone gives
    /// fixed-size buffers, so audio time and the 20 ms wall pacing stay in step (a short chunk on a
    /// full beat made the feed 0.2 % slower than real time in the fourth smoke).
    static func slice(_ b: AVAudioPCMBuffer, _ start: Int, _ len: Int) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(chunkFrames))!
        out.frameLength = AVAudioFrameCount(chunkFrames)
        let bpf = Int(b.format.streamDescription.pointee.mBytesPerFrame)
        let srcList = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(srcList, dstList) {
            memset(d.mData!, 0, chunkFrames * bpf)
            memcpy(d.mData!, s.mData!.advanced(by: start * bpf), len * bpf)
        }
        return out
    }

    static func silence(_ f: AVAudioFormat) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(chunkFrames))!
        b.frameLength = AVAudioFrameCount(chunkFrames)
        for d in UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList) { memset(d.mData!, 0, Int(d.mDataByteSize)) }
        return b
    }

    // MARK: result stream state

    final class Hyp: @unchecked Sendable {
        struct Final { var text: String; var arrival: ContinuousClock.Instant; var endS: Double }
        private let lock = NSLock()
        private var volatile = "", prevVolatile = ""
        private var finals: [Final] = []
        private var clipFinals: [Final] = []
        private var clipStartS = 0.0
        private var sentenceStartS = 0.0
        private var firstVolatile: ContinuousClock.Instant?
        /// First result in the clip holding a word that ends after the clip start: arrival, word end.
        private var firstWord: (arrival: ContinuousClock.Instant, endS: Double)?
        private var error: String?
        private var insufficient = false
        /// Results ending with sentence punctuation (§5.1 punctPause / asrFinal rule check; counts only).
        private var punct = (volatile: 0, volatileTotal: 0, final: 0, finalTotal: 0)

        /// A new clip (sentence audio).
        func begin(atS s: Double) {
            lock.withLock { volatile = ""; prevVolatile = ""; finals = []; clipFinals = []; clipStartS = s; sentenceStartS = s; firstVolatile = nil; firstWord = nil }
        }
        /// A new segment inside the clip: the previous one was finalized; more speech follows.
        func newSegment(atS s: Double) { lock.withLock { volatile = ""; prevVolatile = ""; finals = []; sentenceStartS = s } }
        var clipText: String { lock.withLock { (clipFinals.map(\.text) + [volatile]).filter { !$0.isEmpty }.joined(separator: " ") } }
        func add(_ text: String, final: Bool, endS: Double, wordEnds: [Double] = []) {
            lock.withLock {
                if firstWord == nil, let w = wordEnds.first(where: { $0 > clipStartS }) { firstWord = (.now, w) }
                if !text.isEmpty {
                    let p = FinalizeTrigger.endsWithSentencePunct(text) ? 1 : 0
                    if final { punct.final += p; punct.finalTotal += 1 } else { punct.volatile += p; punct.volatileTotal += 1 }
                }
                if final, endS > clipStartS { clipFinals.append(Final(text: text, arrival: .now, endS: endS)) }
                guard endS > sentenceStartS else { return }
                if final {
                    finals.append(Final(text: text, arrival: .now, endS: endS)); volatile = ""; prevVolatile = ""
                } else {
                    prevVolatile = volatile; volatile = text
                    if firstVolatile == nil, !text.isEmpty { firstVolatile = .now }
                }
            }
        }
        func fail(_ e: Error) {
            lock.withLock { error = "\(e)"; if SpeechBench.isInsufficientResources(e) { insufficient = true } }
        }
        var insufficientResources: Bool { lock.withLock { insufficient } }
        var firstWordSeen: (arrival: ContinuousClock.Instant, endS: Double)? { lock.withLock { firstWord } }
        var punctuation: [String: Int] {
            lock.withLock { ["volatile_punct": punct.volatile, "volatile_total": punct.volatileTotal,
                             "final_punct": punct.final, "final_total": punct.finalTotal] }
        }
        var snapshot: (finalText: String, volatile: String, prev: String, finals: [Final], firstVolatile: ContinuousClock.Instant?, error: String?) {
            lock.withLock { (finals.map(\.text).joined(separator: " "), volatile, prevVolatile, finals, firstVolatile, error) }
        }
    }

    static func listen(_ t: SpeechTranscriber, _ hyp: Hyp) -> Task<Void, Never> {
        let results = t.results
        return Task {
            do {
                for try await r in results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespaces)
                    var ends: [Double] = []
                    for run in r.text.runs {
                        if let range = run.audioTimeRange, T10Analysis.isWord(String(r.text[run.range].characters)) { ends.append(range.end.seconds) }
                    }
                    hyp.add(text, final: r.isFinal, endS: r.range.end.seconds, wordEnds: ends)
                }
            } catch is CancellationError {
            } catch { hyp.fail(error) }
        }
    }

    // MARK: ④ finalizeToFinal

    func finalizeRun(_ lang: Lang, tmp: URL) async -> [String: Any] {
        var out: [String: Any] = [:]
        let transcriber = Self.makeTranscriber(lang)
        out["assets"] = await Self.ensureAssets(transcriber)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: Self.int16Mono) else {
            out["error"] = "no compatible audio format"; return out
        }
        out["format"] = "\(format.commonFormat.rawValue)@\(Int(format.sampleRate))x\(format.channelCount)"
        var rows: [[String: Any]] = []
        var pendingCalls: [(row: Int, box: Box<(done: Bool, ms: Int?, error: String?)>)] = []
        var clips: [[String: Any]] = []
        let sentences = corpus[lang] ?? []
        // Render every clip before streaming, so `say` never stalls the real-time feed (retry once).
        var items: [(idx: Int, voice: String, text: String, clip: Clip)] = []
        var renderFailures = 0
        var n = 0
        for voice in Self.voices[lang] ?? [] {
            for text in sentences.prefix(options.sentencesPerVoice) {
                n += 1
                let wav = tmp.appendingPathComponent("\(lang.rawValue)-\(n).wav")
                var clip: Clip?
                for _ in 0..<2 where clip == nil {
                    if (try? SaySynth.render(text, voice: voice, to: wav)) != nil { clip = try? Self.load(wav, format: format) }
                }
                try? FileManager.default.removeItem(at: wav)
                if let clip { items.append((n, voice, text, clip)) } else { renderFailures += 1 }
            }
        }
        out["render_failures"] = renderFailures
        // Rendered with the rest before the analyzer starts: the M0 bench rendered after start, so
        // the analyzer saw 1 s of silence, then no input for the whole render (seconds), and the
        // first sentence after that stall was lost in both smoke runs (2026-11-05). The product
        // feeds the tap's audio without a gap. `--part startup` checks the three cases.
        var warmClip: (text: String, clip: Clip)?
        if let w = sentences.last, let voice = Self.voices[lang]?.first {
            let wav = tmp.appendingPathComponent("\(lang.rawValue)-warmup.wav")
            if (try? SaySynth.render(w, voice: voice, to: wav)) != nil, let clip = try? Self.load(wav, format: format) { warmClip = (w, clip) }
            try? FileManager.default.removeItem(at: wav)
        }
        // As AppleSpeechASR opens it for LISTEN (en-US / de-DE): .medium.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .medium, modelRetention: .processLifetime))
        do { try await analyzer.prepareToAnalyze(in: format) } catch { out["error"] = "prepare: \(error)"; return out }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        do { try await analyzer.start(inputSequence: stream) } catch { out["error"] = "start: \(error)"; return out }
        let hyp = Hyp()
        let listener = Self.listen(transcriber, hyp)

        let sr = format.sampleRate
        var fed: Int64 = 0
        let silenceBuf = Self.silence(format)
        var clock = ContinuousClock.now
        let wall0 = clock
        func wallS(_ t: ContinuousClock.Instant) -> Double { (t - wall0) / .seconds(1) }
        var feeds = T10Analysis.FeedTable()
        var lastVoicedEndS = 0.0          // audio end of the last voiced chunk fed
        var lastLoadSwitch: ContinuousClock.Instant?
        func push(_ b: AVAudioPCMBuffer) async {
            feeds.append(audio: Double(fed) / sr, wall: wallS(.now))
            input.yield(AnalyzerInput(buffer: b, bufferStartTime: CMTime(value: fed, timescale: CMTimeScale(sr))))
            fed += Int64(b.frameLength)
            clock = clock.advanced(by: .milliseconds(20))
            try? await Task.sleep(until: clock, clock: .continuous)
        }
        // A second of silence to settle.
        for _ in 0..<50 { await push(silenceBuf) }

        // The first sentence after start, reported on its own and not counted below.
        if let (w, clip) = warmClip {
            let warmBeginS = Double(fed) / sr
            defer { lastVoicedEndS = warmBeginS + Double((clip.speechEndChunk + 1) * Self.chunkFrames) / sr }
            hyp.begin(atS: warmBeginS)
            var firstText: Int?
            let t0 = ContinuousClock.now
            for ch in clip.chunks + Array(repeating: silenceBuf, count: 150) {
                await push(ch)
                if firstText == nil, !hyp.clipText.isEmpty { firstText = Int((ContinuousClock.now - t0) / .milliseconds(1)) }
            }
            var warm: [String: Any] = [:]
            warm["ref_units"] = T10Analysis.textUnits(w)
            warm["units"] = T10Analysis.textUnits(hyp.clipText)
            warm["first_text_ms"] = firstText ?? NSNull()
            warm["speech_ms"] = (clip.speechEndChunk - clip.speechStartChunk + 1) * 20
            out["warmup"] = warm
        }
        for (k, item) in items.enumerated() {
            do {
                let idx = item.idx, voice = item.voice, text = item.text, clip = item.clip
                let loaded = load != nil && T10Analysis.loaded(item: k, block: options.loadBlock)
                if let load {
                    // Switching off waits for the clause in flight: keep feeding silence meanwhile,
                    // never stall the analyzer's input (that loses the next sentence).
                    let done = Box(false)
                    let switching = k == 0 || loaded != T10Analysis.loaded(item: k - 1, block: options.loadBlock)
                    Task { await load.setActive(loaded); done.value = true }
                    while !done.value { await push(silenceBuf) }
                    if switching { lastLoadSwitch = .now }
                }
                let loadName = loaded ? "mlx" : "idle"
                let beginS = Double(fed) / sr
                let speechEndS = beginS + Double((clip.speechEndChunk + 1) * Self.chunkFrames) / sr
                hyp.begin(atS: beginS)
                var trigger = FinalizeTrigger(config: finalize, lang: lang)
                var silentChunks = 0, heardSpeech = false
                var seg = 0
                var fired: (kind: FinalizeTrigger.Kind, chunk: Int, at: ContinuousClock.Instant, audioS: Double)?
                var finalAt: ContinuousClock.Instant?
                var finalEndS: Double?
                var finalizeCall: Box<(done: Bool, ms: Int?, error: String?)>?
                var alreadyFinal = false
                var segStartWall = ContinuousClock.now
                var speechOnsetWall: ContinuousClock.Instant?
                // Silence the analyzer got since the last speech (the previous tail, a load switch, this lead-in).
                let leadSilenceMs = Int(((beginS + Double(clip.speechStartChunk * Self.chunkFrames) / sr - lastVoicedEndS) * 1000).rounded())
                let sinceSwitchMs = lastLoadSwitch.map { Int((ContinuousClock.now - $0) / .milliseconds(1)) }
                let tailChunks = options.tailSilenceMs / 20
                var c = 0
                var afterFinal = 0

                // One row per finalized segment (an early ASR final splits a sentence, as in the product).
                func closeSegment() async {
                    var row: [String: Any] = ["i": idx, "seg": seg, "lang": Self.localeID[lang]!, "voice": voice, "load": loadName,
                                              "speech_ms": (clip.speechEndChunk - clip.speechStartChunk + 1) * 20,
                                              "words": trigger.words]
                    if seg == 0 {
                        row["lead_silence_ms"] = leadSilenceMs
                        if load != nil { row["ms_since_load_switch"] = sinceSwitchMs ?? NSNull() }
                        // First result with a word of this clip − wall time that word's chunk was fed
                        // (not the §6.5 volatile lag: that is ① soak's last word).
                        if let fw = hyp.firstWordSeen, let w = feeds.wallForWordEnd(fw.endS) {
                            row["first_word_lag_ms"] = T10Analysis.ms(wallS(fw.arrival) - w)
                        }
                    }
                    if let f = fired {
                        row["trigger"] = f.kind.rawValue
                        row["speech_end_to_trigger_ms"] = Int(((f.audioS - speechEndS) * 1000).rounded())
                        row["is_last"] = f.chunk >= clip.speechEndChunk
                        if alreadyFinal { row["already_final"] = true }
                        if let fa = finalAt {
                            row["finalize_to_final_ms"] = f.kind == .asrFinal || alreadyFinal ? 0 : Int((fa - f.at) / .milliseconds(1))
                            row["trigger_to_final_ms"] = max(0, Int((fa - f.at) / .milliseconds(1)))
                        } else { row["no_final_after_trigger"] = true }
                        // The finalize(through:) call is read after the run: waiting here would stop the feed.
                        if let box = finalizeCall { pendingCalls.append((rows.count, box)) }
                    } else { row["no_trigger"] = true; row["is_last"] = true }
                    if seg == 0, let fv = hyp.snapshot.firstVolatile, let on = speechOnsetWall {
                        row["onset_to_first_volatile_ms"] = Int((fv - on) / .milliseconds(1))
                    }
                    let snap = hyp.snapshot
                    if let e = snap.error { row["result_error"] = e }
                    // This segment's finals: units and audio end of each (from the clip start).
                    row["final_units"] = snap.finals.map { T10Analysis.textUnits($0.text) }
                    row["final_end_ms"] = snap.finals.map { T10Analysis.ms($0.endS - beginS) }
                    if let e = snap.finals.last?.endS, e < speechEndS - 0.02 {
                        // A final that closed the segment before the sentence's speech ended.
                        row["early_final_before_speech_end_ms"] = T10Analysis.ms(speechEndS - e)
                    }
                    rows.append(row)
                    seg += 1
                    fired = nil; finalAt = nil; finalEndS = nil; finalizeCall = nil; alreadyFinal = false
                }

                while c < clip.chunks.count + tailChunks {
                    let voicedNow = c < clip.chunks.count ? clip.voiced[c] : false
                    await push(c < clip.chunks.count ? clip.chunks[c] : silenceBuf)
                    if voicedNow { lastVoicedEndS = Double(fed) / sr }
                    if voicedNow { heardSpeech = true; silentChunks = 0; if speechOnsetWall == nil { speechOnsetWall = .now } }
                    else if heardSpeech { silentChunks += 1 }
                    let s = hyp.snapshot
                    let full = [s.finalText, s.volatile].filter { !$0.isEmpty }.joined(separator: " ")
                    let stable = [s.finalText, FinalizeTrigger.stablePrefix(s.prev, s.volatile)].filter { !$0.isEmpty }.joined(separator: " ")
                    let nowMs = Int((ContinuousClock.now - segStartWall) / .milliseconds(1))
                    if fired == nil, let k = trigger.observe(nowMs: nowMs, words: FinalizeTrigger.wordCount(full),
                                                             stableEndsWithSentencePunct: FinalizeTrigger.endsWithSentencePunct(stable),
                                                             silenceMs: silentChunks * 20,
                                                             asrFinal: s.finals.last.map { FinalizeTrigger.endsWithSentencePunct($0.text) } ?? false) {
                        // As ListenSegmenter (§5.1, M1): a final ends the sentence only with sentence
                        // punctuation; another rule with everything already final closes at once.
                        fired = (k, c, .now, Double(fed) / sr)
                        if k == .asrFinal {
                            finalAt = s.finals.last?.arrival
                            finalEndS = s.finals.last?.endS
                        } else if s.volatile.isEmpty, let last = s.finals.last {
                            alreadyFinal = true
                            finalAt = .now
                            finalEndS = last.endS
                        } else {
                            let a = analyzer
                            let through = CMTime(value: fed, timescale: CMTimeScale(sr))
                            let t0 = ContinuousClock.now
                            let box = Box<(done: Bool, ms: Int?, error: String?)>((false, nil, nil))
                            finalizeCall = box
                            Task {
                                do { try await a.finalize(through: through); box.value = (true, Int((ContinuousClock.now - t0) / .milliseconds(1)), nil) }
                                catch { box.value = (true, nil, "\(error)") }
                            }
                        }
                    }
                    if let f = fired, f.kind != .asrFinal, finalAt == nil, let fin = s.finals.first(where: { $0.arrival >= f.at }) {
                        finalAt = fin.arrival
                        finalEndS = fin.endS
                    }
                    if finalAt != nil {
                        if c < clip.speechEndChunk {
                            // More speech follows: the rest is a new segment.
                            let next = finalEndS ?? Double(fed) / sr
                            await closeSegment()
                            hyp.newSegment(atS: next)
                            trigger.reset()
                            segStartWall = .now
                        } else if c >= clip.chunks.count {
                            afterFinal += 1
                            if afterFinal >= 15 { break }   // 300 ms more silence, then the next sentence
                        }
                    }
                    c += 1
                }
                if fired != nil || seg == 0 { await closeSegment() }
                let clipRow: [String: Any] = ["i": idx, "lang": Self.localeID[lang]!, "voice": voice, "segments": seg,
                                              "ref_words": FinalizeTrigger.wordCount(text), "wer": Self.wer(ref: text, hyp: hyp.clipText),
                                              // Numbers come back as digits ("300", "12th") while the corpus spells them out.
                                              "hyp_digits": hyp.clipText.contains(where: \.isNumber)]
                records.write("t10.clip", clipRow)
                clips.append(clipRow)
            }
        }
        await load?.setActive(false)
        // Bounded: a finalize(through:) that never returns is itself a finding.
        let until = ContinuousClock.now + .seconds(2)
        for p in pendingCalls {
            while !p.box.value.done, ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(10)) }
            let v = p.box.value
            rows[p.row]["finalize_call_ms"] = v.ms ?? NSNull()
            if !v.done { rows[p.row]["finalize_not_returned"] = true }
            if let err = v.error { rows[p.row]["finalize_error"] = err }
        }
        for row in rows { records.write("t10.finalize", row) }
        input.finish()
        await analyzer.cancelAndFinishNow()
        listener.cancel()

        // Summary per trigger kind, and per load half when there is a load.
        if load != nil {
            var byLoad: [String: Any] = [:]
            for l in ["idle", "mlx"] {
                let xs = rows.filter { ($0["load"] as? String) == l }
                var kinds: [String: Any] = [:]
                for k in FinalizeTrigger.Kind.allCases {
                    let ys = xs.filter { ($0["trigger"] as? String) == k.rawValue }
                    if !ys.isEmpty { kinds[k.rawValue] = benchDist(ys.compactMap { $0["finalize_to_final_ms"] as? Int }) }
                }
                byLoad[l] = ["n": xs.count, "finalize_to_final_ms": benchDist(xs.compactMap { $0["finalize_to_final_ms"] as? Int }),
                             "by_trigger": kinds]
            }
            out["by_load"] = byLoad
        }
        var byKind: [String: Any] = [:]
        for k in FinalizeTrigger.Kind.allCases {
            let xs = rows.filter { ($0["trigger"] as? String) == k.rawValue }
            guard !xs.isEmpty else { continue }
            byKind[k.rawValue] = ["n": xs.count, "finalize_to_final_ms": benchDist(xs.compactMap { $0["finalize_to_final_ms"] as? Int }),
                                  "speech_end_to_trigger_ms": benchDist(xs.compactMap { $0["speech_end_to_trigger_ms"] as? Int }),
                                  "no_final": xs.filter { $0["no_final_after_trigger"] != nil }.count]
        }
        let last = rows.filter { ($0["is_last"] as? Bool) == true }
        out["n_clips"] = clips.count
        out["n_segments"] = rows.count
        out["segments_per_clip"] = Dictionary(grouping: clips.compactMap { $0["segments"] as? Int }, by: { "\($0)" }).mapValues(\.count)
        out["by_trigger"] = byKind
        out["last_segment_by_trigger"] = Dictionary(grouping: last.compactMap { $0["trigger"] as? String }, by: { $0 }).mapValues(\.count)
        out["all_finalize_to_final_ms"] = benchDist(rows.compactMap { $0["finalize_to_final_ms"] as? Int })
        // End of speech → final text of the sentence's last segment (§6.5 "句末判定 + final").
        out["speech_end_to_final_ms"] = benchDist(last.compactMap { r -> Int? in
            guard let a = r["speech_end_to_trigger_ms"] as? Int, let b = r["trigger_to_final_ms"] as? Int else { return nil }
            return a + b
        })
        out["onset_to_first_volatile_ms"] = benchDist(rows.compactMap { $0["onset_to_first_volatile_ms"] as? Int })
        out["no_trigger"] = rows.filter { $0["no_trigger"] != nil }.count
        out["errors"] = rows.filter { $0["error"] != nil || $0["result_error"] != nil || $0["finalize_error"] != nil }.count
        out["finalize_not_returned"] = rows.filter { $0["finalize_not_returned"] != nil }.count
        let wers = clips.compactMap { $0["wer"] as? Double }
        out["wer_mean"] = wers.isEmpty ? NSNull() : (wers.reduce(0, +) / Double(wers.count) * 1000).rounded() / 1000
        let plain = clips.filter { ($0["hyp_digits"] as? Bool) == false }.compactMap { $0["wer"] as? Double }
        out["wer_mean_without_digit_clips"] = plain.isEmpty ? NSNull() : (plain.reduce(0, +) / Double(plain.count) * 1000).rounded() / 1000
        out["clips_with_digits"] = clips.count - plain.count
        out["already_final"] = rows.filter { $0["already_final"] != nil }.count
        out["ends_with_sentence_punct"] = hyp.punctuation
        out["load"] = load == nil ? "idle (no MLX load)" : "alternating blocks of \(options.loadBlock): idle, mlx, idle, …"
        return out
    }

    /// Word error rate on lowercased words without punctuation (quality signal only).
    static func wer(ref: String, hyp: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let r = words(ref), h = words(hyp)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var d = Array(0...h.count)
        for i in 1...r.count {
            var prev = d[0]; d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let cur = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return (Double(d[h.count]) / Double(r.count) * 1000).rounded() / 1000
    }

    // MARK: ② consecutive presses

    func pressesRun(tmp: URL) async -> [String: Any] {
        var out: [String: Any] = [:]
        let probe = Self.makeTranscriber(.zh)
        out["assets"] = await Self.ensureAssets(probe)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe], considering: Self.int16Mono) else {
            out["error"] = "no compatible audio format"; return out
        }
        var clips: [Clip] = []
        for (i, t) in zhSentences.prefix(10).enumerated() {
            let wav = tmp.appendingPathComponent("zh-\(i).wav")
            if (try? SaySynth.render(t, voice: Self.zhVoice, to: wav)) != nil, let c = try? Self.load(wav, format: format) { clips.append(c) }
        }
        guard !clips.isEmpty else { out["error"] = "no zh audio"; return out }
        // As documented (`--load mlx`): the presses run with the engine synthesizing.
        await load?.setActive(true)
        let loadBefore = await load?.summary()
        let started = Date()
        var insufficient = 0
        var previous: (SpeechAnalyzer, AsyncStream<AnalyzerInput>.Continuation, Task<Void, Never>)?
        var setupMs: [Int] = [], cancelMs: [Int] = [], firstVolatile: [Int] = [], noVolatileHeld: [Int] = []
        var errors: [String: Int] = [:]
        for i in 0..<options.presses {
            if let (a, cont, l) = previous {
                let t0 = ContinuousClock.now
                cont.finish()
                await a.cancelAndFinishNow()
                l.cancel()
                cancelMs.append(Int((ContinuousClock.now - t0) / .milliseconds(1)))
            }
            let t0 = ContinuousClock.now
            let tr = Self.makeTranscriber(.zh)
            let a = SpeechAnalyzer(modules: [tr], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            let hyp = Hyp()
            do {
                try await a.prepareToAnalyze(in: format)
                try await a.start(inputSequence: stream)
            } catch {
                errors["\(error)", default: 0] += 1
                if Self.isInsufficientResources(error) { insufficient += 1 }
                records.write("t10.press", ["i": i, "error": "\(error)"])
                previous = nil
                continue
            }
            let l = Self.listen(tr, hyp)
            hyp.begin(atS: 0)
            let setup = Int((ContinuousClock.now - t0) / .milliseconds(1))
            setupMs.append(setup)
            let clip = clips[i % clips.count]
            let holdChunks = Int.random(in: 40...125)   // 0.8–2.5 s held
            var fed: Int64 = 0
            var clock = ContinuousClock.now
            let start = clock
            for c in 0..<min(holdChunks, clip.chunks.count) {
                cont.yield(AnalyzerInput(buffer: clip.chunks[c], bufferStartTime: CMTime(value: fed, timescale: CMTimeScale(format.sampleRate))))
                fed += Int64(clip.chunks[c].frameLength)
                clock = clock.advanced(by: .milliseconds(20))
                try? await Task.sleep(until: clock, clock: .continuous)
            }
            let s = hyp.snapshot
            if let fv = s.firstVolatile { firstVolatile.append(Int((fv - start) / .milliseconds(1))) } else { noVolatileHeld.append(holdChunks * 20) }
            if let e = s.error { errors[e, default: 0] += 1 }
            if hyp.insufficientResources { insufficient += 1 }
            records.write("t10.press", ["i": i, "setup_ms": setup, "held_ms": holdChunks * 20, "volatile": s.firstVolatile != nil,
                                        "error": s.error ?? NSNull()])
            previous = (a, cont, l)
        }
        if let (a, cont, l) = previous { cont.finish(); await a.cancelAndFinishNow(); l.cancel() }
        if let a = loadBefore, let b = await load?.summary() {
            out["mlx_busy_fraction"] = ((b["busy_s", default: 0] - a["busy_s", default: 0]) / max(1, Date().timeIntervalSince(started)) * 100).rounded() / 100
            out["mlx_clauses"] = b["clauses", default: 0] - a["clauses", default: 0]
        }
        await load?.setActive(false)
        out["mlx_load"] = load != nil
        out["n"] = options.presses
        out["setup_ms"] = benchDist(setupMs)
        out["cancel_ms"] = benchDist(cancelMs)
        out["first_volatile_ms"] = benchDist(firstVolatile)
        // cancel_ms has n − 1 entries (the first press has nothing to cancel); a press held
        // shorter than the first volatile shows none.
        out["presses_without_volatile"] = noVolatileHeld.count
        out["without_volatile_held_ms"] = benchDist(noVolatileHeld)
        out["errors"] = errors
        // Occurrences with SFSpeechError.Code.insufficientResources (not distinct messages).
        out["insufficient_resources"] = insufficient
        out["setup_definition"] = "SpeechTranscriber init → prepareToAnalyze → start (authorize, AssetInventory, bestAvailableAudioFormat not included)"
        return out
    }
}

extension SpeechBench {
    // MARK: startup: is the first sentence after start recognized?

    /// Both smoke runs of 2026-11-05 lost the first sentence after start (④ only; ① and ② did not).
    /// A fresh en-US / de-DE analyzer, as `AppleSpeechASR.open` makes it (prepare, then start),
    /// then one of three inputs before the same sentence, `startupReps` times each:
    ///   speech_now           speech right after start (② / ① feed like this);
    ///   silence_then_speech  3 s of continuous silence first (the product: the tap feeds zeros
    ///                        until someone speaks);
    ///   stall_then_speech    1 s of silence, then no input for 8 s, then speech (the M0 ④ order).
    func startupRun(tmp: URL) async -> [String: Any] {
        var out: [String: Any] = ["reps": options.startupReps]
        for lang in [Lang.en, .de] {
            let id = Self.localeID[lang]!
            let probe = Self.makeTranscriber(lang)
            _ = await Self.ensureAssets(probe)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe], considering: Self.int16Mono),
                  let text = corpus[lang]?.first, let voice = Self.voices[lang]?.first else {
                out[id] = ["error": "no format or corpus"]; continue
            }
            let wav = tmp.appendingPathComponent("startup-\(lang.rawValue).wav")
            guard (try? SaySynth.render(text, voice: voice, to: wav)) != nil, let clip = try? Self.load(wav, format: format) else {
                out[id] = ["error": "say failed"]; continue
            }
            try? FileManager.default.removeItem(at: wav)
            let silence = Self.silence(format)
            var cases: [String: Any] = [:]
            for (name, leadSilence, stallS) in [("speech_now", 0, 0), ("silence_then_speech", 150, 0), ("stall_then_speech", 50, 8)] {
                var recognized = 0, units: [Int] = [], firstText: [Int] = [], prepareMs: [Int] = []
                for rep in 0..<options.startupReps {
                    let t = Self.makeTranscriber(lang)
                    let a = SpeechAnalyzer(modules: [t], options: .init(priority: .medium, modelRetention: .processLifetime))
                    let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
                    let p0 = ContinuousClock.now
                    do {
                        try await a.prepareToAnalyze(in: format)
                        try await a.start(inputSequence: stream)
                    } catch { cases["\(name)_error"] = "\(error)"; continue }
                    prepareMs.append(Int((ContinuousClock.now - p0) / .milliseconds(1)))
                    let hyp = Hyp()
                    hyp.begin(atS: 0)
                    let l = Self.listen(t, hyp)
                    var fed: Int64 = 0
                    var clock = ContinuousClock.now
                    func push(_ b: AVAudioPCMBuffer) async {
                        input.yield(AnalyzerInput(buffer: b, bufferStartTime: CMTime(value: fed, timescale: CMTimeScale(format.sampleRate))))
                        fed += Int64(b.frameLength)
                        clock = clock.advanced(by: .milliseconds(20))
                        try? await Task.sleep(until: clock, clock: .continuous)
                    }
                    for _ in 0..<leadSilence { await push(silence) }
                    if stallS > 0 {
                        try? await Task.sleep(for: .seconds(stallS))
                        clock = ContinuousClock.now
                    }
                    var onset: ContinuousClock.Instant?
                    var first: Int?
                    for (k, b) in (clip.chunks + Array(repeating: silence, count: 150)).enumerated() {
                        await push(b)
                        if k == clip.speechStartChunk { onset = .now }
                        if first == nil, let o = onset, !hyp.clipText.isEmpty { first = Int((ContinuousClock.now - o) / .milliseconds(1)) }
                    }
                    let u = T10Analysis.textUnits(hyp.clipText)
                    units.append(u)
                    if u > 0 { recognized += 1 }
                    if let first { firstText.append(first) }
                    records.write("t10.startup", ["locale": id, "case": name, "rep": rep, "units": u,
                                                  "ref_units": T10Analysis.textUnits(text), "first_text_ms": first ?? NSNull()])
                    input.finish()
                    await a.cancelAndFinishNow()
                    l.cancel()
                }
                cases[name] = ["recognized": recognized, "units": units, "first_text_ms": benchDist(firstText),
                               "prepare_start_ms": benchDist(prepareMs)]
            }
            cases["ref_units"] = T10Analysis.textUnits(text)
            out[id] = cases
        }
        return out
    }

    // MARK: ① two analyzers, long run

    struct SoakLane: Sendable {
        var lang: Lang
        /// The one clock origin of both lanes (so their buckets line up).
        let start: ContinuousClock.Instant
        var events = Box<[T10Analysis.ResultEvent]>([])
        var clipTimes = Box<[T10Analysis.ClipTimes]>([])
        var feeds = Box(T10Analysis.FeedTable())
        var fed = Box<Int64>(0)
        var firstYield = Box<Double?>(nil)
        var counts = Box<(volatile: Int, final: Int)>((0, 0))
        var errors = Box<[String: Int]>([:])
        var insufficient = Box(0)
        var listenerDone = Box(false)
        func now() -> Double { (ContinuousClock.now - start) / .seconds(1) }
    }

    static func isInsufficientResources(_ e: Error) -> Bool {
        (e as NSError).domain == SFSpeechError.errorDomain && (e as NSError).code == SFSpeechError.Code.insufficientResources.rawValue
    }

    func soakRun(tmp: URL) async -> [String: Any] {
        var out: [String: Any] = ["minutes": options.soakMinutes, "mlx_load": load != nil,
                                  "lag_bucket_s": options.lagBucketS, "lag_baseline_buckets": options.lagBaselineBuckets]
        let origin = ContinuousClock.now
        // zh-CN as SPEAK opens it (userInitiated), en-US as LISTEN does (medium), both kept alive.
        var lanes: [(SoakLane, SpeechAnalyzer, AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat, [Clip], Task<Void, Never>)] = []
        for (lang, priority) in [(Lang.zh, TaskPriority.userInitiated), (.en, .medium)] {
            let lane = SoakLane(lang: lang, start: origin)
            let t = Self.makeTranscriber(lang)
            var info = await Self.ensureAssets(t)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t], considering: Self.int16Mono) else {
                info["error"] = "no compatible audio format"; out[Self.localeID[lang]!] = info; return out
            }
            var clips: [Clip] = []
            let texts = lang == .zh ? Array(zhSentences.prefix(20)) : Array((corpus[.en] ?? []).prefix(20))
            let voice = lang == .zh ? Self.zhVoice : (Self.voices[.en]?.first ?? "Samantha")
            for (i, text) in texts.enumerated() {
                let wav = tmp.appendingPathComponent("soak-\(lang.rawValue)-\(i).wav")
                if (try? SaySynth.render(text, voice: voice, to: wav)) != nil, let c = try? Self.load(wav, format: format) { clips.append(c) }
                try? FileManager.default.removeItem(at: wav)
            }
            guard !clips.isEmpty else { out["error"] = "no \(lang.rawValue) audio"; return out }
            let analyzer = SpeechAnalyzer(modules: [t], options: .init(priority: priority, modelRetention: .processLifetime))
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
            } catch {
                out["error"] = "\(Self.localeID[lang]!) start: \(error)"; return out
            }
            let results = t.results
            let sr = format.sampleRate
            // Volatile ranges end at the audio fed when they arrive (r.range.end == lane.fed in
            // the first smoke), so timing uses the words' own audio ends and the feed table.
            // Nothing is written from here (a shared writer lock would delay `t`): buffered only.
            let listener = Task {
                do {
                    for try await r in results {
                        let t = lane.now()
                        let fedS = Double(lane.fed.value) / sr
                        var ends: [Double] = []
                        for run in r.text.runs {
                            guard let range = run.audioTimeRange else { continue }
                            if T10Analysis.isWord(String(r.text[run.range].characters)) { ends.append(range.end.seconds) }
                        }
                        let units = T10Analysis.textUnits(String(r.text.characters))
                        lane.events.mutate { $0.append(.init(t: t, isFinal: r.isFinal, wordEnds: ends, fedAtReceipt: fedS,
                                                             rangeEnd: r.range.end.seconds, units: units)) }
                        lane.counts.mutate { if r.isFinal { $0.final += 1 } else { $0.volatile += 1 } }
                    }
                } catch is CancellationError {
                    // our own cancel at the end of the run
                } catch {
                    if Self.isInsufficientResources(error) { lane.insufficient.mutate { $0 += 1 } }
                    lane.errors.mutate { $0["\(error)", default: 0] += 1 }
                }
                lane.listenerDone.value = true
            }
            lanes.append((lane, analyzer, input, format, clips, listener))
        }
        await load?.setActive(true)
        let loadBefore = await load?.summary()
        let started = Date()
        let feedStart = (ContinuousClock.now - origin) / .seconds(1)
        let feedChunks = Int(options.soakMinutes * 60 * 50)
        let tailChunks = 150   // 3 s of silence after the last sentence, so it gets its final
        let jitterMaxChunks = options.soakJitterMs / 20
        let tracked = lanes.map(\.0)
        let records = self.records
        // Numbers only, written while the run goes (a crash in the hour keeps what was fed):
        // every result's word ends, units, range end and receipt, every sentence's audio times and
        // chunk walls. The writer stamps its own `t_ms`, so receipt time is `recv_ms`.
        let written = Box(tracked.map { _ in (events: 0, clips: 0) })
        func flush() {
            for (n, l) in tracked.enumerated() {
                let id = Self.localeID[l.lang]!
                let ev = l.events.value, cl = l.clipTimes.value, f = l.feeds.value
                let w = written.value[n]
                for e in ev[w.events...] {
                    records.write("t10.soak.event", ["locale": id, "recv_ms": T10Analysis.ms(e.t), "final": e.isFinal, "units": e.units,
                                                     "word_end_ms": e.wordEnds.map { T10Analysis.ms($0) },
                                                     "range_end_ms": e.rangeEnd.map { T10Analysis.ms($0) } ?? NSNull(),
                                                     "fed_ms": T10Analysis.ms(e.fedAtReceipt)])
                }
                for c in cl[w.clips...] {
                    // Chunks from the clip start through its last speech chunk.
                    let lo = f.last { $0 <= c.audioStart + 1e-9 } ?? 0
                    let hi = (f.last { $0 < c.speechEndAudio - 1e-9 } ?? lo) + 1
                    records.write("t10.soak.clip", ["locale": id, "identity": c.identity, "audio_start_ms": T10Analysis.ms(c.audioStart),
                                                    "onset_ms": T10Analysis.ms(c.onsetAudio), "speech_end_ms": T10Analysis.ms(c.speechEndAudio),
                                                    "chunk_wall_ms": f.wall[lo..<min(hi, f.wall.count)].map { T10Analysis.ms($0) }])
                }
                written.mutate { $0[n] = (ev.count, cl.count) }
            }
        }
        let feeding = Box(true)
        await withTaskGroup(of: Void.self) { g in
            for (lane, _, input, format, clips, _) in lanes {
                g.addTask {
                    let silence = Self.silence(format)
                    let sr = format.sampleRate
                    var clock = ContinuousClock.now
                    var sent = 0, k = 0
                    // Fixed seed: the 20-sentence rotation's length mod the ~960 ms result grid
                    // would otherwise lock each sentence to one grid phase for many minutes.
                    var rng = SeededRandom(seed: lane.lang == .zh ? 0x7410_1 : 0x7410_2)
                    func feed(_ b: AVAudioPCMBuffer) async -> Double {
                        let at = Double(lane.fed.value) / sr
                        let wall = lane.now()
                        lane.feeds.mutate { $0.append(audio: at, wall: wall) }
                        if lane.firstYield.value == nil { lane.firstYield.value = wall }
                        input.yield(AnalyzerInput(buffer: b, bufferStartTime: CMTime(value: lane.fed.value, timescale: CMTimeScale(sr))))
                        lane.fed.mutate { $0 += Int64(b.frameLength) }
                        sent += 1
                        clock = clock.advanced(by: .milliseconds(20))
                        try? await Task.sleep(until: clock, clock: .continuous)
                        return at
                    }
                    while sent < feedChunks {
                        // One whole sentence, then 2 s (+ jitter) of silence (a pause between turns).
                        let identity = k % clips.count
                        let clip = clips[identity]
                        k += 1
                        let audioStart = Double(lane.fed.value) / sr
                        var onset = audioStart, end = audioStart
                        let pause = 100 + (jitterMaxChunks > 0 ? Int(rng.next() % UInt64(jitterMaxChunks + 1)) : 0)
                        for (c, b) in (clip.chunks + Array(repeating: silence, count: pause)).enumerated() {
                            let at = await feed(b)
                            if c == clip.speechStartChunk { onset = at }
                            if c == clip.speechEndChunk { end = at + Double(b.frameLength) / sr }
                        }
                        lane.clipTimes.mutate { $0.append(.init(audioStart: audioStart, onsetAudio: onset, speechEndAudio: end, identity: identity)) }
                    }
                    for _ in 0..<tailChunks { _ = await feed(silence) }
                }
            }
            g.addTask {
                while feeding.value {
                    try? await Task.sleep(for: .seconds(5))
                    if feeding.value { flush() }
                }
            }
            // The feeders end on their own; then stop the writer.
            var finished = 0
            for await _ in g {
                finished += 1
                if finished == lanes.count { feeding.value = false }
            }
        }
        let wallS = Date().timeIntervalSince(started)
        if let a = loadBefore, let b = await load?.summary() {
            // Was the load on the whole time? mlx_busy_fraction = 有请求在途的时间占比: share of
            // the soak's wall time with a TTS request in flight (client side, not GPU busy time).
            out["mlx_busy_fraction"] = ((b["busy_s", default: 0] - a["busy_s", default: 0]) / max(1, wallS) * 100).rounded() / 100
            out["mlx_clauses"] = b["clauses", default: 0] - a["clauses", default: 0]
            out["mlx_errors"] = b["errors", default: 0] - a["errors", default: 0]
        }
        await load?.setActive(false)
        // Finish through the end of input (the last results come in), then the last flush.
        for (lane, analyzer, input, _, _, listener) in lanes {
            input.finish()
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { lane.errors.mutate { $0["finish: \(error)", default: 0] += 1 } }
            let until = ContinuousClock.now + .seconds(5)
            while !lane.listenerDone.value, ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(20)) }
            listener.cancel()
        }
        flush()
        out["started_unix"] = Int(started.timeIntervalSince1970)
        out["ended_unix"] = Int(Date().timeIntervalSince1970)
        out["lag_rule"] = "C6"
        out["lag_drift_stat"] = options.lagStat.rawValue   // C5's statistic (reported only)
        out["inter_clip_silence_ms"] = "2000 + uniform 0…\(jitterMaxChunks * 20) (seeded)"
        out["tail_silence_ms"] = tailChunks * 20
        for (lane, _, _, format, clips, _) in lanes {
            let id = Self.localeID[lane.lang]!
            let events = lane.events.value, feeds = lane.feeds.value, firstYield = lane.firstYield.value ?? feedStart
            let clipTimes = lane.clipTimes.value
            let lags = T10Analysis.clipLags(events: events, clips: clipTimes, feeds: feeds)
            // Feeder lateness: hand-over minus the absolute 20 ms schedule from the first yield, by
            // the chunk's audio time and by its index (equal now that every chunk is 320 frames).
            func late(_ audio: Double) -> (audio: Int, index: Int)? {
                guard let k = feeds.last({ $0 <= audio }) else { return nil }
                return (T10Analysis.ms(feeds.wall[k] - (firstYield + feeds.audio[k])), T10Analysis.ms(feeds.wall[k] - (firstYield + Double(k) * 0.02)))
            }
            for (i, l) in lags.enumerated() {
                let hit = l.hitIndex.map { events[$0] }
                let c = clipTimes[i]
                func msOrNull(_ x: Double?) -> Any { x.map { T10Analysis.ms($0) } ?? NSNull() }
                var row: [String: Any] = ["locale": id, "identity": l.identity, "start_ms": T10Analysis.ms(l.start - feedStart)]
                row["onset_lag_ms"] = l.onsetMs ?? NSNull()
                row["lag_ms"] = l.completionMs ?? NSNull()
                row["last_from_final"] = l.lastFromFinal ?? NSNull()
                row["hit_is_final"] = l.hitIsFinal ?? NSNull()
                row["speech_end_ms"] = T10Analysis.ms(c.speechEndAudio)
                row["last_word_end_ms"] = msOrNull(l.lastWordEnd)
                row["hit_range_end_ms"] = msOrNull(hit?.rangeEnd)
                row["hit_fed_ms"] = msOrNull(hit?.fedAtReceipt)
                row["hit_units"] = l.hitUnits ?? NSNull()
                row["final_units"] = l.finalUnits ?? NSNull()
                row["complete_lag_ms"] = l.completeMs ?? NSNull()
                row["complete_units"] = l.completeIndex.map { events[$0].units } ?? NSNull()
                row["late_batch"] = l.lateBatch ?? NSNull()
                let ls = late(c.audioStart), le = late(c.speechEndAudio - 1e-6)
                row["late_at_start_ms"] = ls?.audio ?? NSNull()
                row["late_at_ref_ms"] = le?.audio ?? NSNull()
                row["late_idx_at_start_ms"] = ls?.index ?? NSNull()
                row["late_idx_at_ref_ms"] = le?.index ?? NSNull()
                records.write("t10.soak.lag", row)
            }
            // ① rule: sentences with a final only (a sentence cut off at the end has none).
            let samples = lags.compactMap { l in
                l.lastFromFinal == true ? l.completionMs.map { (feedS: l.start - feedStart, lagMs: $0) } : nil
            }
            let drift = T10Analysis.LagDrift.evaluate(samples, bucketS: options.lagBucketS, baselineBuckets: options.lagBaselineBuckets,
                                                      stat: options.lagStat)
            let c6 = T10Analysis.C6.evaluate(T10Analysis.C6.inputs(events: events, lags: lags, feeds: feeds, feedStart: feedStart),
                                             bucketS: options.lagBucketS, baselineBuckets: options.lagBaselineBuckets)
            let indices = Set(drift.buckets.map(\.index)).union(c6.buckets.map(\.index)).sorted()
            for i in indices {
                var row: [String: Any] = ["locale": id, "bucket": i]
                if let b = drift.buckets.first(where: { $0.index == i }) {
                    row["n"] = b.n; row["lag_p50_ms"] = b.p50; row["lag_p90_ms"] = b.p90; row["lag_mean_ms"] = b.mean
                }
                if let b = c6.buckets.first(where: { $0.index == i }) {
                    row["clips"] = b.clips
                    row["delivery_p90_ms"] = b.deliveryP90 ?? NSNull()
                    row["backlog_max_ms"] = b.backlogMax ?? NSNull()
                    row["median_batch_gap_ms"] = b.medianBatchGap ?? NSNull()
                    row["late_batch_frac"] = b.lateBatchFrac.map { ($0 * 1000).rounded() / 1000 } ?? NSNull()
                    row["lag_complete_p90_ms"] = b.completeP90 ?? NSNull()
                }
                records.write("t10.soak", row)
            }
            let causal = T10Analysis.causalFaults(events)
            let negative = T10Analysis.negative(lags)
            let below = samples.filter { $0.lagMs < 0 }.map(\.lagMs)
            var r: [String: Any] = [:]
            r["volatile_results"] = lane.counts.value.volatile
            r["final_results"] = lane.counts.value.final
            r["fed_s"] = Int(Double(lane.fed.value) / format.sampleRate)
            r["feed_start_offset_ms"] = T10Analysis.ms(firstYield - feedStart)
            r["errors"] = lane.errors.value
            r["insufficient_resources"] = lane.insufficient.value
            r["identities"] = clips.count
            r["clips"] = lags.count
            r["clips_without_text"] = lags.filter { $0.lastWordEnd == nil }.count
            r["clips_without_final"] = lags.filter { $0.lastFromFinal != true }.count
            r["hit_is_final"] = lags.filter { $0.hitIsFinal == true }.count
            r["onset_to_text_ms"] = benchDist(lags.compactMap(\.onsetMs))
            r["lag_ms"] = benchDist(samples.map(\.lagMs))
            r["lag_definition"] = "first result holding a word of the sentence and covering its speech end (volatile range end ≥ speech end, or a final with its last word) − wall time the last voiced chunk was fed"
            r["causal_faults"] = causal          // a result holding audio not fed yet
            r["negative_lags"] = negative        // below −20 ms
            r["lags_below_zero"] = below.count
            r["lag_min_ms"] = samples.map(\.lagMs).min() ?? NSNull()
            // C5 (one p90 of the whole lag): reported, not judged (§14 T10 ①: the grid wait alone
            // gives it ~7 % false failures an hour).
            r["c5_baseline_ms"] = drift.baselineMs ?? NSNull()
            r["c5_max_deviation_ms"] = drift.maxDeviationMs ?? NSNull()
            r["c5_pass"] = drift.pass ?? NSNull()
            r["lag_complete_ms"] = benchDist(lags.compactMap { $0.lastFromFinal == true ? $0.completeMs : nil })
            r["late_batch"] = lags.filter { $0.lastFromFinal == true && $0.lateBatch == true }.count
            // C6: the parts of the lag judged one by one.
            if let b = c6.baseline {
                r["c6_baseline"] = ["delivery_p90_ms": b.deliveryP90 ?? NSNull(), "median_batch_gap_ms": b.medianBatchGap ?? NSNull(),
                                    "late_batch_frac": b.lateBatchFrac.map { ($0 * 1000).rounded() / 1000 } ?? NSNull(),
                                    "lag_complete_p90_ms": b.completeP90 ?? NSNull()] as [String: Any]
            }
            r["c6_failed_checks"] = c6.failedChecks
            r["c6_failures"] = c6.failures
            r["lag_skipped_tail_bucket"] = c6.skippedTail ?? NSNull()
            if causal + negative > 0 { r["lag_drift_pass"] = false } else { r["lag_drift_pass"] = c6.pass ?? NSNull() }
            r["buckets"] = drift.buckets.count
            out[id] = r
        }
        return out
    }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

/// The MLX load for T10 (TalkTalkApp: the engine synthesizing clause after clause). `setActive`
/// returns once the load is really on or off (an off waits for the clause in flight).
public protocol BenchLoad: Sendable {
    func setActive(_ on: Bool) async
    func summary() async -> [String: Double]
}

/// SplitMix64: a fixed, reproducible sequence (the bench's inter-sentence jitter).
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
