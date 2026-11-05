import Foundation
import TalkTalkCore

/// The live model list and the per-model probe (§7.7, §11). The list is fetched with the user's
/// key and kept in memory only.
public struct OpenAIModelCatalog: Sendable {
    public let client: OpenAIClient
    public let builder: OpenAIRequestBuilder

    public init(client: OpenAIClient, builder: OpenAIRequestBuilder) {
        self.client = client; self.builder = builder
    }

    public enum CatalogError: Error, Sendable, Equatable {
        case http(Int, OpenAIErrorInfo?)
        case malformed
    }

    /// `GET /v1/models` → rows (id, created, object, owned_by, shutdown_date).
    public func list() async throws -> [ModelFilter.Listed] {
        let r = try await client.get(leg: .A, path: client.cloud.modelsPath)
        guard r.headers.status == 200 else { throw CatalogError.http(r.headers.status, r.error) }
        struct Page: Decodable { var data: [ModelFilter.Listed] }
        guard let page = try? JSONDecoder().decode(Page.self, from: r.body) else { throw CatalogError.malformed }
        return page.data
    }

    public struct ProbeResult: Sendable, Equatable {
        public var model: String
        public var effort: String
        public var httpStatus: Int?
        public var error: OpenAIErrorInfo?
        public var accepted: Bool
        public var rejectReason: String?
        public var storeEchoMissing: Bool
        public var reasoningTokens: Int?
        public var firstDeltaMs: Int?
        public var totalMs: Int?
        /// The yellow path (§11): effort none not supported, retry with low.
        public var needsLowEffort: Bool { httpStatus == 400 && effort == "none" }
    }

    /// One real translation request without hedging (§11): warm A, then translate a fixed
    /// sentence and check effort accepted, status completed, reasoning tokens 0, store echo.
    /// `basePolicy` is the profile's speak policy; hedging is switched off for the probe.
    public func probe(model: String, effort: String = "none", reasoningBudget: Int = 0,
                      basePolicy: HedgePolicy) async -> ProbeResult {
        _ = try? await client.get(leg: .A, path: client.cloud.keepWarmPath.replacingOccurrences(of: "{model}", with: model))
        let req = MTRequest(job: 0, session: .speakZhEn, text: "我们下周三之前修好。", isFinalChunk: true,
                            priority: .p1Speak, maxOutputTokens: 48)
        let options = OpenAIRequestBuilder.Options(model: model, effort: effort, reasoningBudget: reasoningBudget,
                                                   contextTokensSoft: 300, contextTokensHard: 800)
        var result = ProbeResult(model: model, effort: effort, accepted: false, storeEchoMissing: false)
        guard let body = try? builder.body(for: req, glossary: [], options: options) else {
            result.rejectReason = "body"; return result
        }
        var policy = basePolicy
        policy.totalDeadlineMs = 10_000
        policy.extendToDrain.enabled = false
        policy.hedge.enabled = false
        let outcome = await HedgedRequest(client: client, policy: policy, afterNewlineGraceMs: 300)
            .run(body: body, sentEffort: effort, deadlineMs: 10_000)
        let a = outcome.legs[.A]!
        result.httpStatus = a.headers?.status
        result.error = a.error
        result.accepted = outcome.decision.outcome.winner == .A
        result.rejectReason = a.validation?.rejectReason ?? (result.accepted ? nil : "\(String(describing: a.result))")
        result.storeEchoMissing = a.validation?.storeEchoMissing ?? false
        result.reasoningTokens = a.echo?.reasoningTokens
        result.firstDeltaMs = a.firstDeltaMs
        result.totalMs = a.endMs
        return result
    }
}
