@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import TalkTalkCore

/// LISTEN streaming ASR (ARCHITECTURE.md §4.2): Apple `SpeechTranscriber` en-US / de-DE with
/// `.volatileResults + .fastResults` and `.audioTimeRange`, analyzer `.processLifetime`,
/// `prepareToAnalyze`, 16 kHz Int16 mono input. Speech assets are system-managed (AssetInventory);
/// `open` refuses a locale whose assets are not installed — installing is the settings UI's call
/// (`installAssets`), never a side effect of starting a meeting.
public struct AppleSpeechASR: StreamingASREngine {
    public enum Failure: Error, Sendable, Equatable {
        case notAvailable
        case assetsNotInstalled(String)
        case noCompatibleFormat
        case notAuthorized(String)
    }

    public let id = EngineID(name: "apple-speech", revision: "SpeechTranscriber", placement: .systemService)

    public init() {}

    public static func localeIdentifier(_ lang: Lang) -> String {
        switch lang { case .en: "en-US"; case .de: "de-DE"; case .zh: "zh-CN" }
    }

    static func makeTranscriber(_ lang: Lang) -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: localeIdentifier(lang)), transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }

    /// Speech recognition permission (the first call shows the system prompt; run from the app).
    public static func authorize() async -> String {
        let s: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            if SFSpeechRecognizer.authorizationStatus() != .notDetermined { c.resume(returning: SFSpeechRecognizer.authorizationStatus()); return }
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return name(s)
    }

    /// The current status without prompting (§7.5 item 5).
    public static func currentAuthorization() -> String { name(SFSpeechRecognizer.authorizationStatus()) }

    static func name(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    public static func assetsInstalled(_ lang: Lang) async -> Bool {
        await AssetInventory.status(forModules: [makeTranscriber(lang)]) == .installed
    }

    /// Reserves the locale's speech assets so the system keeps them (§7.5 item 6). false: refused
    /// or failed (the startup check reports it).
    public static func reserve(_ lang: Lang) async -> Bool {
        (try? await AssetInventory.reserve(locale: Locale(identifier: localeIdentifier(lang)))) ?? false
    }

    /// App launch, before the startup check: onboarding step 2 reserves only what it downloads, so
    /// a locale that was already installed is reserved here. Only installed locales that are not
    /// reserved yet, and never more than `maximumReservedLocales` in all.
    public static func reserveInstalledLocales(_ langs: [Lang] = AppleStartupCheck.locales) async {
        var reserved = Set(await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) })
        let limit = AssetInventory.maximumReservedLocales
        for l in langs {
            let id = Locale(identifier: localeIdentifier(l)).identifier(.bcp47)
            guard !reserved.contains(id), reserved.count < limit, await assetsInstalled(l) else { continue }
            if await reserve(l) { reserved.insert(id) }
        }
    }

    /// Downloads the locale's speech assets (system-managed, ~140 MB per locale, §4.3). UI only
    /// (onboarding step 2, the meeting-start prompt). Reserves the locale first so the system
    /// keeps the assets (§7.5 item 6: zh-CN, en-US, de-DE take 3 of the reservation slots); a
    /// failed reservation does not block the download (the startup check reports it).
    public static func installAssets(_ lang: Lang) async throws {
        _ = try? await AssetInventory.reserve(locale: Locale(identifier: localeIdentifier(lang)))
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(lang)]) {
            try await req.downloadAndInstall()
        }
    }

    public func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        guard SpeechTranscriber.isAvailable else { throw Failure.notAvailable }
        let auth = await Self.authorize()
        guard auth == "authorized" else { throw Failure.notAuthorized(auth) }
        let transcriber = Self.makeTranscriber(lang)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw Failure.assetsNotInstalled(Self.localeIdentifier(lang))
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                         considering: AppleSpeechStream.int16Mono) else {
            throw Failure.noCompatibleFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: highPriority ? .userInitiated : .medium,
                                                     modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        let stream = try AppleSpeechStream(analyzer: analyzer, transcriber: transcriber, format: format)
        try await stream.start()
        return stream
    }
}

/// One analyzer session. `feed` runs on the audio worker: it converts, timestamps and yields into
/// the analyzer's input stream without waiting. Audio time (seconds since the first fed frame,
/// 16 kHz timescale) maps back to host time through the anchors recorded at each discontinuity.
public final class AppleSpeechStream: ASRStream, @unchecked Sendable {
    static let int16Mono = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    static let nsPerFrame: Double = 1e9 / 16_000

    public let volatileEvents: AsyncStream<ASREvent>
    public let finalEvents: AsyncStream<ASREvent>
    private let volatileCont: AsyncStream<ASREvent>.Continuation
    private let finalCont: AsyncStream<ASREvent>.Continuation

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>

    private let lock = NSLock()
    private var fed: Int64 = 0                                  // 16 kHz frames
    private var anchors: [(frame: Int64, host: HostTime)] = []
    private var closed = false
    private var listener: Task<Void, Never>?
    private var _droppedFinals = 0
    private var _lastError: String?

