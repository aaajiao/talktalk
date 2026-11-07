import AVFoundation
import Foundation
import TalkTalkCore

/// The system-voice fallback (ARCHITECTURE.md C8, §9, §16 decision 5): `AVSpeechSynthesizer.write`
/// with the best installed zh-CN / en-US / de-DE voice, never a Personal Voice.
/// Output: 24 kHz f32 mono in 0.16 s chunks (§1.3), like RemoteQwenTTS, so it goes through
/// the same PlayoutStage. Licence: personal, non-commercial use only (SLA §2.F, licensing.md).
///
/// There is no conditioning: `buildConditioning` throws, `load` accepts only `CloneMode.system`.
public actor SystemVoiceTTS: TTSEngine {
    public enum Failure: Error, Sendable, Equatable {
        case unsupportedLanguage(String)
        case noVoice(String)
        case noConditioning
        case conversion
        case timeout
    }

    /// What voice selection looks at (pure, testable).
    public struct VoiceInfo: Sendable, Equatable {
        public var identifier: String
        public var name: String
        public var language: String          // BCP-47, e.g. "en-US"
        public var quality: Int              // AVSpeechSynthesisVoiceQuality raw value: 1 default, 2 enhanced, 3 premium
        public var isPersonal: Bool
        public var isNovelty: Bool
        public init(identifier: String, name: String, language: String, quality: Int, isPersonal: Bool = false, isNovelty: Bool = false) {
            self.identifier = identifier; self.name = name; self.language = language; self.quality = quality
            self.isPersonal = isPersonal; self.isNovelty = isNovelty
        }
    }

    public static let locales: [Lang: String] = [.zh: "zh-CN", .en: "en-US", .de: "de-DE"]
    /// Preferred names per language at equal quality (§9: Ava Premium, Anna).
    public static let preferred: [Lang: [String]] = [.zh: ["Tingting", "婷婷"], .en: ["Ava"], .de: ["Anna"]]
    public static let chunkSamples = 3840                  // 0.16 s at 24 kHz

    /// Highest quality first, then the preferred name, then the identifier (stable). Personal and
    /// novelty voices never qualify.
    public static func pickVoice(for lang: Lang, among voices: [VoiceInfo]) -> VoiceInfo? {
        guard let loc = locales[lang] else { return nil }
        let names = preferred[lang] ?? []
        return voices
            .filter { $0.language == loc && !$0.isPersonal && !$0.isNovelty }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                let ap = names.contains { a.name.hasPrefix($0) }, bp = names.contains { b.name.hasPrefix($0) }
                if ap != bp { return ap }
                return a.identifier < b.identifier
            }
            .first
    }

    public static func installedVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            VoiceInfo(identifier: v.identifier, name: v.name, language: v.language, quality: v.quality.rawValue,
                      isPersonal: v.voiceTraits.contains(.isPersonalVoice), isNovelty: v.voiceTraits.contains(.isNoveltyVoice))
        }
    }

    /// Whether a voice better than compact is installed for this language (Settings hints to download one, §9).
    public static func hasGoodVoice(_ lang: Lang) -> Bool {
        (pickVoice(for: lang, among: installedVoices())?.quality ?? 0) >= 2
    }

    public nonisolated let id = EngineID(name: "system-voice", revision: "AVSpeechSynthesizer", placement: .systemService)
    public nonisolated let outputRate: Double = 24_000

    /// One synthesizer per running job; `stopSpeaking` ends its write callbacks.
    final class Job: @unchecked Sendable {
        let synth = AVSpeechSynthesizer()
        private let lock = NSLock()
        private var stopped = false
        private var onStop: (() -> Void)?
        var isStopped: Bool { lock.withLock { stopped } }
        /// Called once on stop, so a render whose callbacks just cease still ends.
        func setOnStop(_ f: @escaping () -> Void) { lock.withLock { onStop = f } }
        func stop() {
            let f = lock.withLock { () -> (() -> Void)? in stopped = true; defer { onStop = nil }; return onStop }
            synth.stopSpeaking(at: .immediate)
            f?()
        }
    }

    private var jobs: [JobID: Job] = [:]

    public init() {}

    public func buildConditioning(_ ref: VoiceReference, model: EngineID, mode: CloneMode) async throws -> Data {
        throw Failure.noConditioning
    }

    public func load(_ voice: VoiceHandle, blob: Data) async throws {
        guard voice.mode == .system else { throw Failure.noConditioning }
    }

    public func report(_ p: PlayoutReport) async {}

    public func cancel(_ job: JobID) async {
        jobs.removeValue(forKey: job)?.stop()
    }

    private func register(_ job: JobID) -> Job {
        let j = Job()
        jobs[job] = j
        return j
    }

    private func finish(_ job: JobID) { jobs[job] = nil }

    public nonisolated func speak(_ r: TTSRequest) -> AsyncThrowingStream<TTSChunk, any Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                guard Self.locales[r.language] != nil else {
                    cont.finish(throwing: Failure.unsupportedLanguage(r.language.rawValue)); return
                }
                guard let info = Self.pickVoice(for: r.language, among: Self.installedVoices()),
                      let voice = AVSpeechSynthesisVoice(identifier: info.identifier) else {
                    cont.finish(throwing: Failure.noVoice(r.language.rawValue)); return
                }
                let job = await self.register(r.job)
                await Self.render(r, voice: voice, job: job, cont: cont)
                await self.finish(r.job)
            }
            cont.onTermination = { _ in
                task.cancel()
                Task { await self.cancel(r.job) }
            }
        }
    }

    /// Writes the utterance, converts every buffer to 24 kHz f32 mono and yields 0.16 s chunks.
    static func render(_ r: TTSRequest, voice: AVSpeechSynthesisVoice, job: Job,
                       cont: AsyncThrowingStream<TTSChunk, any Error>.Continuation) async {
        let received = HostClock.now()
        let utterance = AVSpeechUtterance(string: r.text)
        utterance.voice = voice
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        let state = RenderState(job: r.job, out: out, cont: cont)
        // A watchdog bounds the wait: the synthesizer may stop calling back (cancel, audio reset).
        let limitS = 10 + Double(r.text.count) * 0.15
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            state.onDone = { done.resume() }
            job.setOnStop { state.end() }
            Task.detached {
                try? await Task.sleep(for: .seconds(limitS))
                state.end(timeout: true)
            }
            job.synth.write(utterance) { buffer in
                state.consume(buffer, stopped: job.isStopped)
            }
        }
        if job.isStopped {
            cont.finish(throwing: CancellationError())
            return
        }
        if let error = state.error {
            cont.finish(throwing: error)
            return
        }
        let finished = HostClock.now()
        let summary = TTSSummary(audioS: Double(state.frames) / 24_000, frames: state.frames,
                                 timing: StageTiming(received: received, started: received,
                                                     firstOutput: state.firstOutput, finished: finished))
        state.flush(summary: summary, at: finished)
        cont.finish()
    }

    /// Mutable state of one render, touched only from the synthesizer's callback queue.
    final class RenderState: @unchecked Sendable {
        let job: JobID
        let out: AVAudioFormat
        let cont: AsyncThrowingStream<TTSChunk, any Error>.Continuation
        var converter: AVAudioConverter?
        var pending: [Float] = []
        var seq = 0
        var frames = 0
        var firstOutput: HostTime?
        var error: (any Error)?
        var onDone: (() -> Void)?
        private let lock = NSLock()
        private var ended = false

        init(job: JobID, out: AVAudioFormat, cont: AsyncThrowingStream<TTSChunk, any Error>.Continuation) {
            self.job = job; self.out = out; self.cont = cont
        }

        func end(timeout: Bool = false) {
            let first = lock.withLock { () -> Bool in
                guard !ended else { return false }
                ended = true
                if timeout { error = Failure.timeout }
                return true
            }
            if first { onDone?() }
        }

        func consume(_ buffer: AVAudioBuffer, stopped: Bool) {
            guard !lock.withLock({ ended }) else { return }
            guard !stopped, let pcm = buffer as? AVAudioPCMBuffer else { end(); return }
            if pcm.frameLength == 0 { end(); return }          // the last callback has an empty buffer
            if converter == nil { converter = AVAudioConverter(from: pcm.format, to: out) }
            guard let converter else { error = Failure.conversion; end(); return }
            let ratio = out.sampleRate / pcm.format.sampleRate
            let cap = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
            guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { error = Failure.conversion; end(); return }
            var fed = false
            var err: NSError?
            converter.convert(to: dst, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return pcm
            }
            if err != nil { error = Failure.conversion; end(); return }
            guard let ch = dst.floatChannelData?[0] else { return }
            pending.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(dst.frameLength)))
            frames += Int(dst.frameLength)
            while pending.count >= SystemVoiceTTS.chunkSamples {
                let chunk = Array(pending.prefix(SystemVoiceTTS.chunkSamples))
                pending.removeFirst(SystemVoiceTTS.chunkSamples)
                emit(chunk, isLast: false, summary: nil, at: HostClock.now())
            }
        }

        func flush(summary: TTSSummary, at t: HostTime) {
            emit(pending, isLast: true, summary: summary, at: t)
            pending = []
        }

        private func emit(_ samples: [Float], isLast: Bool, summary: TTSSummary?, at t: HostTime) {
            if firstOutput == nil { firstOutput = t }
            cont.yield(TTSChunk(job: job, seq: seq, samples24k: samples, isLast: isLast, producedAt: t, summary: summary))
            seq += 1
        }
    }
}
