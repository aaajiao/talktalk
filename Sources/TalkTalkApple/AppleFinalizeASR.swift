@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
import TalkTalkCore

/// Clip ASR fallback (§4.1 `ClipASREngine`, §4.2): when the engine host's Qwen3-ASR is absent or
/// late, a clip from the 16 kHz ring is transcribed by a fresh SpeechAnalyzer fed at full speed and
/// finalized through its end. LISTEN uses it as the second-pass slot's stand-in (the real second
/// pass is RemoteQwenASR, talktalk-m0); SPEAK uses it for "Apple `finalize(through:)` + ring replay".
public final class AppleFinalizeASR: ClipASREngine, @unchecked Sendable {
    public let id = EngineID(name: "apple-speech-clip", revision: "SpeechTranscriber", placement: .systemService)

    private let lock = NSLock()
    private var jobs: [JobID: Task<ASRFinal, Error>] = [:]

    public init() {}

    public enum Failure: Error, Sendable, Equatable { case deadline, empty }

    public func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, job: JobID,
                           priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        let received = HostClock.now()
        let task = Task { try await Self.run(clip, hint, priority, received: received) }
        lock.withLock { jobs[job] = task }
        defer { _ = lock.withLock { jobs.removeValue(forKey: job) } }
        var timer: Task<Void, Never>?
        if let deadline {
            let wait = deadline > received ? Double(deadline - received) / 1e9 : 0
            timer = Task { try? await Task.sleep(for: .seconds(wait)); task.cancel() }
        }
        defer { timer?.cancel() }
        do { return try await task.value }
        catch is CancellationError where deadline.map({ HostClock.now() >= $0 }) ?? false { throw Failure.deadline }
    }

    public func cancel(_ job: JobID) async {
        lock.withLock { jobs[job] }?.cancel()
    }

    static func run(_ clip: PCMClip16k, _ lang: Lang, _ priority: Priority, received: HostTime) async throws -> ASRFinal {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: AppleSpeechASR.localeIdentifier(lang)),
                                            transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                         considering: AppleSpeechStream.int16Mono) else {
            throw AppleSpeechASR.Failure.noCompatibleFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: priority <= .p1Speak ? .userInitiated : .medium,
                                                     modelRetention: .processLifetime))
        return try await withTaskCancellationHandler {
            try await analyzer.prepareToAnalyze(in: format)
            let started = HostClock.now()
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            let results = transcriber.results
            let collector = Task { () -> (String, HostTime?) in
                var parts: [String] = []
                var first: HostTime?
                do {
                    for try await r in results where r.isFinal {
                        let t = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { parts.append(t); if first == nil { first = HostClock.now() } }
                    }
                } catch {}
                return (parts.joined(separator: " "), first)
            }
            for (start, buffer) in try buffers(clip.samples, format: format) {
                input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: start, timescale: 16_000)))
            }
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let (text, first) = await collector.value
            try Task.checkCancellation()
            return ASRFinal(text: text, language: lang,
                            timing: StageTiming(received: received, started: started, firstOutput: first, finished: HostClock.now()))
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// 0.5 s Int16 buffers (converted when the analyzer wants another format), with 16 kHz start frames.
    static func buffers(_ samples: [Float], format: AVAudioFormat) throws -> [(Int64, AVAudioPCMBuffer)] {
        let step = 8_000
        let converter = format == AppleSpeechStream.int16Mono ? nil : AVAudioConverter(from: AppleSpeechStream.int16Mono, to: format)
        var out: [(Int64, AVAudioPCMBuffer)] = []
        var i = 0
        while i < samples.count {
            let n = min(step, samples.count - i)
            let src = AVAudioPCMBuffer(pcmFormat: AppleSpeechStream.int16Mono, frameCapacity: AVAudioFrameCount(n))!
            src.frameLength = AVAudioFrameCount(n)
            let p = src.int16ChannelData![0]
            for k in 0..<n { p[k] = Int16(clamping: Int((max(-1, min(1, samples[i + k])) * 32767).rounded())) }
            if let converter {
                let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(n) * format.sampleRate / 16_000) + 64)!
                nonisolated(unsafe) var given = false
                var err: NSError?
                converter.convert(to: dst, error: &err) { _, status in
                    if given { status.pointee = .noDataNow; return nil }
                    given = true; status.pointee = .haveData; return src
                }
                if let err { throw err }
                out.append((Int64(i), dst))
            } else {
                out.append((Int64(i), src))
            }
            i += n
        }
        return out
    }
}
