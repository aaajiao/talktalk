import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct OpenAIRequestBuilderTests {
    let builder: OpenAIRequestBuilder
    let profile: PolicyProfile

    init() throws {
        profile = try TestResources.profile()
        builder = OpenAIRequestBuilder(cloud: profile.cloud, prompts: try TestResources.prompts())
    }

    var glossary: [GlossaryEntry] {
        [GlossaryEntry(zh: "延迟", en: "latency", de: "Latenz"), GlossaryEntry(zh: "原型", en: "prototype", de: "Prototyp")]
    }

    func speakRequest(_ text: String = "总共还是三十万欧元。", history: [MTTurn] = [], final: Bool = false,
                      mode: MTMode = .normal, strict: [String] = []) -> MTRequest {
        MTRequest(job: 7, session: .speakZhDe, text: text, isFinalChunk: final, mode: mode, priority: .p1Speak,
                  maxOutputTokens: profile.speak.mt.maxOutputTokens(for: .de)!, history: history, strictTerms: strict)
    }

    var options: OpenAIRequestBuilder.Options {
        .init(model: "gpt-6-luna", effort: "none", contextTokensSoft: profile.speak.mt.contextTokensSoft,
              contextTokensHard: profile.speak.mt.contextTokensHard)
    }

    /// Golden: the exact bytes for a SPEAK zh→de clause with history and glossary.
    @Test func goldenSpeakBody() throws {
        let r = speakRequest(history: [MTTurn(source: "预算方面暂时没有变化。", target: "Beim Budget gibt es vorerst keine Änderung.")])
        let body = try builder.body(for: r, glossary: glossary, options: options)
        let golden = try Data(contentsOf: TestResources.golden("openai_body_speak_zh_de.json"))
        #expect(String(decoding: body, as: UTF8.self) == String(decoding: golden, as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    @Test func bodyAlwaysHasStoreFalseAndNoForbiddenFields() throws {
        for session in MTSession.allCases {
            let r = MTRequest(job: 1, session: session, text: "x", isFinalChunk: true, priority: .p2Listen, maxOutputTokens: 256)
            let data = try builder.body(for: r, glossary: glossary, options: options)
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            #expect(obj["store"] as? Bool == false)
            #expect(String(decoding: data, as: UTF8.self).contains("\"store\":false"))
            for k in OpenAIRequestBuilder.forbiddenKeys { #expect(obj[k] == nil, "\(k)") }
            #expect((obj["reasoning"] as? [String: String])?["effort"] == "none")
            #expect(obj["temperature"] as? Double == 0)
            #expect(obj["service_tier"] as? String == "default")
            #expect(obj["stream"] as? Bool == true)
            #expect((obj["prompt_cache_options"] as? [String: String]) == ["mode": "explicit"])
            #expect(obj["model"] as? String == "gpt-6-luna")
        }
    }

    @Test func yellowPathDropsTemperatureAndAddsReasoningBudget() throws {
        let o = OpenAIRequestBuilder.Options(model: "gpt-6.1-sol", effort: "low", reasoningBudget: 512,
                                             contextTokensSoft: 300, contextTokensHard: 800)
        let obj = try builder.bodyObject(for: speakRequest(), glossary: [], options: o)
        #expect(obj["temperature"] == nil)
        #expect(obj["max_output_tokens"] as? Int == 56 + 512)
        #expect((obj["reasoning"] as? [String: String])?["effort"] == "low")
    }

    @Test func bodyIsByteIdenticalAcrossCalls() throws {
        let r = speakRequest(history: [MTTurn(source: "a", target: "b")])
        #expect(try builder.body(for: r, glossary: glossary, options: options) == builder.body(for: r, glossary: glossary.reversed(), options: options))
    }

    @Test func headersNeverCarryAuthorizationOrOrganization() {
        let id = UUID()
        let h = OpenAIRequestBuilder.headers(clientRequestID: id, streaming: true)
        #expect(h["Authorization"] == nil)
        #expect(h["OpenAI-Organization"] == nil && h["OpenAI-Project"] == nil)
        #expect(h["Accept"] == "text/event-stream")
        #expect(h["X-Client-Request-Id"] == id.uuidString.lowercased())
        #expect(OpenAIRequestBuilder.headers(clientRequestID: UUID(), streaming: true)["X-Client-Request-Id"] != h["X-Client-Request-Id"])
    }

    @Test func instructionsCarryModesGlossaryAndStrictTerms() throws {
        let normal = try builder.instructions(session: .speakZhDe, mode: .normal, glossary: glossary)
        #expect(normal.hasPrefix("You are a simultaneous interpreter. Translate ONLY the newest speech chunk into German"))
        #expect(normal.contains("原型 = Prototyp\n延迟 = Latenz") || normal.contains("延迟 = Latenz"))
        let concise = try builder.instructions(session: .speakZhEn, mode: .concise, glossary: [])
        #expect(concise.contains("at most 70%"))
        let summary = try builder.instructions(session: .speakZhEn, mode: .summarize, glossary: [])
        #expect(summary.contains("Summarize them as ONE short English sentence"))
        let strict = try builder.instructions(session: .speakZhDe, mode: .normal, glossary: [], strictTerms: ["张总", "李工"])
        #expect(strict.contains("张总, 李工"))
        #expect(strict.contains("Output German only"))
        let listen = try builder.instructions(session: .listenDeZh, mode: .normal, glossary: glossary)
        #expect(listen.contains("newest German sentence into concise Simplified Chinese"))
        #expect(listen.contains("Latenz = 延迟"))
        // Glossary is capped at 30 entries.
        let many = (0..<40).map { GlossaryEntry(zh: "词\($0)", en: "w\($0)", de: "w\($0)") }
        let capped = try builder.instructions(session: .speakZhEn, mode: .normal, glossary: many)
        #expect(capped.components(separatedBy: " = ").count - 1 == 30)
    }

    @Test func englishSpeakingDirectionsHaveTheirOwnPromptsAndGlossaries() throws {
        #expect(MTSession.speak(source: .zh, target: .en) == .speakZhEn)
        #expect(MTSession.speak(source: .zh, target: .de) == .speakZhDe)
        #expect(MTSession.speak(source: .en, target: .zh) == .speakEnZh)
        #expect(MTSession.speak(source: .en, target: .de) == .speakEnDe)
        #expect(MTSession.speak(source: .en, target: .en) == nil)
        #expect(MTSession.speak(source: .de, target: .zh) == nil)
        for session in [MTSession.speakEnZh, .speakEnDe] {
            #expect(session.isSpeak && session.direction.source == .en)
            for mode in [MTMode.normal, .concise, .summarize] {
                let prompt = try builder.instructions(session: session, mode: mode, glossary: glossary)
                #expect(prompt.contains("English"))
                #expect(prompt.contains(session == .speakEnZh ? "latency = 延迟" : "latency = Latenz"))
                #expect(prompt.contains(session == .speakEnZh ? "Simplified Chinese" : "German"))
                if session == .speakEnZh { #expect(!prompt.contains("never output Chinese characters")) }
            }
        }
        let retry = try builder.instructions(session: .speakEnZh, mode: .normal, glossary: glossary,
                                             strictTerms: ["1.5 million", "latency"])
        #expect(retry.contains("1.5 million, latency"))
        #expect(retry.contains("Output Simplified Chinese only"))
        #expect(!retry.contains("never output Chinese characters"))
    }

    @Test func allSubtitleDirectionsUseSubtitlePromptsAndTheirOwnGlossary() throws {
        for source in Lang.allCases {
            for target in Lang.allCases {
                let session = MTSession.listen(source: source, target: target)
                if source == target { #expect(session == nil); continue }
                let selected = try #require(session)
                #expect(!selected.isSpeak && selected.direction == Direction(source: source, target: target))
                let prompt = try builder.instructions(session: selected, mode: .normal, glossary: glossary)
                #expect(prompt.hasPrefix("You write live subtitles"))
                let term = glossary[0]
                #expect(prompt.contains("\(term.rendering(for: source)) = \(term.rendering(for: target))"))
                let targetName = builder.prompts.languageNames[target.rawValue]!
                #expect(prompt.contains(targetName))
            }
        }
        #expect(MTSession.speak(source: .de, target: .en) == nil)
        #expect(MTSession.speak(source: .de, target: .zh) == nil)
    }

    @Test func chunkIsEscapedAndMarked() {
        #expect(OpenAIRequestBuilder.chunk("a<b>&c", final: false) == "<chunk final=\"false\">a&lt;b&gt;&amp;c</chunk>")
        #expect(OpenAIRequestBuilder.chunk("好", final: true) == "<chunk final=\"true\">好</chunk>")
    }

    @Test func historyIsTrimmedFromTheOldestTurn() {
        let turns = (0..<20).map { _ in MTTurn(source: String(repeating: "字", count: 30), target: String(repeating: "word ", count: 6)) }
        let kept = OpenAIRequestBuilder.trimmedHistory(turns, soft: 150, hard: 400)
        #expect(!kept.isEmpty && kept.count < 20)
        #expect(kept.last == turns.last)
        #expect(OpenAIRequestBuilder.trimmedHistory([MTTurn(source: String(repeating: "字", count: 500), target: "x")], soft: 300, hard: 400).isEmpty)
    }

    // MARK: validation

    func echo(status: String = "completed", reason: String? = nil, effort: String? = "none", tier: String? = "default",
              store: Bool? = false, reasoning: Int? = 0) -> ResponseEcho {
        ResponseEcho(id: "resp_1", status: status, incompleteReason: reason, effort: effort, serviceTier: tier, store: store,
                     inputTokens: 100, outputTokens: 12, reasoningTokens: reasoning, cachedTokens: 0)
    }

    @Test func validationRules() {
        typealias B = OpenAIRequestBuilder
        #expect(B.validate(echo(), sentEffort: "none", firstLineComplete: true).isUsable)
        // store missing: usable, only mt.store_echo_missing.
        let missing = B.validate(echo(store: nil), sentEffort: "none", firstLineComplete: true)
        #expect(missing.isUsable && missing.storeEchoMissing)
        // store:true echoed: rejected.
        #expect(B.validate(echo(store: true), sentEffort: "none", firstLineComplete: true).rejectReason == "store:true")
        #expect(B.validate(echo(effort: "low"), sentEffort: "none", firstLineComplete: true).rejectReason == "effort:low")
        #expect(B.validate(echo(effort: nil), sentEffort: "none", firstLineComplete: true).rejectReason == "effort:missing")
        #expect(B.validate(echo(tier: "flex"), sentEffort: "none", firstLineComplete: true).rejectReason == "serviceTier:flex")
        // Fast mode may echo its own name, the older "priority", or "default" after a downgrade.
        for tier in ["fast", "priority", "default"] {
            #expect(B.validate(echo(tier: tier), sentEffort: "none", firstLineComplete: true, expectedServiceTier: "fast").isUsable)
        }
        #expect(B.validate(echo(tier: "flex"), sentEffort: "none", firstLineComplete: true, expectedServiceTier: "fast").rejectReason == "serviceTier:flex")
        #expect(B.validate(echo(tier: "fast"), sentEffort: "none", firstLineComplete: true).rejectReason == "serviceTier:fast")
        #expect(B.validate(echo(reasoning: 3), sentEffort: "none", firstLineComplete: true).rejectReason == "reasoningTokens:nonzero")
        #expect(B.validate(echo(reasoning: nil), sentEffort: "none", firstLineComplete: true).rejectReason == "reasoningTokens:missing")
        // Yellow path: reasoning tokens recorded, not blocked.
        #expect(B.validate(echo(effort: "low", reasoning: 120), sentEffort: "low", firstLineComplete: true).isUsable)
        // incomplete: only max_output_tokens with a complete first line.
        #expect(B.validate(echo(status: "incomplete", reason: "max_output_tokens"), sentEffort: "none", firstLineComplete: true).isUsable)
        #expect(!B.validate(echo(status: "incomplete", reason: "max_output_tokens"), sentEffort: "none", firstLineComplete: false).isUsable)
        #expect(B.validate(echo(status: "incomplete", reason: "content_filter"), sentEffort: "none", firstLineComplete: true).rejectReason == "incomplete:content_filter")
        #expect(!B.validate(echo(status: "failed"), sentEffort: "none", firstLineComplete: true).isUsable)
    }

    @Test func partialValidationUsesTheCreatedEcho() {
        let created = ResponseEcho(status: "in_progress", effort: "none", serviceTier: "default", store: nil)
        let v = OpenAIRequestBuilder.validatePartial(created: created, sentEffort: "none")
        #expect(v.isUsable && v.storeEchoMissing)
        #expect(!OpenAIRequestBuilder.validatePartial(created: ResponseEcho(effort: "none", serviceTier: "auto"), sentEffort: "none").isUsable)
    }

    @Test func echoParsesFromAResponseObject() throws {
        let json = """
        {"id":"resp_x","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},
         "reasoning":{"effort":"none","summary":null},"service_tier":"default","store":false,
         "usage":{"input_tokens":625,"input_tokens_details":{"cached_tokens":0},"output_tokens":56,
                  "output_tokens_details":{"reasoning_tokens":0},"total_tokens":681}}
        """
        let e = ResponseEcho(response: try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
        #expect(e == ResponseEcho(id: "resp_x", status: "incomplete", incompleteReason: "max_output_tokens", effort: "none",
                                  serviceTier: "default", store: false, inputTokens: 625, outputTokens: 56,
                                  reasoningTokens: 0, cachedTokens: 0))
    }

    @Test func firstLineStopsAtTheNewline() {
        var f = FirstLine()
        let a = f.append("Guten ")
        let b = f.append("Tag.\nHere is")
        let c = f.append(" more")
        #expect(!a && b && !c)
        #expect(f.text == "Guten Tag." && f.isComplete)
    }

    // MARK: errors

    @Test func errorClassificationGolden() throws {
        let c = profile.cloud
        func k(_ status: Int, _ code: String?, _ type: String?, _ ra: Int? = nil) -> LegFailure {
            OpenAIErrorClassifier.classify(status: status, error: OpenAIErrorInfo(code: code, type: type), retryAfterS: ra, cloud: c)
        }
        for code in ["credit_balance_exhausted", "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
                     "organization_usage_limit_exceeded"] {
            #expect(k(429, code, "insufficient_quota") == .pause(code))
        }
        #expect(k(429, nil, "insufficient_quota") == .pause("insufficient_quota"))
        #expect(k(429, "slow_down", "rate_limit_error", 12) == .rateLimited(retryAfterS: 12))
        #expect(k(429, nil, nil, 3) == .rateLimited(retryAfterS: 3))
        #expect(k(401, "invalid_api_key", "invalid_request_error") == .pause("http401"))
        #expect(k(403, "unsupported_country_region_territory", nil) == .pause("http403"))
        #expect(k(503, nil, nil) == .http5xx(503))
        #expect(k(400, "unsupported_value", "invalid_request_error") == .clientError(400))
        #expect(k(404, "model_not_found", nil) == .clientError(404))
        #expect(OpenAIErrorClassifier.retryAfterSeconds("2.1") == 3)
        #expect(OpenAIErrorClassifier.retryAfterSeconds("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
    }

    @Test func errorParsingNeverKeepsTheMessage() throws {
        let fakeKey = "sk-proj-FAKEKEYFAKEKEY1234"
        let body = Data(#"{"error":{"message":"Incorrect API key provided: \#(fakeKey)","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#.utf8)
        let info = try #require(OpenAIErrorInfo.parse(body))
        #expect(info == OpenAIErrorInfo(code: "invalid_api_key", type: "invalid_request_error", param: nil))
        let encoded = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        #expect(!encoded.contains("FAKEKEY"))
        #expect(!"\(info)".contains("FAKEKEY"))
    }

    @Test func hanRatioGate() {
        #expect(TextScript.hanRatio("我们用 Kubernetes 部署") > 0.2)
        #expect(TextScript.hanRatio("OK, let's go") == 0)
    }
}
