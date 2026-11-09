import Foundation
import Synchronization

// M2 seams (§4.1). Engines stay behind Core protocols so TalkTalkSession does not depend on
// Cloud, EngineHost or Voice. HostTime is the capture/key event time, never actor arrival time.

/// Shared by LISTEN and SPEAK for the lifetime of their shared cloud instance. Job IDs must
/// not restart on a new press or collide across directions (OpenAIMT cancels by JobID).
public final class JobIDSequence: Sendable {
    private let value: Mutex<JobID>
    public init(start: JobID = 1) { value = Mutex(start) }
    public func next() -> JobID {
        value.withLock { current in
            precondition(current < JobID.max, "Job IDs exhausted")
            defer { current += 1 }
            return current
        }
    }
}

public struct SpeakMicState: Sendable, Equatable {
    public enum Capture: Sendable { case open, closed, noDevice }
    public var capture: Capture
    public var physicalMicPassesRule2: Bool
    public init(capture: Capture, physicalMicPassesRule2: Bool) {
        self.capture = capture; self.physicalMicPassesRule2 = physicalMicPassesRule2
    }
}

public struct SpeakClip: Sendable {
    public enum CutReason: String, Sendable { case release, vadDip, energyMinimum, limit, shortReply }
    public var pcm: PCMClip16k
    public var index: Int
    public var isFinal: Bool
    public var speechMs: Int
    public var cutReason: CutReason
    public init(pcm: PCMClip16k, index: Int, isFinal: Bool, speechMs: Int, cutReason: CutReason) {
        self.pcm = pcm; self.index = index; self.isFinal = isFinal
        self.speechMs = speechMs; self.cutReason = cutReason
    }
}

/// Owns its 16 kHz mono samples; pointers never cross from the mic worker to an actor.
public struct SpeakPreviewFrame: Sendable {
    public var samples: [Int16]
    public var at: HostTime
    public var level: Float
    public init(samples: [Int16], at: HostTime, level: Float) {
        self.samples = samples; self.at = at; self.level = level
    }
}

/// Evidence about the whole current hypothesis, rather than its potentially stale stable
/// prefix. Used only to authorize the conservative short-reply boundary, never as ASR text.
public struct SpeakPreviewBoundary: Sendable {
    public var from: HostTime
    public var fullyStable: Bool
    public init(from: HostTime, fullyStable: Bool) { self.from = from; self.fullyStable = fullyStable }
}

public protocol SpeakPressAudio: AnyObject, Sendable {
    /// Single consumer, floor-clamped clips. Finishing is authoritative: a silent or cancelled
    /// press may have no final clip. M2 queues these until release; M3 can commit while held.
    var clips: AsyncStream<SpeakClip> { get }
    /// Single consumer; pre-roll is clamped to the same privacy floor as clips.
    var preview: AsyncStream<SpeakPreviewFrame> { get }
    /// Idempotent, nonblocking; the mic worker captures any remaining tail before finishing.
    func release(at: HostTime, reason: PushToTalkMachine.ReleaseReason)
    /// Idempotent; discards the press and finishes both streams.
    func cancel()
    /// Stable preview for the uncommitted segment; time remains the recognizer's audio time.
    func updatePreview(stableText: String, through: HostTime, at: HostTime, isFinal: Bool)
    func updatePreview(stableText: String, through: HostTime, at: HostTime, isFinal: Bool,
                       boundary: SpeakPreviewBoundary)
}

extension SpeakPressAudio {
    public func updatePreview(stableText: String, through: HostTime, at: HostTime, isFinal: Bool) {}
    public func updatePreview(stableText: String, through: HostTime, at: HostTime, isFinal: Bool,
                              boundary: SpeakPreviewBoundary) {
        updatePreview(stableText: stableText, through: through, at: at, isFinal: isFinal)
    }
}

public protocol SpeakMicSource: AnyObject, Sendable {
    var state: SpeakMicState { get }
    /// Never opens HAL synchronously on the key thread. The returned press owns streams while
    /// the mic worker starts a cold capture; nil means capture cannot be requested.
    func beginPress(id: UInt64, keyDownAt: HostTime, passthroughClosedAt: HostTime?) -> (any SpeakPressAudio)?
}

public struct SpeakMTRequest: Sendable {
    public var clause, press: UInt64
    public var job: JobID
    public var text: String
    public var source: Lang
    public var target: Lang
    public var history: [MTTurn]
    public var mode: MTMode
    public var appleLate: Bool
    public var precedingAudioMs, maskedMs, ttsFirstChunkP95Ms: Int
    public init(clause: UInt64, press: UInt64, job: JobID, text: String, source: Lang = .zh, target: Lang,
                history: [MTTurn] = [], precedingAudioMs: Int = 0, maskedMs: Int = 0,
                ttsFirstChunkP95Ms: Int = 400, mode: MTMode = .normal, appleLate: Bool = false) {
        self.clause = clause; self.press = press; self.job = job; self.text = text; self.source = source; self.target = target
        self.history = history; self.mode = mode; self.appleLate = appleLate; self.precedingAudioMs = precedingAudioMs
        self.maskedMs = maskedMs; self.ttsFirstChunkP95Ms = ttsFirstChunkP95Ms
    }
}

