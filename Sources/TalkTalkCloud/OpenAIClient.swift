import Foundation
import Synchronization
import TalkTalkCore

/// Per-request connection facts from URLSessionTaskMetrics (§6.3 "记录"). Built from the last
/// transaction only; `transactionMetrics[i].request` carries Authorization and is never read.
public struct RequestMetrics: Sendable, Equatable, Codable {
    public var leg: Leg
    /// The attempt's X-Client-Request-Id (joins metrics to bench records).
    public var clientRequestID: String?
    public var protocolName: String?
    public var reusedConnection: Bool?
    public var localPort: Int?
    public var remotePort: Int?
    public var connectMs: Double?
    public var tlsMs: Double?
    public var requestToResponseStartMs: Double?
    public var taskMs: Double?
    public var redirects: Int

    public init(leg: Leg, protocolName: String? = nil, reusedConnection: Bool? = nil, localPort: Int? = nil,
                remotePort: Int? = nil, connectMs: Double? = nil, tlsMs: Double? = nil,
                requestToResponseStartMs: Double? = nil, taskMs: Double? = nil, redirects: Int = 0) {
        self.leg = leg; self.protocolName = protocolName; self.reusedConnection = reusedConnection
        self.localPort = localPort; self.remotePort = remotePort; self.connectMs = connectMs; self.tlsMs = tlsMs
        self.requestToResponseStartMs = requestToResponseStartMs; self.taskMs = taskMs; self.redirects = redirects
    }

    init(leg: Leg, clientRequestID: String?, _ m: URLSessionTaskMetrics) {
        self.init(leg: leg, redirects: m.redirectCount)
        self.clientRequestID = clientRequestID
        taskMs = m.taskInterval.duration * 1000
        guard let t = m.transactionMetrics.last else { return }
        protocolName = t.networkProtocolName
        reusedConnection = t.isReusedConnection
        localPort = t.localPort.map { Int($0) }
        remotePort = t.remotePort.map { Int($0) }
        func ms(_ a: Date?, _ b: Date?) -> Double? { guard let a, let b else { return nil }; return b.timeIntervalSince(a) * 1000 }
        connectMs = ms(t.connectStartDate, t.connectEndDate)
        tlsMs = ms(t.secureConnectionStartDate, t.secureConnectionEndDate)
        requestToResponseStartMs = ms(t.requestStartDate, t.responseStartDate)
    }
}

/// Response headers worth logging (§6.3). No cookies, no other headers.
public struct OpenAIResponseHeaders: Sendable, Equatable, Codable {
    public var status: Int
    public var requestID: String?
    public var processingMs: Int?
    public var remainingRequests: String?
    public var remainingTokens: String?
    public var retryAfterS: Int?

    public init(status: Int, requestID: String? = nil, processingMs: Int? = nil, remainingRequests: String? = nil,
                remainingTokens: String? = nil, retryAfterS: Int? = nil) {
        self.status = status; self.requestID = requestID; self.processingMs = processingMs
        self.remainingRequests = remainingRequests; self.remainingTokens = remainingTokens; self.retryAfterS = retryAfterS
    }

    init(_ r: HTTPURLResponse) {
        func h(_ k: String) -> String? { r.value(forHTTPHeaderField: k) }
        self.init(status: r.statusCode, requestID: h("x-request-id"), processingMs: h("openai-processing-ms").flatMap { Int($0) },
                  remainingRequests: h("x-ratelimit-remaining-requests"), remainingTokens: h("x-ratelimit-remaining-tokens"),
                  retryAfterS: OpenAIErrorClassifier.retryAfterSeconds(h("retry-after")))
    }
}

/// Everything the cloud layer logs. Numbers, codes and ids only: never a key, never request or
/// response text, never `error.message` (§7.7).
public enum CloudEvent: Sendable, Equatable {
    case request(leg: Leg, path: String, clientRequestID: String)
    case response(leg: Leg, OpenAIResponseHeaders)
    case error(leg: Leg, status: Int, OpenAIErrorInfo?)
    case metrics(RequestMetrics)
    case hedge(HedgeOutcome)
    case validation(leg: Leg, reject: String?, storeEchoMissing: Bool, partial: Bool)
    case keepWarm(leg: Leg, ok: Bool, ms: Double)
    case sessionReset(leg: Leg, reason: String)
    case breaker(String)
    case fallback(String)
}

public typealias CloudEventSink = @Sendable (CloudEvent) -> Void

/// The app's only HTTPS client for OpenAI (§6.3): two long-lived `.ephemeral` URLSessions,
/// A (all MT) and B (hedge copies only). Each has its own connection pool (O17; T4 ③ checks
/// the ports). The key is read through `keyProvider` for each request, goes only into the
/// Authorization header, and is never logged.
public final class OpenAIClient: Sendable {
    public enum ClientError: Error, Sendable, Equatable {
        case noKey
        case badURL
        case notHTTP
    }

    /// One item of a streamed response.
    public enum StreamItem: Sendable {
        /// Yielded first, before any network I/O.
        case started(clientRequestID: String)
        case headers(OpenAIResponseHeaders)
        case sse(SSEEvent)
        /// Non-200: the error body's code/type (message discarded), then the stream ends.
        case httpError(OpenAIResponseHeaders, OpenAIErrorInfo?)
    }

