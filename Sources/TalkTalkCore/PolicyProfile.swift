import Foundation

/// Every policy threshold (ARCHITECTURE.md §5.3). Field names are exactly the JSON keys of
/// `Resources/PolicyProfile.default.json`; there are no Swift defaults. PolicyProfileTests
/// decodes the file, re-encodes it and requires the result to equal the file, so a key that
/// the Swift types forget fails the test.
///
/// One rule beyond plain decoding: `listen.finalMT.hedge` may omit fields; the missing ones
/// take speak.mt.hedge's values (§4.1). The resolved value is `listenFinalHedge`.
public struct PolicyProfile: Codable, Sendable, Equatable {
    public var listen: Listen
    public var speak: Speak
    public var cloud: Cloud

    /// listen.finalMT.hedge with missing fields filled from speak.mt.hedge (resolved at decode).
    public let listenFinalHedge: HedgeConfig

    private enum CodingKeys: String, CodingKey { case listen, speak, cloud }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listen = try c.decode(Listen.self, forKey: .listen)
        speak = try c.decode(Speak.self, forKey: .speak)
        cloud = try c.decode(Cloud.self, forKey: .cloud)
        listenFinalHedge = listen.finalMT.hedge.resolved(over: speak.mt.hedge)
    }

    /// The SPEAK hedge policy (§4.1): speak.mt.{hedge,totalDeadlineMs,extendToDrain,guardRetry}.
    public var speakHedgePolicy: HedgePolicy {
        HedgePolicy(hedge: speak.mt.hedge, totalDeadlineMs: speak.mt.totalDeadlineMs,
                    extendToDrain: speak.mt.extendToDrain, guardRetry: speak.mt.guardRetry)
    }

    /// LISTEN: resolved hedge (off by default), deadline from listen.finalMT.deadlineMs and no
    /// extension to drain (LISTEN has no playout queue); guardRetry is shared with SPEAK.
    public var listenHedgePolicy: HedgePolicy {
        var drain = speak.mt.extendToDrain
        drain.enabled = false
        return HedgePolicy(hedge: listenFinalHedge, totalDeadlineMs: listen.finalMT.deadlineMs,
                           extendToDrain: drain, guardRetry: speak.mt.guardRetry)
    }

    public static func decode(_ data: Data) throws -> PolicyProfile {
        try JSONDecoder().decode(PolicyProfile.self, from: data)
    }

    public static func load(from url: URL) throws -> PolicyProfile {
        try decode(Data(contentsOf: url))
    }

    /// `Contents/Resources/PolicyProfile.default.json` of the running app (no Bundle.module, §2.2).
    public static func loadDefault() throws -> PolicyProfile {
        try load(from: ResourceLocator.url(for: "PolicyProfile.default.json"))
    }
}

// MARK: - listen

extension PolicyProfile {
    public struct Listen: Codable, Sendable, Equatable {
        public var draft: Draft
        public var finalize: Finalize
        public var finalMT: FinalMT
        public var secondPassASR: Bool
        public var deLookback: DeLookback
        public var display: Display
        public var echoFilter: EchoFilter

        public struct Draft: Codable, Sendable, Equatable {
            public var minNewWords: Int; public var maxIntervalMs: Int; public var maxUpdatesPerS: Int
        }
        public struct Finalize: Codable, Sendable, Equatable {
            public var punctPauseMs: Int
            public var silenceMs: [String: Int]
            public var force: Force
            public var stallMs: Int; public var stallMsAfter8s: Int; public var hardCapS: Int
            public struct Force: Codable, Sendable, Equatable {
                public var minWords: Int; public var pauseMs: Int; public var pauseMsAfter8s: Int
            }
            public func silenceMs(for lang: Lang) -> Int? { silenceMs[lang.rawValue] }
        }
        public struct FinalMT: Codable, Sendable, Equatable {
            public var deadlineMs: Int; public var deadlineFrom: String; public var secondPassBudgetMs: Int
            public var maxOutputTokens: Int; public var contextTokensSoft: Int; public var contextTokensHard: Int
            public var retries: Int
            public var hedge: PartialHedgeConfig
        }
        public struct DeLookback: Codable, Sendable, Equatable { public var enabled: Bool; public var windowMs: Int }
        public struct Display: Codable, Sendable, Equatable { public var lines: Int; public var maxCps: Int }
        public struct EchoFilter: Codable, Sendable, Equatable {
            public var overlap: Double; public var windowS: Int; public var afterPlayS: Int
        }
    }

