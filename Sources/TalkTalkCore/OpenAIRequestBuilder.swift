import Foundation

/// `Resources/prompts/mt.json` (§5.4). Only Swift reads it.
public struct MTPrompts: Codable, Sendable, Equatable {
    public var version: Int
    public var speak: Speak
    public var listen: [String: String]
    public var glossary: Glossary
    public var languageNames: [String: String]

    public struct Speak: Codable, Sendable, Equatable {
        public var zhDe: String
        public var zhEn: String
        public var enZh: String
        public var enDe: String
        public var concise: String
        public var summarize: [String: String]
        public var strictTerms: String
        public var strictTermsZh: String
        enum CodingKeys: String, CodingKey {
            case zhDe = "zh-de", zhEn = "zh-en", enZh = "en-zh", enDe = "en-de"
            case concise, summarize, strictTerms, strictTermsZh
        }
    }
    public struct Glossary: Codable, Sendable, Equatable { public var header: String; public var line: String }

    public static func load(from url: URL) throws -> MTPrompts {
        try JSONDecoder().decode(MTPrompts.self, from: Data(contentsOf: url))
    }
    public static func loadDefault() throws -> MTPrompts {
        try load(from: ResourceLocator.url(for: "prompts/mt.json"))
    }
}

/// Request bodies and response validation for the OpenAI Responses API (§5.4). Pure.
///
/// The body never contains `previous_response_id`, `conversation`, `background`, `tools`,
/// `include`, `metadata`, `top_p` or `prompt_cache_key`, and always contains `"store":false`.
/// It is serialized once with sorted keys, so the hedge copy B is byte-identical to A.
/// The Authorization header is not built here: only OpenAIClient adds it, from KeychainSecret.
public struct OpenAIRequestBuilder: Sendable {
    public var cloud: PolicyProfile.Cloud
    public var prompts: MTPrompts

    public init(cloud: PolicyProfile.Cloud, prompts: MTPrompts) {
        self.cloud = cloud
        self.prompts = prompts
    }

    public static let maxGlossaryEntries = 30
    public static let minOutputTokens = 16

    /// Fields the request body must never contain (tests assert their absence).
    public static let forbiddenKeys = ["previous_response_id", "conversation", "background", "tools",
                                       "include", "metadata", "top_p", "prompt_cache_key"]

    public enum PromptError: Error, Equatable { case missingPrompt(String) }

    // MARK: instructions

