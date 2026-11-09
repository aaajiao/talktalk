import Foundation

// §4.1 protocol sketch, MT subset only (M0). The ASR/TTS/E2E protocols arrive with M1/M2;
// their shapes are already fixed in ARCHITECTURE.md §4.1 and must be added there verbatim.
//
// The four hedge structs below have exactly the field names of PolicyProfile (§5.3) and are
// decoded straight from the JSON; there is no second set of defaults in Swift.

public typealias HostTime = UInt64              // ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
public typealias JobID = UInt64

public enum Lang: String, Codable, Sendable, CaseIterable { case zh, en, de }

public struct Direction: Hashable, Codable, Sendable {
    public var source: Lang
    public var target: Lang
    public init(source: Lang, target: Lang) { self.source = source; self.target = target }
}

public enum Priority: Int, Codable, Sendable, Comparable {
    case p0TTS = 0, p1Speak, p2Listen, p3Background
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum Placement: String, Codable, Sendable { case systemService, engineGPU, cpu, network }

public struct EngineID: Hashable, Codable, Sendable {
    public var name: String
    public var revision: String
    public var placement: Placement
    public init(name: String, revision: String, placement: Placement) {
        self.name = name; self.revision = revision; self.placement = placement
    }
}

public struct StageTiming: Codable, Sendable {
    public var received, started: HostTime
    public var firstOutput: HostTime?
    public var finished: HostTime
    public init(received: HostTime, started: HostTime, firstOutput: HostTime?, finished: HostTime) {
        self.received = received; self.started = started; self.firstOutput = firstOutput; self.finished = finished
    }
}

// MT ───────────────────────────────────────────────

public enum MTSession: String, Codable, Sendable, CaseIterable {
    case speakZhEn, speakZhDe, speakEnZh, speakEnDe
    case listenEnZh, listenDeZh, listenZhEn, listenZhDe, listenEnDe, listenDeEn

    public var direction: Direction {
        switch self {
        case .speakZhEn: Direction(source: .zh, target: .en)
        case .speakZhDe: Direction(source: .zh, target: .de)
        case .speakEnZh: Direction(source: .en, target: .zh)
        case .speakEnDe: Direction(source: .en, target: .de)
        case .listenEnZh: Direction(source: .en, target: .zh)
        case .listenDeZh: Direction(source: .de, target: .zh)
        case .listenZhEn: Direction(source: .zh, target: .en)
        case .listenZhDe: Direction(source: .zh, target: .de)
        case .listenEnDe: Direction(source: .en, target: .de)
        case .listenDeEn: Direction(source: .de, target: .en)
        }
    }

    public var isSpeak: Bool {
        switch self {
        case .speakZhEn, .speakZhDe, .speakEnZh, .speakEnDe: true
        case .listenEnZh, .listenDeZh, .listenZhEn, .listenZhDe, .listenEnDe, .listenDeEn: false
        }
    }

    /// Subtitles support every non-identical pair among Chinese, English and German.
    public static func listen(source: Lang, target: Lang) -> MTSession? {
        switch (source, target) {
        case (.zh, .en): .listenZhEn
        case (.zh, .de): .listenZhDe
        case (.en, .zh): .listenEnZh
        case (.en, .de): .listenEnDe
        case (.de, .zh): .listenDeZh
        case (.de, .en): .listenDeEn
        default: nil
        }
    }

    /// Explicit speaking directions. German is a target only, never a microphone source.
    public static func speak(source: Lang, target: Lang) -> MTSession? {
        switch (source, target) {
        case (.zh, .en): .speakZhEn
        case (.zh, .de): .speakZhDe
        case (.en, .zh): .speakEnZh
        case (.en, .de): .speakEnDe
        default: nil
        }
    }
}

public enum MTMode: String, Codable, Sendable { case normal, concise, summarize }

public struct GlossaryEntry: Codable, Sendable, Equatable {
    public var zh, en, de: String
    public var note: String?
    public init(zh: String, en: String, de: String, note: String? = nil) {
        self.zh = zh; self.en = en; self.de = de; self.note = note
    }
    public func rendering(for lang: Lang) -> String {
        switch lang { case .zh: zh; case .en: en; case .de: de }
    }
}

/// One spoken (source, target) pair.
public struct MTTurn: Codable, Sendable, Equatable {
    public var source, target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}

public struct MTRequest: Codable, Sendable {
    public var job: JobID; public var session: MTSession; public var text: String
    public var isFinalChunk: Bool; public var mode: MTMode; public var priority: Priority
    public var deadline: HostTime?; public var maxOutputTokens: Int
    /// Give up at this time if the backend has not started to answer; `deadline` still bounds
    /// one that has. Nil applies `deadline` alone.
    public var replyBy: HostTime?
    public var history: [MTTurn]
    public var replaces: JobID?
    public var strictTerms: [String]
    public var merges: [JobID]