    /// listen.finalMT.hedge as written: any field may be missing.
    public struct PartialHedgeConfig: Codable, Sendable, Equatable {
        public var enabled: Bool?; public var on: HedgeTrigger?; public var afterMs: Int?; public var stallAfterDeltaMs: Int?
        public var maxInFlight: Int?; public var fastFailHedge: Bool?; public var failAfterDeltaMinRemainMs: Int?
        public var startAppleAtHedge: Bool?; public var pauseAfter429S: Int?

        public func resolved(over base: HedgeConfig) -> HedgeConfig {
            HedgeConfig(enabled: enabled ?? base.enabled, on: on ?? base.on, afterMs: afterMs ?? base.afterMs,
                        stallAfterDeltaMs: stallAfterDeltaMs ?? base.stallAfterDeltaMs,
                        maxInFlight: maxInFlight ?? base.maxInFlight, fastFailHedge: fastFailHedge ?? base.fastFailHedge,
                        failAfterDeltaMinRemainMs: failAfterDeltaMinRemainMs ?? base.failAfterDeltaMinRemainMs,
                        startAppleAtHedge: startAppleAtHedge ?? base.startAppleAtHedge,
                        pauseAfter429S: pauseAfter429S ?? base.pauseAfter429S)
        }
    }
}

// MARK: - speak

extension PolicyProfile {
    public struct Speak: Codable, Sendable, Equatable {
        public var ptt: PTT
        public var boundary: Boundary
        public var commitMin: CommitMin
        public var fillers: [String]
        public var forceCut: ForceCut
        public var release: Release
        public var gate: Gate
        public var mt: MT
        public var tts: TTS
        public var backlog: Backlog
        public var floor: Floor
        public var passthrough: Passthrough
        public var de: LangOverride?

        /// commitMin with the per-language override applied (§5.3 "de").
        public func commitMin(for lang: Lang) -> CommitMin {
            guard lang == .de, let o = de?.commitMin else { return commitMin }
            var c = commitMin
            if let v = o.estCjk { c.estCjk = v }
            if let v = o.defaultCjkPerS { c.defaultCjkPerS = v }
            if let v = o.speechS { c.speechS = v }
            if let v = o.sinceOnsetS { c.sinceOnsetS = v }
            if let v = o.previewVetoCaughtUpMs { c.previewVetoCaughtUpMs = v }
            return c
        }

