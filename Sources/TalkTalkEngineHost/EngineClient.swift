import Foundation
import Synchronization
import TalkTalkCore

/// HTTP client of the engine API v2 (§4.4, §7.6). Two URLSessions so long chunked `/v1/tts` and
/// `/v1/asr` calls can never make `/v1/cancel`, `/v1/playout` and `/v1/health` wait:
/// - control: one keep-alive connection, small requests only;
/// - data: up to 8 connections, ASR, TTS and voice.
/// Both are ephemeral (no cookies, cache or credential store) and bypass any system proxy: the
/// engine is on 127.0.0.1 only. OpenAI never goes through these sessions (`TalkTalkCloud`).
public final class EngineClient: Sendable {
    public let port: Int
    private let token: String
    private let control: URLSession
    private let data: URLSession
    private let router: StreamRouter
    /// Set by `invalidate()`. Tasks are created only under this lock: URLSession raises an
    /// Objective-C exception when a task is created on an invalidated session.
    private let invalidated = Mutex(false)

    public init(port: Int, token: String, controlTimeout: TimeInterval = 2, dataIdleTimeout: TimeInterval = 30) {
        self.port = port
        self.token = token
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 1
        c.timeoutIntervalForRequest = controlTimeout
        c.connectionProxyDictionary = [:]
        c.urlCache = nil
        c.waitsForConnectivity = false
        control = URLSession(configuration: c)
        let d = URLSessionConfiguration.ephemeral
        d.httpMaximumConnectionsPerHost = 8
        d.timeoutIntervalForRequest = dataIdleTimeout
        d.connectionProxyDictionary = [:]
        d.urlCache = nil
        d.waitsForConnectivity = false
        let r = StreamRouter()
        router = r
        data = URLSession(configuration: d, delegate: r, delegateQueue: nil)
    }

    deinit {
        control.invalidateAndCancel()
        data.invalidateAndCancel()
    }

    /// Cancels everything in flight (engine stopped or restarted); later calls throw `.invalidated`.
    public func invalidate() {
        invalidated.withLock { flag in
            guard !flag else { return }
            flag = true
            control.invalidateAndCancel()
            data.invalidateAndCancel()
        }
    }

    public var isInvalidated: Bool { invalidated.withLock { $0 } }

    private func makeTask(_ session: URLSession, _ req: URLRequest,
                          completion: (@Sendable (Data?, URLResponse?, Error?) -> Void)? = nil) throws -> URLSessionDataTask {
        try invalidated.withLock { flag in
            if flag { throw EngineAPIError.invalidated }
            if let completion { return session.dataTask(with: req, completionHandler: completion) }
            return session.dataTask(with: req)
        }
    }

    // MARK: control session

    public func health(timeout: TimeInterval? = nil) async throws -> EngineHealth {
        var req = request("GET", "/v1/health")
        if let timeout { req.timeoutInterval = timeout }
        return try decode(EngineHealth.self, try await controlCall(req, expect: [200]))
    }

