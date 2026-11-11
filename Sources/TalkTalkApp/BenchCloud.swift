import AppKit
import Foundation
import Synchronization
import TalkTalkCloud
import TalkTalkCore

@MainActor func runBenchCloud() -> Never {
    #if TALKTALK_DEV
    BenchCloud.run(arguments: arguments, outPath: argumentValue("--out"))
    #else
    fail("--bench cloud exists only in the dev build (TalkTalk-Dev.app)")
    #endif
}

#if TALKTALK_DEV
/// `--bench cloud` (ARCHITECTURE.md T4 ⓪–⑨). Dev build only.
///
/// Runs the T4 measurement program with the production client (OpenAIClient, HedgedRequest,
/// KeepWarm, CloudHealth, SessionResetPolicy, the real prompts and PolicyProfile). The key is
/// read from the dev app's own Keychain item (written by `--bench store-key`); it is never
/// printed, logged or passed on the command line. Output: `--out <file>` gets the summary JSON;
/// `<file>.jsonl` gets one record per request/sentence/event: numbers, codes and ids only, no
/// text, no key, no `error.message`. At the end the bench scans its own output for the key.
///
///   open -W -n -a build/TalkTalk-Dev.app --args --bench cloud --phase <list> --out <file>
///
/// Phases (comma list, run in this order): models, probe, formal, hedge, keepwarm, faults,
/// reset, cancel, watch, keychain. Default: models,probe,formal. `all` = every phase except
/// cancel and watch. `--dry-run` uses a fake key and a local simulated server (no network, no
/// Keychain) to check the bench itself.
@MainActor
enum BenchCloud {
    static func run(arguments: [String], outPath: String?) -> Never {
        let options = Options(arguments)
        Task.detached {
            let code = await Runner(options: options, outPath: outPath).run()
            exit(code)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    struct Options: Sendable {
        var phases: [String]
        var dryRun: Bool
        var model: String?
        var formalCount = 40
        var speakCount = 200
        var listenCount = 100
        var guardCount = 30
        var injectCount = 20
        var cancelCount = 50
        var idleS: [Int] = [10, 30, 60, 120]
        var watchMinutes = 30
        var paceScale = 1.0
        var confirmCancelProject = false

        static let order = ["models", "probe", "formal", "hedge", "keepwarm", "faults", "reset", "cancel", "watch", "keychain"]

        init(_ args: [String]) {
            func value(_ n: String) -> String? {
                guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            func int(_ n: String, _ d: Int) -> Int { value(n).flatMap { Int($0) } ?? d }
            let raw = (value("--phase") ?? "models,probe,formal").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let wanted: Set<String> = raw.contains("all")
                ? Set(Self.order).subtracting(["cancel", "watch"]).union(raw.filter { $0 != "all" })
                : Set(raw)
            phases = Self.order.filter { wanted.contains($0) }
            dryRun = args.contains("--dry-run")
            model = value("--model")
            formalCount = int("--formal", formalCount)
            speakCount = int("--speak", speakCount)
            listenCount = int("--listen", listenCount)
            guardCount = int("--guard", guardCount)
            injectCount = int("--inject", injectCount)
            cancelCount = int("--cancel", cancelCount)
            watchMinutes = int("--watch-minutes", watchMinutes)
            if let s = value("--idle") { idleS = s.split(separator: ",").compactMap { Int($0) } }
            if let s = value("--pace-scale"), let d = Double(s) { paceScale = d }
            confirmCancelProject = args.contains("--confirm-separate-project")
        }
    }
}

// MARK: - Output

/// JSONL writer. Records are built by the caller from numbers, codes and ids only.
final class BenchRecords: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    let url: URL?
    private let t0 = Date()

    init(path: String?) {
        guard let path else { url = nil; handle = nil; return }
        let u = URL(fileURLWithPath: path + ".jsonl")
        FileManager.default.createFile(atPath: u.path, contents: nil, attributes: [.posixPermissions: 0o600])
        url = u
        handle = try? FileHandle(forWritingTo: u)
    }

    func write(_ type: String, _ fields: [String: Any]) {
        var o = fields
        o["type"] = type
        o["t_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.withLock {
            if let handle { handle.write(d); handle.write(Data("\n".utf8)) }
        }
    }

    func close() { lock.withLock { try? handle?.close() } }
}

/// Per-request connection metrics by X-Client-Request-Id (joined into the summary).
final class MetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: RequestMetrics] = [:]
    private var all: [RequestMetrics] = []
    func add(_ m: RequestMetrics) { lock.withLock { all.append(m); if let id = m.clientRequestID { byID[id] = m } } }
    subscript(id: String?) -> RequestMetrics? { lock.withLock { id.flatMap { byID[$0] } } }
    var everything: [RequestMetrics] { lock.withLock { all } }
}

/// One sentence's numbers for the summary (Sendable copy of the record).
struct SentenceStat: Sendable {
    var phase: String
    var tag: String
    var session: MTSession
    var hedgeOn: Bool
    var kind: String
    var winner: HedgeWinner
    var fired: Bool
    var reason: HedgeReason?
    var fallback: String?
    var ms: Int
    var deadlineMs: Int
    var firstDeltaMs: Int?
    var inputTokens: Int?
    var cachedTokens: Int?
    var reasoningTokens: Int?
    var store: String?
    var effortEcho: String?
    var tierEcho: String?
    var createdEffort: Bool?
    var createdTier: Bool?
    var createdStore: Bool?
    var incomplete: String?
    var stallOver500: Bool
    var newlineToEndMs: Int?
    var ids: [Leg: String]
    var rejects: [String]
    var outputHasCJK: Bool?
    var numberMissing: Int?
    var appleStarts: Int
    var responseID: String?
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

// MARK: - Runner

struct BenchCorpus: Decodable, Sendable {
    var glossary: [GlossaryEntry]
    var speakChains: [[String]]
    var listenEn: [String]
    var listenDe: [String]
    var numberSentences: [String]
}

struct Runner: Sendable {
    let options: BenchCloud.Options
    let outPath: String?