        public struct PTT: Codable, Sendable, Equatable {
            public var minHoldMs: Int; public var prerollMs: Int; public var tailMs: Int; public var maxHoldS: Int
            public var chordCancelWindowMs: Int; public var chordCancelOnlyBeforeFirstCommit: Bool
            public var doubleTap: DoubleTap
            public struct DoubleTap: Codable, Sendable, Equatable {
                public var maxPressMs: Int; public var maxGapMs: Int; public var requireNoVad: Bool
            }
        }
        public struct Boundary: Codable, Sendable, Equatable {
            public var punct: String; public var punctHoldMs: Int; public var vadSilenceMs: Int; public var stallMs: Int
            public var punctOnlyAdvances: Bool
        }
        public struct CommitMin: Codable, Sendable, Equatable {
            public var estCjk: Int; public var defaultCjkPerS: Double; public var speechS: Double
            public var sinceOnsetS: Double; public var previewVetoCaughtUpMs: Int
        }
        public struct PartialCommitMin: Codable, Sendable, Equatable {
            public var estCjk: Int?; public var defaultCjkPerS: Double?; public var speechS: Double?
            public var sinceOnsetS: Double?; public var previewVetoCaughtUpMs: Int?
        }
        public struct LangOverride: Codable, Sendable, Equatable { public var commitMin: PartialCommitMin? }
        public struct ForceCut: Codable, Sendable, Equatable {
            public var cjk: Int; public var sinceLastS: Double; public var dipMs: Int; public var clipMaxS: Double
            public var clipMaxSUntilSteppedASR: Double; public var minEnergyWindowMs: Int
        }
        public struct Release: Codable, Sendable, Equatable { public var commitRemainderMinSpeechS: Double }
        public struct Gate: Codable, Sendable, Equatable {
            public var minHanRatio: Double
            public var speakerMode: SpeakerMode
            public struct SpeakerMode: Codable, Sendable, Equatable {
                public var remoteOverlapMax: Double; public var latinMatchWindowS: Int
            }
        }
        public struct MT: Codable, Sendable, Equatable {
            public var maxOutputTokens: [String: Int]
            public var hedge: HedgeConfig
            public var totalDeadlineMs: Int
            public var extendToDrain: ExtendToDrain
            public var afterNewlineGraceMs: Int
            public var guardRetry: GuardRetry
            public var retries: Int
            public var contextTokensSoft: Int; public var contextTokensHard: Int
            public var numberGuard: String
            public var targetGate: TargetGate
            public struct TargetGate: Codable, Sendable, Equatable {
                public var minLatinLetters: Int; public var langIdMinConf: Double; public var langIdMinWords: Int
                public var retryOnce: Bool; public var translitMaxHanRun: Int
            }
            public func maxOutputTokens(for lang: Lang) -> Int? { maxOutputTokens[lang.rawValue] }
        }
        public struct TTS: Codable, Sendable, Equatable {
            public var mergeWindowMs: Int; public var mergeMaxWords: Int; public var streamingIntervalS: Double
            public var interClauseGapMs: Int; public var renderHorizonMs: Int; public var ringOAheadMs: Int
            public var wholeClauseBelowExpectedS: Double; public var wholeClauseMaxAttempts: Int
            public var startAtFirstChunkIfRtfBelow: Double; public var elsePrerollMs: Int; public var degradedPrerollMs: Int
            public var rebuffer: Rebuffer; public var leadTrim: LeadTrim; public var tailTrim: TailTrim
            public var runaway: Runaway; public var slow: Slow; public var shortFactor: Double; public var leadEcho: LeadEcho
            public struct Rebuffer: Codable, Sendable, Equatable {
                public var minMs: Int; public var p95IntervalFactor: Double; public var doubleWithinS: Int; public var maxMs: Int
            }
            public struct LeadTrim: Codable, Sendable, Equatable { public var thresholdDbfs: Double; public var maxMs: Int }
            public struct TailTrim: Codable, Sendable, Equatable {
                public var thresholdDbfs: Double; public var holdMaxMs: Int; public var keepMs: Int
            }
            public struct Runaway: Codable, Sendable, Equatable {
                public var factor: Double; public var extraS: Double; public var calibrateInM0: Bool
            }
            public struct Slow: Codable, Sendable, Equatable { public var ratio: Double; public var tempo: Double }
            public struct LeadEcho: Codable, Sendable, Equatable { public var framesChecked: Int; public var matchRatio: Double }
        }
        public struct Backlog: Codable, Sendable, Equatable {
            public var baseTempo: [String: Double]
            public var q3: Q3; public var q5: Q5; public var q8: String; public var q12: String
            public var tempoMax: Double; public var hysteresisS: Double
            public struct Q3: Codable, Sendable, Equatable { public var tempoStep: Double; public var dropGaps: Bool }
            public struct Q5: Codable, Sendable, Equatable { public var tempo: Double; public var mt: String }
        }
        public struct Floor: Codable, Sendable, Equatable {
            public var ignoreMs: Int; public var finishMaxS: Double; public var resumeAfterRemoteSilenceMs: Int
            public var rearmAfterResumeS: Double; public var echoScoreMax: Double; public var echoLagMs: [Int]
            public var energyAboveFloorDb: Double; public var minNonEchoWords: Int; public var autoClear: Bool
            public var offerClearAfterS: Int
        }
        public struct Passthrough: Codable, Sendable, Equatable {
            public var enabled: Bool; public var key: String; public var altKey: String; public var armHoldMs: Int
            public var maxHoldS: Int; public var countdownS: Int; public var requireHidSource: Bool
            public var denyIfSpeechBeforeOpen: Bool; public var mouseMoveMaxPt: Int; public var coldMicPreOpenVadMs: Int
            public var finishClauseMaxMs: Int; public var clauseCutFadeMs: Int; public var fadeInMs: Int; public var fadeOutMs: Int
            public var leaseMs: Int; public var keyPollMs: Int; public var workerPollMs: Int
            public var ringP: RingP; public var gainDb: GainDb; public var limiterDbtp: Double
            public var resumeAfterCloseMs: Int; public var echoDropAfterCloseS: Int; public var cues: Cues
            public var allowInSpeakerMode: Bool
            public struct RingP: Codable, Sendable, Equatable { public var capacityMs: Int; public var startMs: Int; public var maxFillMs: Int }
            public struct GainDb: Codable, Sendable, Equatable {
                public var targetLufs: Double; public var min: Double; public var max: Double; public var uncalibrated: Double
            }
            public struct Cues: Codable, Sendable, Equatable {
                public var enabled: Bool; public var beforeOpen: Bool; public var headphonesOnly: Bool
                public var dbfs: Double; public var ms: Int
            }
        }
    }
}

