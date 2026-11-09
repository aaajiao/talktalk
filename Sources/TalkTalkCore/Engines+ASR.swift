import Foundation

// §4.1 protocol sketch, ASR subset (M1 LISTEN). Shapes as written in ARCHITECTURE.md §4.1;
// the MT subset is in Engines.swift (talktalk-swift), TTS / E2E arrive with M2.

public struct PCMClip16k: Sendable {
    public var samples: [Float]
    public var start, end: HostTime
    public init(samples: [Float], start: HostTime, end: HostTime) {
        self.samples = samples; self.start = start; self.end = end
    }
}

public enum ASREvent: Sendable, Equatable {
    case volatile(String, through: HostTime)
    case final(String, range: ClosedRange<HostTime>)
}

public protocol ASRStream: AnyObject, Sendable {
    /// Called on the audio-worker thread; never blocks.
    func feed(_ frames: UnsafeBufferPointer<Int16>, at: HostTime)
    func finalize(through: HostTime) async
    /// `.bufferingNewest(1)`: a slow consumer only sees the latest hypothesis.
    var volatileEvents: AsyncStream<ASREvent> { get }
    /// `.bufferingOldest(64)`: finals are never dropped silently; overflow is logged.
    var finalEvents: AsyncStream<ASREvent> { get }
    /// Always finalizes or cancels, releasing the recognizer slot.
    func close() async
    /// Discards pending recognition and waits until the recognizer slot is released. Use when
    /// no consumer needs a final result, including session end and obsolete initialization.
    func cancel() async
}

public extension ASRStream {
    /// Backends without a distinct discard path retain their existing shutdown behavior.
    func cancel() async { await close() }
}

public protocol StreamingASREngine: Sendable {                      // AppleSpeechASR
    var id: EngineID { get }
    /// Expected spacing of cumulative partial updates. Zero keeps the ordinary streaming
    /// policy; a batched recognizer must not have its normal cadence mistaken for a word pause.
    var partialUpdateIntervalMs: Int { get }
    func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream
}

public extension StreamingASREngine {
    var partialUpdateIntervalMs: Int { 0 }
}

public struct ASRFinal: Sendable {
    public var text: String
    public var language: Lang?
    public var timing: StageTiming
    public init(text: String, language: Lang?, timing: StageTiming) {
        self.text = text; self.language = language; self.timing = timing
    }
}

public protocol ClipASREngine: Sendable {                            // RemoteQwenASR (engine host); fallback AppleFinalizeASR
    var id: EngineID { get }
    func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, job: JobID,
                    priority: Priority, deadline: HostTime?) async throws -> ASRFinal
    /// `pinnedText` is the start of the transcript, as an earlier reading of this audio wrote it.
    /// A backend may ignore it, so callers must accept a reading that restates it in other words.
    func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, pinnedText: String?, job: JobID,
                    priority: Priority, deadline: HostTime?) async throws -> ASRFinal
    func cancel(_ job: JobID) async
}

public extension ClipASREngine {
    func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, pinnedText: String?, job: JobID,
                    priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        try await transcribe(clip, hint: hint, context: context, job: job, priority: priority, deadline: deadline)
    }
}