    public init(job: JobID, session: MTSession, text: String, isFinalChunk: Bool, mode: MTMode = .normal,
                priority: Priority, deadline: HostTime? = nil, replyBy: HostTime? = nil, maxOutputTokens: Int, history: [MTTurn] = [],
                replaces: JobID? = nil, strictTerms: [String] = [], merges: [JobID] = []) {
        self.job = job; self.session = session; self.text = text; self.isFinalChunk = isFinalChunk
        self.mode = mode; self.priority = priority; self.deadline = deadline; self.replyBy = replyBy
        self.maxOutputTokens = maxOutputTokens; self.history = history; self.replaces = replaces
        self.strictTerms = strictTerms; self.merges = merges
    }
}

public enum HedgeWinner: String, Codable, Sendable { case A, B, apple }
public enum HedgeReason: String, Codable, Sendable { case noDelta, stall, fastFail, failAfterDelta, guardRetry }

/// Same fields as the event mt.hedge{fired, winner, ms, reason}. Results only, never text.
public struct HedgeOutcome: Codable, Sendable, Equatable {
    public var fired: Bool; public var winner: HedgeWinner; public var reason: HedgeReason?; public var ms: Int
    public init(fired: Bool, winner: HedgeWinner, reason: HedgeReason?, ms: Int) {
        self.fired = fired; self.winner = winner; self.reason = reason; self.ms = ms
    }
}

public struct MTResult: Sendable {
    public var text: String; public var tokens: Int; public var reasoningTokens: Int
    public var engine: EngineID; public var hedge: HedgeOutcome; public var timing: StageTiming
    // Public so MTEngine implementations outside Core can build results (m1-listen: AppleTranslationMT).
    public init(text: String, tokens: Int, reasoningTokens: Int, engine: EngineID, hedge: HedgeOutcome, timing: StageTiming) {
        self.text = text; self.tokens = tokens; self.reasoningTokens = reasoningTokens
        self.engine = engine; self.hedge = hedge; self.timing = timing
    }
}

public enum HedgeTrigger: String, Codable, Sendable { case firstTextDelta }

/// = speak.mt.hedge. listen.finalMT.hedge takes missing fields from speak (PolicyProfile).
public struct HedgeConfig: Codable, Sendable, Equatable {
    public var enabled: Bool; public var on: HedgeTrigger; public var afterMs: Int; public var stallAfterDeltaMs: Int
    public var maxInFlight: Int; public var fastFailHedge: Bool; public var failAfterDeltaMinRemainMs: Int
    public var startAppleAtHedge: Bool; public var pauseAfter429S: Int
}

/// = speak.mt.extendToDrain
public struct ExtendToDrain: Codable, Sendable, Equatable {
    public var enabled: Bool; public var ttsFirstChunkMs: String /* "rollingP95" */; public var marginMs: Int
    public var unrenderedFactor: Double; public var inFlightFactor: Double; public var maxDeadlineMs: Int
    public var subtractAppleP95WhenLate: Bool
}

/// = speak.mt.guardRetry
public struct GuardRetry: Codable, Sendable, Equatable {
    public var hedgeAfterMs: Int; public var floorMs: Int; public var fromDrain: Bool; public var maxMs: Int; public var onlyIfMaskedMs: Int
}

/// = these four keys of speak.mt. Decodes directly from the speak.mt JSON object (other keys
/// are ignored). The decisions are pure functions in HedgePolicy+Decisions.swift.
public struct HedgePolicy: Codable, Sendable, Equatable {
    public var hedge: HedgeConfig; public var totalDeadlineMs: Int; public var extendToDrain: ExtendToDrain; public var guardRetry: GuardRetry
}

public enum MTError: Error, Sendable, Equatable {
    case cloudUnavailable(String)
}

public protocol MTEngine: Sendable {
    var id: EngineID { get }
    func translate(_ r: MTRequest) async throws -> MTResult
    func setContext(_ s: MTSession, glossary: [GlossaryEntry]) async throws
    func cancel(_ job: JobID) async
}