// MARK: - cloud

extension PolicyProfile {
    public struct Cloud: Codable, Sendable, Equatable {
        public var origin: String; public var responsesPath: String; public var modelsPath: String
        public var model: String; public var effort: String; public var temperature: Double; public var store: Bool
        public var serviceTier: String; public var stream: Bool
        public var sessions: Sessions
        public var keepWarmPath: String; public var keepWarmIntervalS: Int; public var rewarmOnKeyDownIdleS: Int
        public var requestTimeoutS: Int
        public var breaker: Breaker
        public var timeoutBreaker: TimeoutBreaker
        public var sessionReset: SessionReset
        public var pauseOn: PauseOn
        public var rateLimitOnly: RateLimitOnly

        public struct Sessions: Codable, Sendable, Equatable {
            public var primary: String; public var hedge: String; public var warmBOnlyIfAnyHedgeEnabled: Bool
        }
        public struct Breaker: Codable, Sendable, Equatable {
            public var failuresToOpen: Int; public var windowS: Int; public var openS: Int; public var honorRetryAfter: Bool
            public var openOnPrimary429: Bool; public var hedgeFiredIsFailure: Bool; public var counts: [String]
            public var lateIsFailure: Bool
        }
        public struct TimeoutBreaker: Codable, Sendable, Equatable {
            public var perDirection: Bool; public var timeoutsToOpen: Int; public var windowS: Int; public var openS: Int
        }
        public struct SessionReset: Codable, Sendable, Equatable {
            public var hedgeWinsWithoutPrimaryHeaders: Int; public var keepWarmFailuresInARow: Int
            public var listenNoHeadersMs: Int; public var listenNoHeadersInARow: Int; public var onWake: Bool; public var onPathChange: Bool
        }
        public struct PauseOn: Codable, Sendable, Equatable {
            public var status: [Int]; public var errorCode: [String]; public var errorType: [String]
        }
        public struct RateLimitOnly: Codable, Sendable, Equatable {
            public var errorCode: [String]; public var honorRetryAfter: Bool
        }

        /// origin + path, never producing `/v1/v1/` (§5.3).
        public func url(_ path: String) -> URL? {
            var o = origin
            while o.hasSuffix("/") { o.removeLast() }
            let p = path.hasPrefix("/") ? path : "/" + path
            return URL(string: o + p)
        }

        public func keepWarmURL(model: String) -> URL? {
            url(keepWarmPath.replacingOccurrences(of: "{model}", with: model))
        }
    }
}

/// Finds files that build-app.sh copies into `Contents/Resources` (no SwiftPM resources, §2.2).
/// Search order: the app bundle's Resources, then `TALKTALK_RESOURCES_DIR` (tests and bare
/// `swift run` only; never set by the app), then `Resources/` next to the current directory.
public enum ResourceLocator {
    public struct NotFound: Error, CustomStringConvertible, Sendable {
        public let name: String
        public var description: String { "resource \(name) not found" }
    }

    public static func url(for relativePath: String) throws -> URL {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(relativePath)) }
        if let d = ProcessInfo.processInfo.environment["TALKTALK_RESOURCES_DIR"] {
            candidates.append(URL(fileURLWithPath: d).appendingPathComponent(relativePath))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources").appendingPathComponent(relativePath))
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c }
        throw NotFound(name: relativePath)
    }
}