    public func setSession(meeting: Bool, speakActive: Bool, langs: [String] = []) async throws {
        var req = request("POST", "/v1/session")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["meeting": meeting, "speak_active": speakActive, "langs": langs])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await controlCall(req, expect: [204])
    }

    /// `PlayoutReport` (§4.4): SPEAK reports its buffer every 100 ms on the control connection.
    public func playout(bufferedMs: Double) async throws {
        try await postPlayout(["bufferedMs": bufferedMs])
    }

    /// §4.4: the body is the PlayoutReport. The engine scheduler reads `bufferedMs`; the other
    /// fields are carried for its logs and the §6.1 deadlines. `job` is the wire id.
    public func playout(_ p: PlayoutReport, job: String?) async throws {
        var body: [String: Any] = ["bufferedMs": p.bufferedMs, "underruns": p.underruns, "paused": p.paused,
                                   "tempo": p.tempo, "epoch": p.epoch]
        if let job { body["job"] = job }
        try await postPlayout(body)
    }

    /// A report older than a few cadences is useless, and the control session has one connection
    /// (health and cancel queue behind it), so a playout POST gives up quickly.
    public static let playoutTimeout: TimeInterval = 0.3

    private func postPlayout(_ body: [String: Any]) async throws {
        var req = request("POST", "/v1/playout")
        req.timeoutInterval = Self.playoutTimeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await controlCall(req, expect: [204])
    }

    public enum CancelScope: String, Sendable { case speak, listen, all }

    public func cancel(job: String) async throws {
        try await postCancel(["job": job])
    }

    public func cancel(scope: CancelScope) async throws {
        try await postCancel(["scope": scope.rawValue])
    }

    private func postCancel(_ body: [String: String]) async throws {
        var req = request("POST", "/v1/cancel")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await controlCall(req, expect: [204])
    }

    public func stats() async throws -> Data {
        try await controlCall(request("GET", "/v1/stats"), expect: [200])
    }

    // MARK: data session

    public struct VoiceBuildResult: Sendable {
        public let milliseconds: [String: Double]
        public let keyMaterial: String
        public let frames: Int?
        public let blob: Data
    }

    /// `/v1/voice/build` (§4.4, recording "my voice"): reference PCM in, conditioning blob out.
    /// The engine never writes it to disk; the app stores it (§9.3).
    public func buildVoice(reference24k: [Float], refText: String, model: String?) async throws -> VoiceBuildResult {
        var head: [String: Any] = ["ref_text": refText, "mode": "icl", "lang": "zh"]
        if let model { head["model"] = model }
        var body = try Frames.encodeJSON(.jsonHead, head)
        body.append(Frames.encode(.pcmF32At24k, Frames.pcmF32(reference24k)))
        let resp = try await dataCall(framesRequest("/v1/voice/build", body), expect: [200])
        let frames = try Frames.decodeAll(resp)
        guard let h = frames.first(where: { $0.kind == .jsonHead }), let blob = frames.first(where: { $0.kind == .blob }) else {
            throw EngineAPIError.badResponse("voice/build: head or blob frame missing")
        }
        struct Head: Decodable {
            let ms: [String: Double]
            let key_material: String
            let frames: Int?
        }
        let head2 = try decode(Head.self, h.payload)
        return VoiceBuildResult(milliseconds: head2.ms, keyMaterial: head2.key_material, frames: head2.frames, blob: blob.payload)
    }

    /// `/v1/voice/load`: 202; `/v1/health` then reports `voice.state` loading → ready.
    public func loadVoice(blob: Data, model: String? = nil, key: String? = nil) async throws {
        var head: [String: Any] = [:]
        if let model { head["model"] = model }
        if let key { head["key"] = key }
        var body = try Frames.encodeJSON(.jsonHead, head)
        body.append(Frames.encode(.blob, blob))
        _ = try await dataCall(framesRequest("/v1/voice/load", body), expect: [202])
    }

    public func unloadVoice() async throws {
        _ = try await dataCall(request("POST", "/v1/voice/unload"), expect: [204])
    }

    /// `/v1/voice/similarity`: x-vector cosine (the TTS model's own speaker encoder) between two
    /// 24 kHz mono clips, reference first. Each clip needs ≥ 0.5 s, else `EngineAPIError` with code
    /// `audio_too_short`; without a TTS model, `tts_not_loaded`.
    public func speakerSimilarity(reference24k: [Float], sample24k: [Float]) async throws -> Double {
        var body = try Frames.encodeJSON(.jsonHead, [String: Any]())
        body.append(Frames.encode(.pcmF32At24k, Frames.pcmF32(reference24k)))
        body.append(Frames.encode(.pcmF32At24k, Frames.pcmF32(sample24k)))
        let resp = try await dataCall(framesRequest("/v1/voice/similarity", body), expect: [200])
        struct Reply: Decodable { let cosine: Double }
        return try decode(Reply.self, resp).cosine
    }

    /// `/v1/asr` with 16 kHz mono samples (kind 6). `hint` is the language ("zh", "en", "de") or nil.
    public func asr(samples16k: [Float], hint: String?, priority: Int = 1, job: String? = nil,
                    context: String? = nil) async throws -> ASRResult {
        var q = ["priority=\(priority)"]
        if let hint { q.append("hint=\(hint)") }
        if let job { q.append("job=\(job)") }
        var head: [String: Any] = [:]
        if let context { head["context"] = context }
        var body = try Frames.encodeJSON(.jsonHead, head)
        body.append(Frames.encode(.pcmS16At16k, Frames.pcmS16(samples16k)))
        let resp = try await dataCall(framesRequest("/v1/asr?" + q.joined(separator: "&"), body), expect: [200])
        return try decode(ASRResult.self, resp)
    }

    /// `/v1/tts`: streams head → PCM chunks → tail (or an error frame). Dropping the stream (or
    /// calling `EngineTTSStream.cancel()`) cancels locally first and then sends `/v1/cancel` (§7.6).
    public func tts(_ request: EngineTTSRequest) -> EngineTTSStream {
        var req = self.request("POST", "/v1/tts")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(request)
        let (stream, cont) = AsyncThrowingStream<EngineTTSEvent, Error>.makeStream()
        let task: URLSessionDataTask
        do {
            task = try makeTask(data, req)
        } catch {
            cont.finish(throwing: error)
            return EngineTTSStream(job: request.job, events: stream, cancelLocal: {}, client: self)
        }
        let state = Mutex(TTSDecodeState())
        router.register(task, StreamRouter.Handler(
            onResponse: { resp in state.withLock { $0.status = resp.statusCode } },
            onData: { chunk in
                let events: Result<[EngineTTSEvent], Error> = state.withLock { st in
                    if st.status != 200 {
                        st.errorBody.append(chunk)
                        return .success([])
                    }
                    do {
                        return .success(try st.decoder.feed(chunk).map(EngineTTSEvent.init(frame:)))
                    } catch {
                        return .failure(error)
                    }
                }
                switch events {
                case .success(let list): list.forEach { cont.yield($0) }
                case .failure(let e):
                    cont.finish(throwing: e)
                    task.cancel()
                }
            },
            onComplete: { error in
                let (status, body) = state.withLock { ($0.status, $0.errorBody) }
                if let error {
                    cont.finish(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                } else if status != 200 {
                    cont.finish(throwing: EngineAPIError.from(status: status, body: body))
                } else {
                    cont.finish()
                }
            }))
        let job = request.job
        let control = self
        cont.onTermination = { reason in
            guard case .cancelled = reason else { return }
            task.cancel()
            Task { try? await control.cancel(job: job) }
        }
        task.resume()
        return EngineTTSStream(job: job, events: stream, cancelLocal: { task.cancel() }, client: self)
    }

    // MARK: plumbing

    private func request(_ method: String, _ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func framesRequest(_ path: String, _ body: Data) -> URLRequest {
        var r = request("POST", path)
        r.setValue(Frames.contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return r
    }

    private func controlCall(_ req: URLRequest, expect: Set<Int>) async throws -> Data {
        let box = Mutex<URLSessionDataTask?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                do {
                    let task = try makeTask(control, req) { body, resp, error in
                        if let error {
                            cont.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                            return
                        }
                        guard let http = resp as? HTTPURLResponse else {
                            cont.resume(throwing: EngineAPIError.badResponse("not HTTP"))
                            return
                        }
                        let b = body ?? Data()
                        if expect.contains(http.statusCode) {
                            cont.resume(returning: b)
                        } else {
                            cont.resume(throwing: EngineAPIError.from(status: http.statusCode, body: b))
                        }
                    }
                    box.withLock { $0 = task }
                    task.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            box.withLock { $0?.cancel() }
        }
    }

    private func dataCall(_ req: URLRequest, expect: Set<Int>) async throws -> Data {
        let task = try makeTask(data, req)
        let collected = Mutex((status: 0, body: Data()))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                router.register(task, StreamRouter.Handler(
                    onResponse: { r in collected.withLock { $0.status = r.statusCode } },
                    onData: { d in collected.withLock { $0.body.append(d) } },
                    onComplete: { error in
                        let (status, body) = collected.withLock { ($0.status, $0.body) }
                        if let error {
                            cont.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                        } else if expect.contains(status) {
                            cont.resume(returning: body)
                        } else {
                            cont.resume(throwing: EngineAPIError.from(status: status, body: body))
                        }
                    }))
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func check(_ resp: URLResponse, _ body: Data, _ expect: Set<Int>) throws -> Data {
        guard let http = resp as? HTTPURLResponse else { throw EngineAPIError.badResponse("not HTTP") }
        guard expect.contains(http.statusCode) else { throw EngineAPIError.from(status: http.statusCode, body: body) }
        return body
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw EngineAPIError.badResponse("\(T.self): \(error)")
        }
    }
}

private struct TTSDecodeState {
    var status = 0
    var decoder = Frames.StreamDecoder()
    var errorBody = Data()
}

/// A running `/v1/tts` request.
public struct EngineTTSStream: Sendable {
    public let job: String
    public let events: AsyncThrowingStream<EngineTTSEvent, Error>
    let cancelLocal: @Sendable () -> Void
    let client: EngineClient

    /// Local cancel (drop this job's chunks, cancel the URLSession task), then `/v1/cancel`
    /// on the control session, in that order (§7.6).
    public func cancel() async {
        cancelLocal()
        try? await client.cancel(job: job)
    }
}

/// Routes data-session delegate callbacks to per-task handlers.
final class StreamRouter: NSObject, URLSessionDataDelegate, Sendable {
    struct Handler: Sendable {
        let onResponse: @Sendable (HTTPURLResponse) -> Void
        let onData: @Sendable (Data) -> Void
        let onComplete: @Sendable (Error?) -> Void
    }

    private let handlers = Mutex<[Int: Handler]>([:])

    func register(_ task: URLSessionTask, _ handler: Handler) {
        handlers.withLock { $0[task.taskIdentifier] = handler }
    }

    private func handler(_ task: URLSessionTask) -> Handler? {
        handlers.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { handler(dataTask)?.onResponse(http) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(dataTask)?.onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let h = handlers.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        h?.onComplete(error)
    }
}

// MARK: wire types

public enum EngineAPIError: Error, Equatable, CustomStringConvertible {
    /// `{"error":{"code","message"}}` (§4.4).
    case http(status: Int, code: String, message: String)
    case badResponse(String)
    /// The engine this client talked to was stopped or restarted.
    case invalidated

    static func from(status: Int, body: Data) -> EngineAPIError {
        struct E: Decodable {
            struct Inner: Decodable { let code: String; let message: String }
            let error: Inner
        }
        if let e = try? JSONDecoder().decode(E.self, from: body) {
            return .http(status: status, code: e.error.code, message: e.error.message)
        }
        return .http(status: status, code: "http_\(status)", message: "")
    }

    public var code: String? {
        if case .http(_, let c, _) = self { return c }
        return nil
    }

    public var description: String {
        switch self {
        case .http(let s, let c, let m): "engine HTTP \(s) \(c): \(m)"
        case .badResponse(let m): "engine bad response: \(m)"
        case .invalidated: "engine client invalidated (engine stopped or restarted)"
        }
    }
}

/// `GET /v1/health` (§4.4). Lenient: unknown fields are ignored, most are optional.
public struct EngineHealth: Decodable, Sendable, Equatable {
    public struct Model: Decodable, Sendable, Equatable {
        public let id: String
        public let rev: String
        public let state: String
    }
    public struct Voice: Decodable, Sendable, Equatable {
        public let state: String
        public let key8: String?
    }
    public struct GPU: Decodable, Sendable, Equatable {
        public let lastStepAgeMs: Double?
        public let inLongStep: Bool
        public let queue: [String: Int]
        public let expiredDropped: Int?
        public let ttsRTFRecent: Double?
        /// p99 step time (ms) per step class (`tts.first`, `tts`, `asr.first`, `asr`, …; §6.1 rule 2/4).
        public let stepP99: [String: Double]?
        /// TTS jobs parked by the render horizon (§6.1 rule 0: paused playback or a full buffer).
        /// They are pending on purpose, so they do not count toward a hang.
        public let parked: Int?

        enum CodingKeys: String, CodingKey {
            case queue, parked
            case lastStepAgeMs = "last_step_age_ms"
            case inLongStep = "in_long_step"
            case expiredDropped = "expired_dropped"
            case ttsRTFRecent = "tts_rtf_recent"
            case stepP99 = "step_p99"
        }

        public init(lastStepAgeMs: Double?, inLongStep: Bool, queue: [String: Int], expiredDropped: Int? = nil,
                    ttsRTFRecent: Double? = nil, stepP99: [String: Double]? = nil, parked: Int? = nil) {
            self.parked = parked
            self.lastStepAgeMs = lastStepAgeMs
            self.inLongStep = inLongStep
            self.queue = queue
            self.expiredDropped = expiredDropped
            self.ttsRTFRecent = ttsRTFRecent
            self.stepP99 = stepP99
        }

        public var pendingJobs: Int { queue.values.reduce(0, +) }
        /// Pending jobs the engine should be stepping: all but the ones parked at the horizon.
        public var activeJobs: Int { max(0, pendingJobs - (parked ?? 0)) }
    }
    public struct Memory: Decodable, Sendable, Equatable {
        public let active: Int64?
        public let cache: Int64?
        public let peak: Int64?
    }
    public let status: String
    public let api: Int
    public let pid: Int32
    public let runtime: String
    public let models: [String: Model]
    public let voice: Voice
    public let gpu: GPU
    public let mem: Memory?
}

/// `/v1/asr` result.
public struct ASRResult: Decodable, Sendable, Equatable {
    public let text: String
    public let language: String?
    public let timing: [String: Double?]
}

/// `EngineTTSRequest` (§4.4). Fields the engine reads: text, lang, job, seed, interval, compiled,
/// temperature, max_frames, prime, debug, voice_key.
public struct EngineTTSRequest: Encodable, Sendable, Equatable {
    public var text: String
    public var lang: String
    public var job: String
    public var seed: Int?
    public var interval: Double?
    public var compiled: Bool?
    public var temperature: Double?
    public var maxFrames: Int?
    public var prime: Bool?
    public var debug: Bool?
    /// §3.3 short clause: render whole, run the guards, then send (nil = the engine decides by
    /// expected duration < 1.5 s).
    public var wholeClause: Bool?
    /// The conditioning identity the caller intends to use. Nil is for legacy bench callers.
    public var voiceKey: String?

    public init(text: String, lang: String, job: String = EngineJobID.make(), seed: Int? = nil,
                interval: Double? = nil, compiled: Bool? = nil, temperature: Double? = nil,
                maxFrames: Int? = nil, prime: Bool? = nil, debug: Bool? = nil, wholeClause: Bool? = nil,
                voiceKey: String? = nil) {
        self.text = text
        self.lang = lang
        self.job = job
        self.seed = seed
        self.interval = interval
        self.compiled = compiled
        self.temperature = temperature
        self.maxFrames = maxFrames
        self.prime = prime
        self.debug = debug
        self.wholeClause = wholeClause
        self.voiceKey = voiceKey
    }

    enum CodingKeys: String, CodingKey {
        case text, lang, job, seed, interval, compiled, temperature, prime, debug
        case maxFrames = "max_frames"
        case wholeClause = "whole_clause"
        case voiceKey = "voice_key"
    }
}

public enum EngineJobID {
    public static func make(prefix: String = "j") -> String {
        prefix + "-" + UUID().uuidString.prefix(12).lowercased()
    }
}

/// The tail of a `/v1/tts` stream (§4.4). Lenient decoding.
public struct EngineTTSTail: Decodable, Sendable, Equatable {
    public let audioS: Double
    public let frames: Int
    public let runaway: Bool
    public let short: Bool
    public let slow: Bool?
    public let cancelled: Bool?
    public let expectedS: Double?
    public let echoAborts: Int?
    public let attempts: Int?
    public let leadTrimMs: Int?
    public let timing: [String: Double?]

    enum CodingKeys: String, CodingKey {
        case frames, runaway, short, slow, cancelled, timing, attempts
        case audioS = "audio_s"
        case expectedS = "expected_s"
        case echoAborts = "echo_aborts"
        case leadTrimMs = "lead_trim_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioS = try c.decode(Double.self, forKey: .audioS)
        frames = try c.decode(Int.self, forKey: .frames)
        runaway = try c.decodeIfPresent(Bool.self, forKey: .runaway) ?? false
        short = try c.decodeIfPresent(Bool.self, forKey: .short) ?? false
        slow = try c.decodeIfPresent(Bool.self, forKey: .slow)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled)
        expectedS = try c.decodeIfPresent(Double.self, forKey: .expectedS)
        echoAborts = try? c.decodeIfPresent(Int.self, forKey: .echoAborts)
        attempts = try? c.decodeIfPresent(Int.self, forKey: .attempts)
        leadTrimMs = try? c.decodeIfPresent(Int.self, forKey: .leadTrimMs)
        // timing values are numbers, null, or (prompt_len, compiled) other scalars: keep numbers only
        let raw = try c.decodeIfPresent([String: LenientNumber].self, forKey: .timing) ?? [:]
        timing = raw.mapValues(\.value)
    }
}

struct LenientNumber: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d } else { value = nil }
    }
}