public enum SpeakMTOutcome: Sendable, Equatable {
    public enum Block: Sendable { case gateRejected, numberMismatch, unavailable }
    case text(String, backend: HUDModel.MTSource, numberWarning: String?, hedge: HedgeOutcome?)
    case blocked(Block)
}

public protocol SpeakTranslator: Sendable {
    /// Backend failures become .blocked; cancellation throws CancellationError and emits no HUD.
    func translate(_ request: SpeakMTRequest) async throws -> SpeakMTOutcome
    func cancel(_ job: JobID) async
    func pressBegan() async
    func prepare(targets: [Lang]) async
    func prepare(source: Lang, targets: [Lang]) async
}

extension SpeakTranslator {
    public func prepare(source: Lang, targets: [Lang]) async { await prepare(targets: targets) }
}

/// Extra SPEAK facts passed into the existing cloud translator. Apple starts exactly when
/// the hedge requests it, not after the cloud request has already reached its deadline.
public struct SpeakCloudContext: Sendable {
    public var precedingAudioMs, maskedMs, ttsFirstChunkP95Ms: Int
    public var appleP95Ms: Int?
    public var appleLate: Bool
    public var onStartApple: @Sendable () -> Void
    public init(precedingAudioMs: Int, maskedMs: Int, ttsFirstChunkP95Ms: Int,
                appleP95Ms: Int? = nil, appleLate: Bool = false,
                onStartApple: @escaping @Sendable () -> Void) {
        self.precedingAudioMs = precedingAudioMs; self.maskedMs = maskedMs
        self.ttsFirstChunkP95Ms = ttsFirstChunkP95Ms; self.appleP95Ms = appleP95Ms
        self.appleLate = appleLate; self.onStartApple = onStartApple
    }
}

public protocol SpeakCloudMT: MTEngine {
    func translate(_ request: MTRequest, speak: SpeakCloudContext) async throws -> MTResult
    func keyDown() async
}

/// App reads its voice routing once per clause and supplies a consistent snapshot. Pending
/// clone voices stay .down: ClauseLedger decides whether to wait, stay silent or use system.
/// .ready(handle) requires a non-nil clone engine; systemHandle always has mode .system.
public struct SpeakVoiceSnapshot: Sendable {
    public var clone: (any TTSEngine)?
    public var system: any TTSEngine
    public var systemHandle: VoiceHandle
    public var cloneAvailability: ClauseLedger.CloneAvailability
    public var playoutGainDb: Double
    public var hudVoice: HUDModel.Voice
    public init(clone: (any TTSEngine)?, system: any TTSEngine, systemHandle: VoiceHandle,
                cloneAvailability: ClauseLedger.CloneAvailability, playoutGainDb: Double,
                hudVoice: HUDModel.Voice) {
        self.clone = clone; self.system = system; self.systemHandle = systemHandle
        self.cloneAvailability = cloneAvailability; self.playoutGainDb = playoutGainDb
        self.hudVoice = hudVoice
    }
}

public enum SpeakEngineStatus: Sendable { case lost, ready }

public protocol SpeakEngineControl: Sendable {
    /// Each access creates an independent subscription and first yields the current state.
    var status: AsyncStream<SpeakEngineStatus> { get }
    func pressActive(_ active: Bool) async
    func cancelSpeak() async
}

public protocol SpeakEchoSink: Sendable {
    func recordPlayed(text: String, startHost: HostTime, endHost: HostTime) async
    /// A clause's first sample reached the Feed. It counts as playing until `stopPlaying`, so a
    /// final released mid-playback can still be recognized as its echo.
    func recordPlaying(clause: UInt64, text: String, startHost: HostTime) async
    func stopPlaying(clause: UInt64) async
    func recordPassthrough(startHost: HostTime, endHost: HostTime) async
    func recentRemoteText(withinS: Double) async -> [String]
    /// nil means the interval was not observed; zero means observed with no remote speech.
    func remoteVADOverlap(from: HostTime, to: HostTime) async -> Double?
}

public extension SpeakEchoSink {
    func recordPlaying(clause: UInt64, text: String, startHost: HostTime) async {}
    func stopPlaying(clause: UInt64) async {}
}

/// One press's current display snapshot, independent of audio playback status. `isFinal`
/// means text work has settled, not that every word has been sent or heard by the meeting.
public struct SpeakTranscript: Sendable, Equatable {
    public var press: UInt64
    public var source: String
    public var target: String
    public var isFinal: Bool
    /// Preview-only tail not submitted to final recognition / translation.
    public var unsubmittedSource: String

    public init(press: UInt64, source: String, target: String, isFinal: Bool, unsubmittedSource: String = "") {
        self.press = press; self.source = source; self.target = target; self.isFinal = isFinal
        self.unsubmittedSource = unsubmittedSource
    }
}

public enum SpeakUIEvent: Sendable, Equatable {
    case transcript(SpeakTranscript)
    case pushToTalk(HUDModel.PushToTalk)
    /// Actual first-sample to end/cut playback, independent of simultaneous microphone input.
    case outputActivity(Bool)
    /// The presses whose translated audio is actually playing, so a turn is credited only
    /// with its own playback (never with the tail of an earlier press).
    case outputPresses(Set<UInt64>)
    case post(HUDModel.Warning)
    case clear(HUDModel.Warning)
    case pttAvailable(Bool)
}