    func run() async -> Int32 {
        var summary: [String: Any] = ["op": "bench-cloud", "phases": options.phases, "dry_run": options.dryRun,
                                      "started": ISO8601DateFormatter().string(from: Date())]
        func finish(_ code: Int32) -> Int32 {
            summary["finished"] = ISO8601DateFormatter().string(from: Date())
            summary["exit"] = Int(code)
            writeResult(summary, to: outPath)
            return code
        }
        // Resources
        let profile: PolicyProfile, prompts: MTPrompts, corpus: BenchCorpus
        do {
            profile = try PolicyProfile.loadDefault()
            prompts = try MTPrompts.loadDefault()
            corpus = try JSONDecoder().decode(BenchCorpus.self, from: Data(contentsOf: ResourceLocator.url(for: "bench/t4_corpus.json")))
        } catch {
            summary["error"] = "resources: \(error)"
            return finish(2)
        }
        // Key: the dev app's own Keychain item, read once, kept in memory only.
        let key: String
        if options.dryRun {
            key = "sk-proj-" + String(repeating: "D", count: 152) + "RYRN"
            FaultInjector.setSimulate(true)
        } else {
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            summary["bundle_id"] = bundleID
            guard bundleID == "com.aaajiao.talktalk.dev", let secret = KeychainSecret.openAI(bundleID: bundleID) else {
                summary["error"] = "must run as TalkTalk-Dev.app (open -W -n -a build/TalkTalk-Dev.app --args --bench cloud ...)"
                return finish(2)
            }
            do {
                let data = try secret.read()
                summary["keychain"] = ["read": true, "length": data.count, "length_is_164": data.count == 164]
                key = String(decoding: data, as: UTF8.self)
            } catch let f as KeychainSecret.Failure {
                summary["keychain"] = ["read": false, "osstatus": Int(f.status), "is_missing_entitlement_34018": f.status == -34018]
                summary["error"] = "no key in the Keychain: run --bench store-key first"
                return finish(2)
            } catch {
                summary["error"] = "keychain read failed"
                return finish(2)
            }
            if let problem = APIKeyShape.problem(key) { summary["error"] = "stored key has a bad shape: \(problem)"; return finish(2) }
        }

        let records = BenchRecords(path: outPath)
        let metrics = MetricsStore()
        let sink: CloudEventSink = { e in Self.log(e, records, metrics) }
        var cloud = profile.cloud
        if let m = options.model { cloud.model = m }
        let client = OpenAIClient(cloud: cloud, keyProvider: { key },
                                  protocolClasses: [.A: [FaultA.self], .B: [FaultB.self]], sink: sink)
        let ctx = Context(options: options, profile: profile, cloud: cloud, prompts: prompts, corpus: corpus,
                          client: client, records: records, metrics: metrics, sink: sink, key: key)
        summary["model"] = cloud.model
        summary["records"] = records.url?.lastPathComponent ?? NSNull()

        var results: [String: Any] = [:]
        for phase in options.phases {
            records.write("phase", ["phase": phase, "event": "start"])
            let r: [String: Any]
            switch phase {
            case "models": r = await ctx.models()
            case "probe": r = await ctx.probe()
            case "formal": r = await ctx.formal()
            case "hedge": r = await ctx.hedgeAB()
            case "keepwarm": r = await ctx.keepWarm()
            case "faults": r = await ctx.faults()
            case "reset": r = await ctx.resetInjection()
            case "cancel": r = await ctx.cancelBilling()
            case "watch": r = await ctx.watch()
            case "keychain": r = ctx.keychainPhase(summary["keychain"])
            default: r = ["error": "unknown phase"]
            }
            results[phase] = r
            records.write("phase", ["phase": phase, "event": "end"])
        }
        summary["results"] = results
        summary["connections"] = ctx.connectionSummary()
        records.close()
        summary["secret_scan"] = ctx.scan(summaryObject: summary)
        return finish(0)
    }

    static func log(_ e: CloudEvent, _ r: BenchRecords, _ m: MetricsStore) {
        switch e {
        case .request(let leg, let path, let id, let keyReadMs):
            r.write("request", ["leg": leg.rawValue, "path": path, "client_request_id": id, "key_read_ms": keyReadMs])
        case .response(let leg, let h):
            r.write("response", ["leg": leg.rawValue, "status": h.status, "x_request_id": h.requestID ?? NSNull(),
                                 "processing_ms": h.processingMs ?? NSNull(), "remaining_requests": h.remainingRequests ?? NSNull(),
                                 "remaining_tokens": h.remainingTokens ?? NSNull(), "retry_after_s": h.retryAfterS ?? NSNull()])
        case .error(let leg, let status, let info):
            r.write("error", ["leg": leg.rawValue, "status": status, "code": info?.code ?? NSNull(), "error_type": info?.type ?? NSNull(),
                              "param": info?.param ?? NSNull()])
        case .metrics(let x):
            m.add(x)
            r.write("metrics", ["leg": x.leg.rawValue, "client_request_id": x.clientRequestID ?? NSNull(),
                                "protocol": x.protocolName ?? NSNull(), "reused": x.reusedConnection ?? NSNull(),
                                "local_port": x.localPort ?? NSNull(), "remote_port": x.remotePort ?? NSNull(),
                                "connect_ms": x.connectMs ?? NSNull(), "tls_ms": x.tlsMs ?? NSNull(),
                                "request_to_response_start_ms": x.requestToResponseStartMs ?? NSNull(),
                                "task_ms": x.taskMs ?? NSNull(), "redirects": x.redirects])
        case .hedge(let o):
            r.write("mt.hedge", ["fired": o.fired, "winner": o.winner.rawValue, "reason": o.reason?.rawValue ?? NSNull(), "ms": o.ms])
        case .validation(let leg, let reject, let missing, let partial):
            r.write(partial ? "mt.validate_partial" : "mt.validate", ["leg": leg.rawValue, "reject": reject ?? NSNull(), "store_echo_missing": missing])
        case .keepWarm(let leg, let ok, let ms):
            r.write("keepwarm", ["leg": leg.rawValue, "ok": ok, "ms": ms])
        case .sessionReset(let leg, let reason):
            r.write("session_reset", ["leg": leg.rawValue, "reason": reason])
        case .breaker(let s):
            r.write("breaker", ["state": s])
        case .fallback(let s):
            r.write("fallback", ["reason": s])
        }
    }
}

// MARK: - Context: the phases

struct Context: Sendable {
    let options: BenchCloud.Options
    let profile: PolicyProfile
    let cloud: PolicyProfile.Cloud
    let prompts: MTPrompts
    let corpus: BenchCorpus
    let client: OpenAIClient
    let records: BenchRecords
    let metrics: MetricsStore
    let sink: CloudEventSink
    let key: String
    let history = Box<[MTSession: [MTTurn]]>([:])
    let job = Box<JobID>(1)

    var builder: OpenAIRequestBuilder { OpenAIRequestBuilder(cloud: cloud, prompts: prompts) }