    init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat) throws {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.format = format
        if format == Self.int16Mono {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: Self.int16Mono, to: format) else { throw AppleSpeechASR.Failure.noCompatibleFormat }
            converter = c
        }
        (volatileEvents, volatileCont) = AsyncStream.makeStream(of: ASREvent.self, bufferingPolicy: .bufferingNewest(1))
        (finalEvents, finalCont) = AsyncStream.makeStream(of: ASREvent.self, bufferingPolicy: .bufferingOldest(64))
        (inputStream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    func start() async throws {
        try await analyzer.start(inputSequence: inputStream)
        let results = transcriber.results
        listener = Task { [weak self] in
            do {
                for try await r in results {
                    guard let self else { return }
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = self.host(atSeconds: r.range.start.seconds)
                    let end = self.host(atSeconds: r.range.end.seconds)
                    if r.isFinal {
                        if case .dropped = self.finalCont.yield(.final(text, range: min(start, end)...max(start, end))) {
                            self.lock.withLock { self._droppedFinals += 1 }
                        }
                    } else {
                        self.volatileCont.yield(.volatile(text, through: end))
                    }
                }
            } catch {
                self?.lock.withLock { self?._lastError = "\(type(of: error))" }
            }
            self?.volatileCont.finish()
            self?.finalCont.finish()
        }
    }

    /// Finals dropped because the consumer fell 64 behind (log `asr.final.dropped`).
    public var droppedFinals: Int { lock.withLock { _droppedFinals } }
    public var lastError: String? { lock.withLock { _lastError } }

    public func feed(_ frames: UnsafeBufferPointer<Int16>, at: HostTime) {
        guard frames.count > 0 else { return }
        let start: Int64? = lock.withLock {
            guard !closed else { return nil }
            let s = fed
            // New anchor at the first frame and whenever the host time strays > 20 ms from the
            // running count (a capture gap or a restarted tap).
            if let a = anchors.last {
                let expected = Double(a.host) + Double(s - a.frame) * Self.nsPerFrame
                if abs(Double(at) - expected) > 20e6 { appendAnchor(s, at) }
            } else {
                appendAnchor(s, at)
            }
            fed += Int64(frames.count)
            return s
        }
        guard let start, let buffer = makeBuffer(frames) else { return }
        input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: start, timescale: 16_000)))
    }

    private func appendAnchor(_ frame: Int64, _ host: HostTime) {
        anchors.append((frame, host))
        if anchors.count > 256 { anchors.removeFirst(anchors.count - 256) }
    }

    private func makeBuffer(_ frames: UnsafeBufferPointer<Int16>) -> AVAudioPCMBuffer? {
        let n = AVAudioFrameCount(frames.count)
        guard let src = AVAudioPCMBuffer(pcmFormat: Self.int16Mono, frameCapacity: n) else { return nil }
        src.frameLength = n
        src.int16ChannelData![0].update(from: frames.baseAddress!, count: frames.count)
        guard let converter else { return src }
        let cap = AVAudioFrameCount(Double(n) * format.sampleRate / 16_000) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        nonisolated(unsafe) var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return src
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }

    func host(atSeconds s: Double) -> HostTime {
        let f = Int64((s.isFinite ? max(0, s) : 0) * 16_000)
        return lock.withLock {
            guard let a = anchors.last(where: { $0.frame <= f }) ?? anchors.first else { return HostClock.now() }
            let d = Double(f - a.frame) * Self.nsPerFrame
            return d >= 0 ? a.host &+ HostTime(d) : a.host &- HostTime(-d)
        }
    }

    func frame(atHost h: HostTime) -> Int64 {
        lock.withLock {
            guard let a = anchors.last(where: { $0.host <= h }) ?? anchors.first else { return fed }
            let f = h >= a.host ? a.frame + Int64(Double(h - a.host) / Self.nsPerFrame) : a.frame
            return min(max(0, f), fed)
        }
    }

    public func finalize(through: HostTime) async {
        let f = frame(atHost: through)
        do { try await analyzer.finalize(through: CMTime(value: f, timescale: 16_000)) }
        catch { lock.withLock { _lastError = "finalize: \(type(of: error))" } }
    }

    /// SPEAK preview replacement does not need a final transcript. Cancel before opening the
    /// next analyzer, instead of leaving the previous one finalizing for up to two seconds.
    public func cancel() async {
        let already = lock.withLock { defer { closed = true }; return closed }
        guard !already else { return }
        input.finish()
        listener?.cancel()
        await analyzer.cancelAndFinishNow()
        volatileCont.finish()
        finalCont.finish()
    }

    /// Finalizes what was fed (bounded to 2 s), else cancels; frees the recognizer slot either way.
    public func close() async {
        let already: Bool = lock.withLock { defer { closed = true }; return closed }
        guard !already else { return }
        input.finish()
        let done = DoneFlag()
        let a = analyzer
        Task { try? await a.finalizeAndFinishThroughEndOfInput(); done.set() }
        let until = ContinuousClock.now + .seconds(2)
        while !done.value, ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(20)) }
        if !done.value { await analyzer.cancelAndFinishNow() }
        // Let the listener deliver the last finals, then end both streams.
        try? await Task.sleep(for: .milliseconds(50))
        listener?.cancel()
        volatileCont.finish()
        finalCont.finish()
    }
}

final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}