public enum EngineTTSEvent: Sendable, Equatable {
    /// `seq`: the engine's job number (`Job.seq`, given on HTTP arrival; TTS renders in this order).
    case head(sampleRate: Int, job: String?, seq: Int?)
    case pcm([Float])
    case tail(EngineTTSTail)
    case failed(code: String, message: String)
    /// The engine is holding this job's audio (0.64 s hold, whole clause, retry): alive, no samples.
    case progress(heldS: Double, attempt: Int)
    case unknown(kind: UInt8)

    init(frame: Frame) {
        switch frame.kind {
        case .jsonHead:
            let o = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any]
            self = .head(sampleRate: o?["sample_rate"] as? Int ?? 24000, job: o?["job"] as? String,
                         seq: o?["seq"] as? Int)
        case .pcmF32At24k:
            self = .pcm(Frames.floats(fromF32: frame.payload))
        case .jsonTail:
            if let t = try? JSONDecoder().decode(EngineTTSTail.self, from: frame.payload) {
                self = .tail(t)
            } else {
                self = .failed(code: "bad_tail", message: "tail frame did not decode")
            }
        case .jsonError:
            let o = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any]
            self = .failed(code: o?["code"] as? String ?? "tts_failed", message: o?["message"] as? String ?? "")
        case .jsonProgress:
            let o = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any]
            self = .progress(heldS: o?["held_s"] as? Double ?? 0, attempt: o?["attempt"] as? Int ?? 1)
        default:
            self = .unknown(kind: frame.kind.rawValue)
        }
    }
}