    public let cloud: PolicyProfile.Cloud
    private let keyProvider: @Sendable () throws -> String
    private let protocolClasses: [Leg: [AnyClass]]
    private let sessions: Mutex<[Leg: URLSession]>
    private let sink: CloudEventSink

    /// `protocolClasses`: tests (fake server) and dev fault injection only.
    public init(cloud: PolicyProfile.Cloud, keyProvider: @escaping @Sendable () throws -> String,
                protocolClasses: [Leg: [AnyClass]] = [:], sink: @escaping CloudEventSink = { _ in }) {
        self.cloud = cloud
        self.keyProvider = keyProvider
        self.protocolClasses = protocolClasses
        self.sink = sink
        var s: [Leg: URLSession] = [:]
        for leg in Leg.allCases { s[leg] = Self.makeSession(cloud: cloud, protocols: protocolClasses[leg]) }
        self.sessions = Mutex(s)
    }

    deinit {
        sessions.withLock { for s in $0.values { s.invalidateAndCancel() } }
    }

    static func makeSession(cloud: PolicyProfile.Cloud, protocols: [AnyClass]?) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = TimeInterval(cloud.requestTimeoutS)   // idle timer only; deadlines cancel
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        if let protocols { c.protocolClasses = protocols + (c.protocolClasses ?? []) }
        return URLSession(configuration: c)
    }

    /// Rebuilds one session (§6.4 step 6): `invalidateAndCancel` on the old one, a new pool.
    /// Requests already running on the old session are cancelled with it.
    public func rebuild(_ leg: Leg) {
        let old = sessions.withLock { s -> URLSession? in
            let o = s[leg]
            s[leg] = Self.makeSession(cloud: cloud, protocols: protocolClasses[leg])
            return o
        }
        old?.invalidateAndCancel()
    }

    func session(_ leg: Leg) -> URLSession { sessions.withLock { $0[leg]! } }

    func request(path: String, method: String, body: Data?, streaming: Bool) throws -> (URLRequest, String) {
        guard let url = cloud.url(path) else { throw ClientError.badURL }
        let key: String
        do { key = try keyProvider() } catch { throw ClientError.noKey }
        guard !key.isEmpty else { throw ClientError.noKey }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = TimeInterval(cloud.requestTimeoutS)
        let id = UUID()
        for (k, v) in OpenAIRequestBuilder.headers(clientRequestID: id, streaming: streaming) where body != nil || k != "Content-Type" {
            r.setValue(v, forHTTPHeaderField: k)
        }
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return (r, id.uuidString.lowercased())
    }

    /// POST /v1/responses with `body` on `leg`. Cancelling the consuming task cancels the
    /// URLSession task. Throws URLError for transport failures.
    public func stream(leg: Leg, body: Data) -> AsyncThrowingStream<StreamItem, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (req, id) = try request(path: cloud.responsesPath, method: "POST", body: body, streaming: true)
                    sink(.request(leg: leg, path: cloud.responsesPath, clientRequestID: id))
                    continuation.yield(.started(clientRequestID: id))
                    let delegate = MetricsDelegate(leg: leg, clientRequestID: id, sink: sink)
                    let (bytes, response) = try await session(leg).bytes(for: req, delegate: delegate)
                    guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }
                    let headers = OpenAIResponseHeaders(http)
                    sink(.response(leg: leg, headers))
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 65_536 { break } }
                        let info = OpenAIErrorInfo.parse(data)
                        data.resetBytes(in: 0..<data.count)
                        sink(.error(leg: leg, status: http.statusCode, info))
                        continuation.yield(.httpError(headers, info))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.headers(headers))
                    var parser = SSEParser()
                    for try await b in bytes {
                        if let e = parser.feed(byte: b) { continuation.yield(.sse(e)) }
                    }
                    if let e = parser.finish() { continuation.yield(.sse(e)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public struct Reply: Sendable {
        public var headers: OpenAIResponseHeaders
        public var body: Data
        public var error: OpenAIErrorInfo?
        public var clientRequestID: String
    }

    /// A small GET (model list, keep-warm `GET /v1/models/{model}`, `GET /v1/responses/{id}`).
    public func get(leg: Leg, path: String) async throws -> Reply {
        let (req, id) = try request(path: path, method: "GET", body: nil, streaming: false)
        sink(.request(leg: leg, path: path, clientRequestID: id))
        let (data, response) = try await session(leg).data(for: req, delegate: MetricsDelegate(leg: leg, clientRequestID: id, sink: sink))
        guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }
        let headers = OpenAIResponseHeaders(http)
        sink(.response(leg: leg, headers))
        if http.statusCode != 200 {
            let info = OpenAIErrorInfo.parse(data)
            sink(.error(leg: leg, status: http.statusCode, info))
            return Reply(headers: headers, body: Data(), error: info, clientRequestID: id)
        }
        return Reply(headers: headers, body: data, error: nil, clientRequestID: id)
    }
}

final class MetricsDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let leg: Leg
    let clientRequestID: String
    let sink: CloudEventSink
    init(leg: Leg, clientRequestID: String, sink: @escaping CloudEventSink) {
        self.leg = leg; self.clientRequestID = clientRequestID; self.sink = sink
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        sink(.metrics(RequestMetrics(leg: leg, clientRequestID: clientRequestID, metrics)))
    }
}