    /// System rules for the direction and mode, then the glossary (sorted, ≤30 entries), then
    /// the strict-terms rule for guard retries. Stable within a session (prompt-cache friendly).
    public func instructions(session: MTSession, mode: MTMode, glossary: [GlossaryEntry],
                             strictTerms: [String] = []) throws -> String {
        let d = session.direction
        let key = "\(d.source.rawValue)-\(d.target.rawValue)"
        var parts: [String] = []
        if session.isSpeak {
            switch mode {
            case .summarize:
                guard let s = prompts.speak.summarize[key] else { throw PromptError.missingPrompt("summarize." + key) }
                parts.append(s)
            case .normal, .concise:
                switch session {
                case .speakZhEn: parts.append(prompts.speak.zhEn)
                case .speakZhDe: parts.append(prompts.speak.zhDe)
                case .speakEnZh: parts.append(prompts.speak.enZh)
                case .speakEnDe: parts.append(prompts.speak.enDe)
                case .listenEnZh, .listenDeZh: preconditionFailure("LISTEN prompt in SPEAK branch")
                }
                if mode == .concise { parts.append(prompts.speak.concise) }
            }
        } else {
            guard let s = prompts.listen[key] else { throw PromptError.missingPrompt("listen." + key) }
            parts.append(s)
        }
        let entries = glossary.sorted { ($0.zh, $0.en, $0.de) < ($1.zh, $1.en, $1.de) }.prefix(Self.maxGlossaryEntries)
        if !entries.isEmpty {
            let lines = entries.map { e -> String in
                // Existing Chinese-source and LISTEN prompts retain their stable rendering;
                // English-source SPEAK needs the English term, including for English → German.
                let source = session.isSpeak ? e.rendering(for: d.source) : e.zh
                let target = session.isSpeak ? e.rendering(for: d.target) : e.rendering(for: d.source)
                return prompts.glossary.line.replacingOccurrences(of: "{zh}", with: source)
                    .replacingOccurrences(of: "{target}", with: target)
            }
            parts.append(([prompts.glossary.header] + lines).joined(separator: "\n"))
        }
        if !strictTerms.isEmpty {
            let lang = prompts.languageNames[d.target.rawValue] ?? d.target.rawValue
            parts.append((d.target == .zh ? prompts.speak.strictTermsZh : prompts.speak.strictTerms)
                .replacingOccurrences(of: "{terms}", with: strictTerms.joined(separator: ", "))
                .replacingOccurrences(of: "{language}", with: lang))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: input and context

    /// `<chunk final="true|false">…</chunk>` with &, <, > escaped.
    public static func chunk(_ text: String, final: Bool) -> String {
        let esc = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<chunk final=\"\(final)\">\(esc)</chunk>"
    }

    /// Rough token estimate: one per CJK character, one per 4 other characters, +4 per message.
    public static func estimatedTokens(_ s: String) -> Int {
        var cjk = 0, other = 0
        for u in s.unicodeScalars {
            if TextScript.isCJK(u) { cjk += 1 } else { other += 1 }
        }
        return cjk + (other + 3) / 4
    }

    /// Keeps the newest turns: drops the oldest until the context is within `soft` tokens (§5.4).
    /// A single turn above `hard` is dropped too.
    public static func trimmedHistory(_ history: [MTTurn], soft: Int, hard: Int) -> [MTTurn] {
        var kept: [MTTurn] = []
        var total = 0
        for turn in history.reversed() {
            let t = estimatedTokens(turn.source) + estimatedTokens(turn.target) + 8
            if t > hard || total + t > soft { break }
            total += t
            kept.insert(turn, at: 0)
        }
        return kept
    }

    // MARK: body

    public struct Options: Sendable, Equatable {
        public var model: String
        /// "none" (default) or "low" (yellow path, §11).
        public var effort: String
        /// Extra output budget for reasoning on the yellow path (max_output_tokens includes it).
        public var reasoningBudget: Int
        public var contextTokensSoft: Int
        public var contextTokensHard: Int
        public init(model: String, effort: String, reasoningBudget: Int = 0, contextTokensSoft: Int, contextTokensHard: Int) {
            self.model = model; self.effort = effort; self.reasoningBudget = reasoningBudget
            self.contextTokensSoft = contextTokensSoft; self.contextTokensHard = contextTokensHard
        }
    }

    public func bodyObject(for r: MTRequest, glossary: [GlossaryEntry], options o: Options) throws -> [String: Any] {
        var input: [[String: Any]] = []
        for turn in Self.trimmedHistory(r.history, soft: o.contextTokensSoft, hard: o.contextTokensHard) {
            input.append(["role": "user", "content": Self.chunk(turn.source, final: true)])
            input.append(["role": "assistant", "content": turn.target])
        }
        input.append(["role": "user", "content": Self.chunk(r.text, final: r.isFinalChunk)])
        var body: [String: Any] = [
            "model": o.model,
            "instructions": try instructions(session: r.session, mode: r.mode, glossary: glossary, strictTerms: r.strictTerms),
            "input": input,
            "reasoning": ["effort": o.effort],
            "max_output_tokens": max(Self.minOutputTokens, r.maxOutputTokens + o.reasoningBudget),
            "stream": cloud.stream,
            "store": false,
            "service_tier": cloud.serviceTier,
            "prompt_cache_options": ["mode": "explicit"],
        ]
        if o.effort == "none" { body["temperature"] = cloud.temperature }   // only legal with effort none
        return body
    }

    /// The serialized body; send these exact bytes on A and (if hedged) on B.
    public func body(for r: MTRequest, glossary: [GlossaryEntry], options: Options) throws -> Data {
        try JSONSerialization.data(withJSONObject: bodyObject(for: r, glossary: glossary, options: options),
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Request headers except Authorization (added by OpenAIClient only). A fresh
    /// X-Client-Request-Id per attempt; never OpenAI-Organization / OpenAI-Project.
    public static func headers(clientRequestID: UUID, streaming: Bool) -> [String: String] {
        var h = ["Content-Type": "application/json", "X-Client-Request-Id": clientRequestID.uuidString.lowercased()]
        if streaming { h["Accept"] = "text/event-stream" }
        return h
    }
}

// MARK: - response validation (§5.4)

/// The fields of a Response object that validation looks at.
public struct ResponseEcho: Sendable, Equatable {
    public var id: String?
    public var status: String?
    public var incompleteReason: String?
    public var effort: String?
    public var serviceTier: String?
    public var store: Bool?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cachedTokens: Int?

    public init(id: String? = nil, status: String? = nil, incompleteReason: String? = nil, effort: String? = nil,
                serviceTier: String? = nil, store: Bool? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                reasoningTokens: Int? = nil, cachedTokens: Int? = nil) {
        self.id = id; self.status = status; self.incompleteReason = incompleteReason; self.effort = effort
        self.serviceTier = serviceTier; self.store = store; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.reasoningTokens = reasoningTokens; self.cachedTokens = cachedTokens
    }

    /// From the `response` object of response.created / .completed / .incomplete / .failed.
    public init(response r: [String: Any]) {
        id = r["id"] as? String
        status = r["status"] as? String
        incompleteReason = (r["incomplete_details"] as? [String: Any])?["reason"] as? String
        effort = (r["reasoning"] as? [String: Any])?["effort"] as? String
        serviceTier = r["service_tier"] as? String
        store = r["store"] as? Bool
        let usage = r["usage"] as? [String: Any]
        inputTokens = usage?["input_tokens"] as? Int
        outputTokens = usage?["output_tokens"] as? Int
        reasoningTokens = (usage?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        cachedTokens = (usage?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
    }
}

public struct ResponseValidation: Sendable, Equatable {
    /// nil = usable.
    public var rejectReason: String?
    /// `store` was not echoed: not a rejection, only the event mt.store_echo_missing.
    public var storeEchoMissing: Bool
    public var isUsable: Bool { rejectReason == nil }
}

extension OpenAIRequestBuilder {
    /// Full validation on the final event. `sentEffort`: the effort in the request.
    /// `firstLineComplete`: a newline arrived, or the stream ended after text.
    public static func validate(_ e: ResponseEcho, sentEffort: String, firstLineComplete: Bool,
                                expectedServiceTier: String = "default") -> ResponseValidation {
        var reason: String?
        switch e.status {
        case "completed": break
        case "incomplete":
            if e.incompleteReason != "max_output_tokens" { reason = "incomplete:\(e.incompleteReason ?? "unknown")" }
            else if !firstLineComplete { reason = "incomplete:firstLineCut" }
        default: reason = "status:\(e.status ?? "missing")"
        }
        if reason == nil { reason = echoProblem(e, sentEffort: sentEffort, expectedServiceTier: expectedServiceTier) }
        if reason == nil, sentEffort == "none" {
            if e.reasoningTokens == nil { reason = "reasoningTokens:missing" }
            else if e.reasoningTokens != 0 { reason = "reasoningTokens:nonzero" }
        }
        return ResponseValidation(rejectReason: reason, storeEchoMissing: e.store == nil)
    }

    /// Partial validation after `afterNewlineGraceMs` expired: only the echo from response.created
    /// (effort, service_tier, store if present), same rules. Logged as mt.validate_partial.
    public static func validatePartial(created e: ResponseEcho, sentEffort: String,
                                       expectedServiceTier: String = "default") -> ResponseValidation {
        ResponseValidation(rejectReason: echoProblem(e, sentEffort: sentEffort, expectedServiceTier: expectedServiceTier),
                           storeEchoMissing: e.store == nil)
    }

    private static func echoProblem(_ e: ResponseEcho, sentEffort: String, expectedServiceTier: String) -> String? {
        if e.effort != sentEffort { return "effort:\(e.effort ?? "missing")" }
        if e.serviceTier != expectedServiceTier { return "serviceTier:\(e.serviceTier ?? "missing")" }
        if e.store == true { return "store:true" }
        return nil
    }
}

/// The text up to the first newline (§5.4: Responses has no `stop`; later deltas are dropped).
public struct FirstLine: Sendable, Equatable {
    public private(set) var text = ""
    public private(set) var isComplete = false
    public init() {}

    /// Appends a delta; returns true when this delta completed the first line.
    @discardableResult
    public mutating func append(_ delta: String) -> Bool {
        guard !isComplete else { return false }
        if let nl = delta.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            text += delta[..<nl]
            isComplete = true
            return true
        }
        text += delta
        return false
    }

    public var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
}

// MARK: - errors (§6.4, §7.7, O20)

/// `{"error":{"code","type","param"}}`. `message` is never decoded or kept (it may contain a
/// partially masked key).
public struct OpenAIErrorInfo: Sendable, Equatable, Codable {
    public var code: String?
    public var type: String?
    public var param: String?

    public init(code: String? = nil, type: String? = nil, param: String? = nil) {
        self.code = code; self.type = type; self.param = param
    }

    public static func parse(_ body: Data) -> OpenAIErrorInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return nil }
        return OpenAIErrorInfo(code: err["code"] as? String, type: err["type"] as? String, param: err["param"] as? String)
    }

    /// From an SSE `error` event or `response.error`.
    public static func parse(event obj: [String: Any]) -> OpenAIErrorInfo {
        let err = (obj["error"] as? [String: Any]) ?? obj
        return OpenAIErrorInfo(code: err["code"] as? String, type: err["type"] as? String, param: err["param"] as? String)
    }
}

public enum OpenAIErrorClassifier {
    /// HTTP status (+ error body) → LegFailure, per cloud.pauseOn / cloud.rateLimitOnly.
    public static func classify(status: Int, error: OpenAIErrorInfo?, retryAfterS: Int?,
                                cloud: PolicyProfile.Cloud) -> LegFailure {
        if cloud.pauseOn.status.contains(status) { return .pause("http\(status)") }
        if status == 429 {
            if let code = error?.code, cloud.pauseOn.errorCode.contains(code) { return .pause(code) }
            if let code = error?.code, cloud.rateLimitOnly.errorCode.contains(code) {
                return .rateLimited(retryAfterS: cloud.rateLimitOnly.honorRetryAfter ? retryAfterS : nil)
            }
            if let type = error?.type, cloud.pauseOn.errorType.contains(type) { return .pause(type) }
            return .rateLimited(retryAfterS: retryAfterS)
        }
        if (500...599).contains(status) { return .http5xx(status) }
        return .clientError(status)
    }

    /// `Retry-After` in seconds (delta-seconds form only; HTTP-date is ignored).
    public static func retryAfterSeconds(_ header: String?) -> Int? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), let v = Double(h), v >= 0 else { return nil }
        return Int(v.rounded(.up))
    }
}

/// Script classes used by the gates and the token estimate.
public enum TextScript {
    public static func isHan(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3007: true
        default: false
        }
    }
    public static func isKana(_ u: Unicode.Scalar) -> Bool { (0x3040...0x30FF).contains(u.value) || (0x31F0...0x31FF).contains(u.value) }
    public static func isHangul(_ u: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(u.value) || (0x1100...0x11FF).contains(u.value) || (0x3130...0x318F).contains(u.value)
    }
    public static func isCJK(_ u: Unicode.Scalar) -> Bool { isHan(u) || isKana(u) || isHangul(u) }
    public static func isLatinLetter(_ u: Unicode.Scalar) -> Bool {
        u.properties.isAlphabetic && (u.value < 0x250 || (0x1E00...0x1EFF).contains(u.value))
    }
    /// Han share of non-whitespace characters (SPEAK language gate, §5.2).
    public static func hanRatio(_ s: String) -> Double {
        let chars = s.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !chars.isEmpty else { return 0 }
        return Double(chars.filter(isHan).count) / Double(chars.count)
    }
}