    var speakClauses: [(MTSession, String)] {
        corpus.speakChains.enumerated().flatMap { i, chain in chain.map { (i % 2 == 0 ? MTSession.speakZhEn : .speakZhDe, $0) } }
    }
    var listenSentences: [(MTSession, String)] {
        zip(corpus.listenEn, corpus.listenDe).flatMap { [(MTSession.listenEnZh, $0), (MTSession.listenDeZh, $1)] }
    }

    func pace(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000 * options.paceScale)))
    }

    func maxOut(_ s: MTSession) -> Int {
        s.isSpeak ? (profile.speak.mt.maxOutputTokens(for: s.direction.target) ?? 56) : profile.listen.finalMT.maxOutputTokens
    }

    func body(_ s: MTSession, _ text: String, maxOutputTokens: Int? = nil, effort: String? = nil, model: String? = nil,
              withHistory: Bool = true) throws -> Data {
        let id = job.value; job.value = id + 1
        let req = MTRequest(job: id, session: s, text: text, isFinalChunk: true, priority: s.isSpeak ? .p1Speak : .p2Listen,
                            maxOutputTokens: maxOutputTokens ?? maxOut(s), history: withHistory ? (history.value[s] ?? []) : [])
        let soft = s.isSpeak ? profile.speak.mt.contextTokensSoft : profile.listen.finalMT.contextTokensSoft
        let hard = s.isSpeak ? profile.speak.mt.contextTokensHard : profile.listen.finalMT.contextTokensHard
        let e = effort ?? cloud.effort
        return try builder.body(for: req, glossary: corpus.glossary,
                                options: .init(model: model ?? cloud.model, effort: e, reasoningBudget: e == "none" ? 0 : 64,
                                               contextTokensSoft: soft, contextTokensHard: hard))
    }

    func policy(for s: MTSession, hedge: Bool) -> HedgePolicy {
        var p = s.isSpeak ? profile.speakHedgePolicy : profile.listenHedgePolicy
        p.hedge.enabled = hedge
        return p
    }

    /// One sentence through HedgedRequest; writes the record; feeds the session history.
    @discardableResult
    func translate(phase: String, tag: String = "", _ s: MTSession, _ text: String, hedge: Bool, kind: HedgeRun.Kind = .normal,
                   deadlineMs: Int? = nil, policyOverride: HedgePolicy? = nil, hedgingPaused: Bool = false) async -> (SentenceStat, HedgedRequest.Outcome) {
        let pol = policyOverride ?? policy(for: s, hedge: hedge)
        let deadline = deadlineMs ?? pol.totalDeadlineMs
        let apple = Box(0)
        // A body that fails to build goes out empty and comes back as a 400 in the record.
        let b = (try? body(s, text)) ?? Data()
        let out = await HedgedRequest(client: client, policy: pol, afterNewlineGraceMs: profile.speak.mt.afterNewlineGraceMs, sink: sink)
            .run(body: b, sentEffort: cloud.effort, kind: kind, deadlineMs: deadline, hedgingPaused: hedgingPaused,
                 onStartApple: { apple.mutate { $0 += 1 } })
        if let t = out.text, !t.isEmpty {
            history.mutate { $0[s, default: []].append(MTTurn(source: text, target: t)); if $0[s]!.count > 12 { $0[s]!.removeFirst() } }
        }
        let st = stat(phase, tag, s, hedge, kind, out, deadline, apple: apple.value, output: out.text, source: text)
        records.write("sentence", record(st, out))
        return (st, out)
    }

    func stat(_ phase: String, _ tag: String, _ s: MTSession, _ hedge: Bool, _ kind: HedgeRun.Kind, _ o: HedgedRequest.Outcome,
              _ deadline: Int, apple: Int, output: String?, source: String) -> SentenceStat {
        let d = o.decision
        let w: HedgedRequest.LegReport? = switch d.outcome.winner { case .A: o.legs[.A]; case .B: o.legs[.B]; case .apple: nil }
        let echo = w?.echo
        let created = w?.createdEcho ?? o.legs[.A]?.createdEcho
        var numberMissing: Int?
        var cjk: Bool?
        if let output {
            if s.isSpeak {
                cjk = output.unicodeScalars.contains(where: TextScript.isCJK)
                numberMissing = NumberGuard.check(source: source, target: output, targetLang: s.direction.target, glossary: corpus.glossary).missing.count
            }
        }
        let incomplete: String? = Leg.allCases.compactMap { o.legs[$0]?.echo }.first { $0.status == "incomplete" }.map { $0.incompleteReason ?? "unknown" }
        return SentenceStat(
            phase: phase, tag: tag, session: s, hedgeOn: hedge, kind: kind == .guardRetry ? "guardRetry" : "normal",
            winner: d.outcome.winner, fired: d.outcome.fired, reason: d.outcome.reason, fallback: d.fallback.map { "\($0)" },
            ms: d.outcome.ms, deadlineMs: deadline, firstDeltaMs: w?.firstDeltaMs.flatMap { fd in w?.sentMs.map { fd - $0 } },
            inputTokens: echo?.inputTokens, cachedTokens: echo?.cachedTokens, reasoningTokens: echo?.reasoningTokens,
            store: echo.map { $0.store.map { $0 ? "true" : "false" } ?? "missing" },
            effortEcho: echo?.effort, tierEcho: echo?.serviceTier,
            createdEffort: created.map { $0.effort != nil }, createdTier: created.map { $0.serviceTier != nil }, createdStore: created.map { $0.store != nil },
            incomplete: incomplete, stallOver500: (w?.maxGapAfterDeltaMs ?? 0) > 500, newlineToEndMs: w?.newlineToEndMs,
            ids: Dictionary(uniqueKeysWithValues: Leg.allCases.compactMap { l in o.legs[l]?.clientRequestID.map { (l, $0) } }),
            rejects: Leg.allCases.compactMap { o.legs[$0]?.validation?.rejectReason },
            outputHasCJK: cjk, numberMissing: numberMissing, appleStarts: apple, responseID: echo?.id)
    }

    func record(_ st: SentenceStat, _ o: HedgedRequest.Outcome) -> [String: Any] {
        func leg(_ l: Leg) -> Any {
            guard let r = o.legs[l], r.sentMs != nil else { return NSNull() }
            var d: [String: Any] = [:]
            d["client_request_id"] = j(r.clientRequestID)
            d["sent_ms"] = j(r.sentMs); d["headers_ms"] = j(r.headersMs)
            d["first_delta_ms"] = j(r.firstDeltaMs); d["end_ms"] = j(r.endMs)
            d["result"] = j(r.result.map { "\($0)" })
            d["cancelled"] = r.cancelled; d["partial"] = r.partialValidation
            d["reject"] = j(r.validation?.rejectReason); d["store_echo_missing"] = j(r.validation?.storeEchoMissing)
            d["x_request_id"] = j(r.headers?.requestID); d["processing_ms"] = j(r.headers?.processingMs)
            d["status"] = j(r.headers?.status)
            d["error_code"] = j(r.error?.code); d["error_type"] = j(r.error?.type)
            d["newline_to_end_ms"] = j(r.newlineToEndMs); d["max_gap_after_delta_ms"] = j(r.maxGapAfterDeltaMs)
            if let e = r.echo {
                var x: [String: Any] = [:]
                x["status"] = j(e.status); x["incomplete_reason"] = j(e.incompleteReason)
                x["effort"] = j(e.effort); x["service_tier"] = j(e.serviceTier)
                x["store"] = e.store.map { $0 as Any } ?? "missing"
                x["input_tokens"] = j(e.inputTokens); x["output_tokens"] = j(e.outputTokens)
                x["reasoning_tokens"] = j(e.reasoningTokens); x["cached_tokens"] = j(e.cachedTokens)
                x["response_id"] = j(e.id)
                d["echo"] = x
            } else { d["echo"] = NSNull() }
            if let c = r.createdEcho {
                var x: [String: Any] = [:]
                x["effort"] = j(c.effort); x["service_tier"] = j(c.serviceTier)
                x["store"] = c.store.map { $0 as Any } ?? "missing"
                d["created_echo"] = x
            } else { d["created_echo"] = NSNull() }
            return d
        }
        var d: [String: Any] = [:]
        d["phase"] = st.phase; d["tag"] = st.tag; d["session"] = st.session.rawValue
        d["hedge_on"] = st.hedgeOn; d["kind"] = st.kind; d["deadline_ms"] = st.deadlineMs
        d["winner"] = st.winner.rawValue; d["fired"] = st.fired; d["reason"] = j(st.reason?.rawValue)
        d["fallback"] = j(st.fallback); d["ms"] = st.ms
        d["breaker_failure"] = o.decision.breakerFailure; d["timed_out"] = o.decision.timedOut
        d["primary_429"] = o.decision.primaryRateLimited; d["pause"] = j(o.decision.pauseReason)
        d["hedge_pause_s"] = j(o.hedgePauseS); d["apple_starts"] = st.appleStarts
        d["input_tokens"] = j(st.inputTokens); d["output_has_cjk"] = j(st.outputHasCJK)
        d["number_missing"] = j(st.numberMissing)
        d["A"] = leg(.A); d["B"] = leg(.B)
        return d
    }

    // MARK: models / probe (⑦)

    func models() async -> [String: Any] {
        let cat = OpenAIModelCatalog(client: client, builder: builder)
        do {
            let rows = try await cat.list()
            let picker = ModelFilter.picker(rows, current: cloud.model)
            return ["listed": rows.count, "eligible_models": picker.models.map(\.id), "eligible_snapshots": picker.snapshots.map(\.id),
                    "current_listed": rows.contains { $0.id == cloud.model }]
        } catch {
            return ["error": "\(error)"]
        }
    }

    func probe() async -> [String: Any] {
        let cat = OpenAIModelCatalog(client: client, builder: builder)
        var out: [[String: Any]] = []
        for m in [cloud.model, "gpt-6-astra", "gpt-6.1-sol"] {
            let r = await cat.probe(model: m, basePolicy: profile.speakHedgePolicy)
            out.append(["model": m, "effort": "none", "status": r.httpStatus ?? NSNull(), "accepted": r.accepted,
                        "reject": r.rejectReason ?? NSNull(), "code": r.error?.code ?? NSNull(), "error_type": r.error?.type ?? NSNull(),
                        "param": r.error?.param ?? NSNull(), "store_echo_missing": r.storeEchoMissing,
                        "reasoning_tokens": r.reasoningTokens ?? NSNull(), "first_delta_ms": r.firstDeltaMs ?? NSNull(),
                        "total_ms": r.totalMs ?? NSNull()])
            if r.needsLowEffort || m != cloud.model {
                // Yellow path: effort low; how large must max_output_tokens be to avoid `incomplete`?
                for maxOut in [56, 96, 160, 256] {
                    let st = await single(phase: "probe", leg: .A, .speakZhDe, corpus.speakChains[1][4], effort: "low", model: m, maxOut: maxOut)
                    out.append(["model": m, "effort": "low", "max_output_tokens": maxOut, "status": st.status ?? NSNull(),
                                "echo_status": st.echo?.status ?? NSNull(), "incomplete_reason": st.echo?.incompleteReason ?? NSNull(),
                                "reasoning_tokens": st.echo?.reasoningTokens ?? NSNull(), "first_delta_ms": st.firstDeltaMs ?? NSNull(),
                                "total_ms": st.endMs ?? NSNull(), "code": st.error?.code ?? NSNull(), "error_type": st.error?.type ?? NSNull()])
                    if st.status != 200 { break }
                }
            }
        }
        // A real 401 body (code/type only), from a deliberately invalid key (not yours).
        let bogus = OpenAIClient(cloud: cloud, keyProvider: { "sk-proj-" + String(repeating: "0", count: 152) + "BAD0" },
                                 protocolClasses: [.A: [FaultA.self], .B: [FaultB.self]], sink: sink)
        if let r = try? await bogus.get(leg: .A, path: cloud.modelsPath) {
            out.append(["case": "invalid_key", "status": r.headers.status, "code": r.error?.code ?? NSNull(), "error_type": r.error?.type ?? NSNull()])
        }
        return ["rows": out]
    }

    // MARK: formal (⓪ ① ③)

    func formal() async -> [String: Any] {
        var stats: [SentenceStat] = []
        var lookups: [Int] = []
        let speak = speakClauses, listen = listenSentences
        for i in 0..<options.formalCount {
            let (s, t) = i % 3 == 2 ? listen[(i / 3) % listen.count] : speak[(i - i / 3) % speak.count]
            let (st, _) = await translate(phase: "formal", s, t, hedge: false, deadlineMs: 10_000)
            stats.append(st)
            if st.winner != .apple, stats.filter({ $0.winner != .apple }).count % 20 == 1, let id = st.responseID {
                if let r = try? await client.get(leg: .A, path: cloud.responsesPath + "/" + id) {
                    lookups.append(r.headers.status)
                    records.write("store_lookup", ["status": r.headers.status, "response_id": id])
                }
            }
            if i % 4 == 0 { _ = try? await client.get(leg: .B, path: cloud.keepWarmPath.replacingOccurrences(of: "{model}", with: cloud.model)) }
            await pace(1)
        }
        var r = echoChecks(stats)
        r["store_lookups"] = ["n": lookups.count, "all_404": lookups.allSatisfy { $0 == 404 }, "statuses": lookups]
        r["by_input_tokens"] = byTokenBin(stats)
        return r
    }

    func echoChecks(_ st: [SentenceStat]) -> [String: Any] {
        let ok = st.filter { $0.winner != .apple }
        var incomplete: [String: Int] = [:]
        for s in st { if let r = s.incomplete { incomplete[r, default: 0] += 1 } }
        return ["n": st.count, "cloud": ok.count,
                "effort_echo_mismatch": ok.filter { $0.effortEcho != cloud.effort }.count,
                "service_tier_mismatch": ok.filter { $0.tierEcho != cloud.serviceTier }.count,
                "reasoning_tokens_nonzero": ok.filter { ($0.reasoningTokens ?? 0) != 0 }.count,
                "reasoning_tokens_missing": ok.filter { $0.reasoningTokens == nil }.count,
                "store_echo": ["false": ok.filter { $0.store == "false" }.count, "true": ok.filter { $0.store == "true" }.count,
                               "missing": ok.filter { $0.store == "missing" }.count],
                "created_echo_has": ["effort": ok.filter { $0.createdEffort == true }.count, "service_tier": ok.filter { $0.createdTier == true }.count,
                                     "store": ok.filter { $0.createdStore == true }.count],
                "incomplete": incomplete, "rejects": Dictionary(grouping: st.flatMap(\.rejects), by: { $0 }).mapValues(\.count),
                "speak_output_has_cjk": st.filter { $0.outputHasCJK == true }.count,
                "speak_number_missing": st.filter { ($0.numberMissing ?? 0) > 0 }.count,
                "cached_tokens": dist(ok.compactMap(\.cachedTokens)), "input_tokens": dist(ok.compactMap(\.inputTokens)),
                "ms": dist(ok.map(\.ms)), "first_delta_ms": dist(ok.compactMap(\.firstDeltaMs))]
    }

    func byTokenBin(_ st: [SentenceStat]) -> [String: Any] {
        let bins: [(String, ClosedRange<Int>)] = [("<400", 0...399), ("400-599", 400...599), ("600-799", 600...799), (">=800", 800...100_000)]
        var r: [String: Any] = [:]
        for (name, range) in bins {
            let xs = st.filter { $0.winner != .apple && range.contains($0.inputTokens ?? -1) }
            if !xs.isEmpty { r[name] = ["n": xs.count, "first_delta_ms": dist(xs.compactMap(\.firstDeltaMs)), "ms": dist(xs.map(\.ms))] }
        }
        return r
    }

    // MARK: hedge A/B (②)

    func hedgeAB() async -> [String: Any] {
        let all = Box<[SentenceStat]>([])
        let speakDone = Box(false)
        let speak = speakClauses, listen = listenSentences
        let n = options.speakCount, nl = options.listenCount
        async let speakLoop: Void = {
            for i in 0..<n {
                let start = ContinuousClock.now
                let (s, t) = speak[i % speak.count]
                let (st, _) = await translate(phase: "hedge", s, t, hedge: i % 2 == 0)
                all.mutate { $0.append(st) }
                let gap = Double.random(in: 2...4)
                let el = Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000
                await pace(max(0, gap - el))
            }
            speakDone.value = true
        }()
        async let listenLoop: Void = {
            var i = 0
            while i < nl {
                let start = ContinuousClock.now
                let (s, t) = listen[i % listen.count]
                // Full MT time: measured with a long deadline, scored against listen.finalMT.deadlineMs.
                let (st, _) = await translate(phase: "listen", s, t, hedge: false, deadlineMs: 10_000)
                all.mutate { $0.append(st) }
                i += 1
                if speakDone.value && i >= nl { break }
                let el = Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000
                await pace(max(0, 6 - el))
            }
        }()
        _ = await (speakLoop, listenLoop)
        // NumberGuard retry injections: both legs from the start (guardRetry.hedgeAfterMs 0).
        let nums = corpus.numberSentences
        let guardPolicy = policy(for: .speakZhEn, hedge: true)
        for i in 0..<options.guardCount {
            let s: MTSession = i % 2 == 0 ? .speakZhEn : .speakZhDe
            let (st, _) = await translate(phase: "guard", s, nums[i % nums.count], hedge: true, kind: .guardRetry,
                                          deadlineMs: guardPolicy.guardRetry.maxMs, policyOverride: guardPolicy)
            all.mutate { $0.append(st) }
            await pace(2)
        }
        let st = all.value
        var r: [String: Any] = [:]
        for on in [true, false] {
            let xs = st.filter { $0.phase == "hedge" && $0.hedgeOn == on }
            let cloudXs = xs.filter { $0.winner != .apple }
            r[on ? "speak_hedge_on" : "speak_hedge_off"] = [
                "n": xs.count, "apple_rate": rate(xs.filter { $0.winner == .apple }.count, xs.count),
                "fired_rate": rate(xs.filter(\.fired).count, xs.count),
                "winner": Dictionary(grouping: xs, by: { $0.winner.rawValue }).mapValues(\.count),
                "reasons": Dictionary(grouping: xs.compactMap(\.reason), by: { $0.rawValue }).mapValues(\.count),
                "ms_cloud": dist(cloudXs.map(\.ms)), "ms_all_apple_at_deadline": dist(xs.map { $0.winner == .apple ? $0.deadlineMs : $0.ms }),
                "first_delta_ms": dist(cloudXs.compactMap(\.firstDeltaMs)),
                "stalls_over_500ms": xs.filter(\.stallOver500).count,
                "incomplete": xs.filter { $0.incomplete != nil }.count,
                "newline_to_end_ms": dist(cloudXs.compactMap(\.newlineToEndMs)),
                "by_input_tokens": byTokenBin(xs)]
        }
        let lx = st.filter { $0.phase == "listen" }
        let deadline = profile.listen.finalMT.deadlineMs
        r["listen"] = ["n": lx.count, "ms": dist(lx.filter { $0.winner != .apple }.map(\.ms)),
                       "within_deadline_rate": rate(lx.filter { $0.winner != .apple && $0.ms <= deadline }.count, lx.count),
                       "deadline_ms": deadline, "note": "LISTEN miss rate = this MT distribution convolved with T10 ④ finalizeToFinal"]
        let gx = st.filter { $0.phase == "guard" }
        r["guard_retry"] = ["n": gx.count, "ms": dist(gx.filter { $0.winner != .apple }.map(\.ms)),
                            "within_floor_rate": rate(gx.filter { $0.winner != .apple && $0.ms <= profile.speak.mt.guardRetry.floorMs }.count, gx.count),
                            "floor_ms": profile.speak.mt.guardRetry.floorMs]
        r["echo_checks"] = echoChecks(st)
        return r
    }

    // MARK: keep-warm (④)

    struct Single: Sendable {
        var id: String?
        var status: Int?
        var headersMs: Int?
        var firstDeltaMs: Int?
        var endMs: Int?
        var cancelled = false
        var echo: ResponseEcho?
        var error: OpenAIErrorInfo?
    }

    enum CancelPoint: Sendable { case afterHeaders, afterFirstDelta }

    /// One request on one leg without hedging (for ④ ⑤ ⑦).
    func single(phase: String, leg: Leg, _ s: MTSession, _ text: String, effort: String? = nil, model: String? = nil,
                maxOut: Int? = nil, cancelAt: CancelPoint? = nil, tag: String = "") async -> Single {
        var r = Single()
        guard let b = try? body(s, text, maxOutputTokens: maxOut, effort: effort, model: model, withHistory: false) else { return r }
        let t0 = ContinuousClock.now
        func now() -> Int { Int((ContinuousClock.now - t0) / .milliseconds(1)) }
        var acc = ResponseAccumulator()
        do {
            loop: for try await item in client.stream(leg: leg, body: b) {
                switch item {
                case .started(let id): r.id = id
                case .headers(let h):
                    r.status = h.status; r.headersMs = now()
                    if cancelAt == .afterHeaders { r.cancelled = true; break loop }
                case .httpError(let h, let info):
                    r.status = h.status; r.headersMs = now(); r.error = info
                case .sse(let e):
                    for sig in acc.consume(e) where sig == .delta && r.firstDeltaMs == nil {
                        r.firstDeltaMs = now()
                        if cancelAt == .afterFirstDelta { r.cancelled = true; break loop }
                    }
                }
            }
        } catch {}
        r.endMs = now()
        r.echo = acc.final
        if r.error == nil { r.error = acc.error }
        records.write("single", ["phase": phase, "tag": tag, "leg": leg.rawValue, "client_request_id": r.id ?? NSNull(),
                                 "status": r.status ?? NSNull(), "headers_ms": r.headersMs ?? NSNull(),
                                 "first_delta_ms": r.firstDeltaMs ?? NSNull(), "end_ms": r.endMs ?? NSNull(), "cancelled": r.cancelled,
                                 "echo_status": r.echo?.status ?? NSNull(), "incomplete_reason": r.echo?.incompleteReason ?? NSNull(),
                                 "reasoning_tokens": r.echo?.reasoningTokens ?? NSNull(), "effort": effort ?? cloud.effort,
                                 "max_output_tokens": maxOut ?? self.maxOut(s)])
        return r
    }

    func keepWarm() async -> [String: Any] {
        let warmPath = cloud.keepWarmPath.replacingOccurrences(of: "{model}", with: cloud.model)
        var trials: [(idle: Int, warm: Bool, leg: Leg, single: Single)] = []
        let clause = speakClauses
        var k = 0
        for idle in options.idleS {
            for warm in [false, true] {
                // Establish both connections, then idle with or without keep-warm.
                _ = try? await client.get(leg: .A, path: warmPath)
                _ = try? await client.get(leg: .B, path: warmPath)
                let kw = KeepWarm(client: client, cloud: cloud, model: cloud.model, isEnabled: { true }, warmB: { true }, sink: sink)
                if warm { await kw.start() }
                await pace(Double(idle))
                await kw.stop()
                for leg in Leg.allCases {
                    let (s, t) = clause[k % clause.count]; k += 1
                    trials.append((idle, warm, leg, await single(phase: "keepwarm", leg: leg, s, t, tag: "idle\(idle)_\(warm ? "warm" : "cold")")))
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(500))   // let metrics arrive
        var rows: [[String: Any]] = []
        for t in trials {
            let m = metrics[t.single.id]
            rows.append(["idle_s": t.idle, "keepwarm": t.warm, "leg": t.leg.rawValue, "reused": m?.reusedConnection ?? NSNull(),
                         "headers_ms": t.single.headersMs ?? NSNull(), "first_delta_ms": t.single.firstDeltaMs ?? NSNull(),
                         "total_ms": t.single.endMs ?? NSNull(), "connect_ms": m?.connectMs ?? NSNull(), "tls_ms": m?.tlsMs ?? NSNull()])
        }
        // Does the next request after a cancelled stream reuse the connection?
        var afterCancel: [[String: Any]] = []
        for i in 0..<10 {
            let (s, t) = clause[(k + i) % clause.count]
            let c = await single(phase: "keepwarm", leg: .A, s, t, cancelAt: i % 2 == 0 ? .afterHeaders : .afterFirstDelta, tag: "cancel")
            let next = await single(phase: "keepwarm", leg: .A, s, t, tag: "after_cancel")
            try? await Task.sleep(for: .milliseconds(200))
            afterCancel.append(["cancel_at": i % 2 == 0 ? "headers" : "first_delta", "cancelled": c.cancelled,
                                "next_reused": metrics[next.id]?.reusedConnection ?? NSNull(), "next_headers_ms": next.headersMs ?? NSNull()])
            await pace(1)
        }
        // GET /v1/models/{model} timing.
        var getMs: [Int] = []
        for _ in 0..<10 {
            let t0 = ContinuousClock.now
            if let r = try? await client.get(leg: .A, path: warmPath), r.headers.status == 200 {
                getMs.append(Int((ContinuousClock.now - t0) / .milliseconds(1)))
            }
            await pace(1)
        }
        return ["trials": rows, "after_cancel": afterCancel, "keepwarm_get_ms": dist(getMs),
                "reused_rate_warm": rate(rows.filter { ($0["keepwarm"] as? Bool) == true && ($0["reused"] as? Bool) == true }.count,
                                         rows.filter { ($0["keepwarm"] as? Bool) == true }.count)]
    }

    // MARK: faults (⑥)

    func faults() async -> [String: Any] {
        let n = options.injectCount
        let clause = speakClauses
        var out: [String: Any] = [:]
        struct Case { var name: String; var setup: @Sendable () -> Void; var policy: HedgePolicy? }
        var alwaysHedge = policy(for: .speakZhEn, hedge: true)
        alwaysHedge.hedge.afterMs = 1   // B is always sent, so a 429 only on B can be injected against a real A
        let cases: [Case] = [
            Case(name: "offline", setup: { FaultInjector.arm(.A, .offline); FaultInjector.arm(.B, .offline) }, policy: nil),
            Case(name: "429_retry_after_on_A", setup: { FaultInjector.arm(.A, .status(429, retryAfterS: 20, code: nil, type: "requests")) }, policy: nil),
            Case(name: "429_on_B_only", setup: { FaultInjector.arm(.B, .status(429, retryAfterS: nil, code: nil, type: "requests")) }, policy: alwaysHedge),
            Case(name: "5xx_on_A", setup: { FaultInjector.arm(.A, .status(503, retryAfterS: nil, code: nil, type: "server_error")) }, policy: nil),
            Case(name: "timeout_both", setup: { FaultInjector.arm(.A, .blackhole); FaultInjector.arm(.B, .blackhole) }, policy: nil),
        ]
        var k = 0
        for c in cases {
            var xs: [SentenceStat] = []
            var health = CloudHealth(cloud: cloud)
            var gates: [String: Int] = [:]
            var pauses: [Int] = []
            for i in 0..<n {
                FaultInjector.disarmAll()
                c.setup()
                let (s, t) = clause[k % clause.count]; k += 1
                let (st, o) = await translate(phase: "faults", tag: c.name, s, t, hedge: true, policyOverride: c.policy)
                xs.append(st)
                if let p = o.hedgePauseS { pauses.append(p) }
                // How the shared state would gate the next sentence (fresh clock per trial).
                _ = health.gate(.speak, now: i * 10_000)
                for line in health.record(.speak, decision: o.decision, hedgePauseS: o.hedgePauseS, now: i * 10_000) {
                    records.write("breaker", ["case": c.name, "state": line])
                }
                switch health.gate(.speak, now: i * 10_000 + 1) {
                case .cloud(let probe): gates[probe ? "cloud_probe" : "cloud", default: 0] += 1
                case .apple(let why): gates[why, default: 0] += 1
                }
                health = CloudHealth(cloud: cloud)
                await pace(1)
            }
            FaultInjector.disarmAll()
            let apple = xs.filter { $0.winner == .apple }
            out[c.name] = ["n": xs.count, "winner": Dictionary(grouping: xs, by: { $0.winner.rawValue }).mapValues(\.count),
                           "fallback": Dictionary(grouping: xs.compactMap(\.fallback), by: { $0 }).mapValues(\.count),
                           "apple_started_exactly_once_when_apple": apple.allSatisfy { $0.appleStarts == 1 },
                           "apple_started_more_than_once": xs.filter { $0.appleStarts > 1 }.count,
                           "ms": dist(xs.map(\.ms)), "hedge_pause_s": pauses, "next_gate": gates]
        }
        return out
    }

    // MARK: reset injection (⑨, injected half)

    func resetInjection() async -> [String: Any] {
        var out: [String: Any] = [:]
        let clause = speakClauses, listen = listenSentences
        // (a) SPEAK: A gives no headers; hedges win; within 2 sentences A must be rebuilt.
        do {
            var policy = SessionResetPolicy(config: cloud.sessionReset)
            FaultInjector.disarmAll()
            FaultInjector.arm(.A, .blackhole, count: 5)
            var rebuiltAt: Int?
            var rows: [[String: Any]] = []
            for i in 0..<5 {
                let (s, t) = clause[i % clause.count]
                let (st, o) = await translate(phase: "reset", tag: "speak_no_headers", s, t, hedge: true)
                var resets: [SessionResetPolicy.Reset] = []
                if st.fired, st.winner != .apple {
                    let loser: Leg = st.winner == .A ? .B : .A
                    resets = policy.recordHedgeWin(winner: st.winner == .A ? .A : .B, loserHadHeaders: o.legs[loser]?.headersMs != nil)
                }
                for r in resets {
                    client.rebuild(r.leg); sink(.sessionReset(leg: r.leg, reason: r.reason))
                    if r.leg == .A { rebuiltAt = rebuiltAt ?? i; FaultInjector.disarmAll() }
                }
                rows.append(["i": i, "winner": st.winner.rawValue, "fired": st.fired, "resets": resets.map { "\($0.leg.rawValue):\($0.reason)" }])
                await pace(2)
            }
            out["speak_no_headers"] = ["rebuilt_A_at_sentence": j(rebuiltAt), "within_2": (rebuiltAt ?? 99) <= 1, "rows": rows]
        }
        // (b) LISTEN only: A gives no headers; then keep-warm on A fails twice.
        do {
            var policy = SessionResetPolicy(config: cloud.sessionReset)
            FaultInjector.disarmAll()
            FaultInjector.arm(.A, .blackhole, count: 4)
            var rebuiltAt: Int?
            for i in 0..<4 {
                let (s, t) = listen[i % listen.count]
                let (_, o) = await translate(phase: "reset", tag: "listen_no_headers", s, t, hedge: false)
                let h = o.legs[.A]?.headersMs.flatMap { hm in o.legs[.A]?.sentMs.map { hm - $0 } }
                for r in policy.recordListenRequest(headersAfterMs: h) {
                    client.rebuild(r.leg); sink(.sessionReset(leg: r.leg, reason: r.reason))
                    if r.leg == .A { rebuiltAt = rebuiltAt ?? i; FaultInjector.disarmAll() }
                }
                await pace(6)
            }
            out["listen_no_headers"] = ["rebuilt_A_at_request": j(rebuiltAt), "within_2": (rebuiltAt ?? 99) <= 1]
            FaultInjector.disarmAll()
            FaultInjector.arm(.A, .status(500, retryAfterS: nil, code: nil, type: "server_error"), target: .get, count: 3)
            let kw = KeepWarm(client: client, cloud: cloud, model: cloud.model, isEnabled: { true }, warmB: { false }, sink: sink)
            var kwRebuilt: Int?
            for i in 0..<3 {
                let ok = await kw.warm(.A)
                for r in policy.recordKeepWarm(.A, ok: ok) {
                    client.rebuild(r.leg); sink(.sessionReset(leg: r.leg, reason: r.reason))
                    kwRebuilt = kwRebuilt ?? i; FaultInjector.disarmAll()
                }
            }
            out["keepwarm_failures"] = ["rebuilt_A_after_failures": j(kwRebuilt.map { $0 + 1 }), "expected": cloud.sessionReset.keepWarmFailuresInARow]
        }
        FaultInjector.disarmAll()
        return out
    }

    // MARK: cancel billing (⑤)

    func cancelBilling() async -> [String: Any] {
        guard options.confirmCancelProject else {
            return ["skipped": "run alone, with a key from a separate project, and pass --confirm-separate-project"]
        }
        let start = ISO8601DateFormatter().string(from: Date())
        var before = 0, after = 0
        let clause = speakClauses
        for i in 0..<options.cancelCount {
            let (s, t) = clause[i % clause.count]
            let r = await single(phase: "cancel", leg: .A, s, t, cancelAt: i % 2 == 0 ? .afterHeaders : .afterFirstDelta,
                                 tag: i % 2 == 0 ? "before_first_delta" : "after_first_delta")
            if r.cancelled { if i % 2 == 0 { before += 1 } else { after += 1 } }
            await pace(2)
        }
        return ["window_utc": ["start": start, "end": ISO8601DateFormatter().string(from: Date())], "model": cloud.model,
                "cancelled_before_first_delta": before, "cancelled_after_first_delta": after,
                "next": "compare the usage dashboard for this project, model and window (x-request-ids are in the .jsonl)"]
    }

    // MARK: watch (⑨, manual half: sleep/wake, network changes)

    func watch() async -> [String: Any] {
        let pending = Box<[String]>([])
        // The observer lives until the bench process exits.
        await MainActor.run {
            _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                pending.mutate { $0.append("wake") }
            }
        }
        let net = NetworkHealth()
        let netTask = Task { for await c in net.changes { pending.mutate { $0.append("\(c)") } } }
        var policy = SessionResetPolicy(config: cloud.sessionReset)
        var rows: [[String: Any]] = []
        var health = CloudHealth(cloud: cloud)
        let end = ContinuousClock.now + .seconds(options.watchMinutes * 60)
        let clause = speakClauses
        var i = 0
        var lastEvent: String?
        while ContinuousClock.now < end {
            let events = pending.value; pending.value = []
            for e in events {
                records.write("watch_event", ["event": e])
                switch e {
                case "wake": for r in policy.onWake() { client.rebuild(r.leg); sink(.sessionReset(leg: r.leg, reason: r.reason)) }; lastEvent = "wake"
                case "pathChanged": for r in policy.onPathChange() { client.rebuild(r.leg); sink(.sessionReset(leg: r.leg, reason: r.reason)) }; lastEvent = "pathChanged"
                case "offline": health.setOffline(true); lastEvent = "offline"
                case "online": health.setOffline(false); lastEvent = lastEvent ?? "online"
                default: break
                }
            }
            if case .apple(let why) = health.gate(.speak, now: i) {
                records.write("watch_skip", ["reason": why])
            } else {
                let (s, t) = clause[i % clause.count]
                let (st, _) = await translate(phase: "watch", tag: lastEvent.map { "first_after_\($0)" } ?? "", s, t, hedge: true)
                if let ev = lastEvent {
                    try? await Task.sleep(for: .milliseconds(300))
                    rows.append(["after": ev, "ms": st.ms, "winner": st.winner.rawValue, "fired": st.fired,
                                 "reused_A": metrics[st.ids[.A]]?.reusedConnection ?? NSNull()])
                    lastEvent = nil
                }
            }
            i += 1
            await pace(10)
        }
        netTask.cancel()
        return ["first_sentence_after_event": rows, "sentences": i,
                "first_after_event_went_to_apple": rows.filter { ($0["winner"] as? String) == "apple" }.count]
    }

    // MARK: keychain (⑧, automatic part) and the secret scan

    func keychainPhase(_ read: Any?) -> [String: Any] {
        var r: [String: Any] = ["read": read.map { $0 } ?? NSNull()]
        r["manual"] = "ad-hoc rebuild twice + read; a different ad-hoc program with the same identifier; see docs/m0-t4-howto.md"
        return r
    }

    func connectionSummary() -> [String: Any] {
        let all = metrics.everything
        var r: [String: Any] = [:]
        for leg in Leg.allCases {
            let xs = all.filter { $0.leg == leg }
            r[leg.rawValue] = ["n": xs.count, "reused_rate": rate(xs.filter { $0.reusedConnection == true }.count, xs.count),
                               "protocols": Dictionary(grouping: xs.compactMap(\.protocolName), by: { $0 }).mapValues(\.count),
                               "local_ports": Set(xs.compactMap(\.localPort)).count]
        }
        let pa = Set(all.filter { $0.leg == .A }.compactMap(\.localPort)), pb = Set(all.filter { $0.leg == .B }.compactMap(\.localPort))
        r["shared_local_ports_A_B"] = pa.intersection(pb).count
        return r
    }

    /// Counts occurrences of the key and of `error.message` fields in this run's own output.
    func scan(summaryObject: [String: Any]) -> [String: Any] {
        var texts: [String] = []
        if let u = records.url, let d = try? Data(contentsOf: u) { texts.append(String(decoding: d, as: UTF8.self)) }
        if let d = try? JSONSerialization.data(withJSONObject: summaryObject) { texts.append(String(decoding: d, as: UTF8.self)) }
        let joined = texts.joined(separator: "\n")
        let keyHits = joined.components(separatedBy: key).count - 1
        let tail = String(key.suffix(12))
        let tailHits = joined.components(separatedBy: tail).count - 1
        let messageHits = joined.components(separatedBy: "\"message\"").count - 1
        return ["key_occurrences": keyHits, "key_tail_occurrences": tailHits, "error_message_fields": messageHits,
                "clean": keyHits == 0 && tailHits == 0 && messageHits == 0]
    }
}

// MARK: - Stats helpers

func dist(_ xs: [Int]) -> [String: Any] {
    guard !xs.isEmpty else { return ["n": 0] }
    let s = xs.sorted()
    func p(_ q: Double) -> Int { s[min(s.count - 1, max(0, Int((q * Double(s.count)).rounded(.up)) - 1))] }
    return ["n": s.count, "p50": p(0.5), "p90": p(0.9), "p95": p(0.95), "p99": p(0.99), "max": s.last!, "min": s.first!]
}

/// JSON value or null.
func j<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }

func rate(_ k: Int, _ n: Int) -> Any { n == 0 ? NSNull() : (Double(k) / Double(n) * 1000).rounded() / 1000 }
#endif
