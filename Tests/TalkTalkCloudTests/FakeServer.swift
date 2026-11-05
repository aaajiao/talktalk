import Foundation
import Synchronization
import TalkTalkCore
@testable import TalkTalkCloud

/// A scripted fake OpenAI server behind URLProtocol. Session A and session B get their own
/// protocol subclass, so the fake knows which leg a request came on. Nothing reaches the network.
enum FakeServer {
    struct Step: Sendable {
        enum Kind: Sendable {
            case respond(Int, [String: String])
            case data(String)
            case finish
            case fail(URLError.Code)
        }
        var atMs: Int
        var kind: Kind
    }

    struct Script: Sendable {
        var steps: [Step]
        /// Answers immediately with `status` and a JSON body.
        static func json(_ status: Int, _ body: String, headers: [String: String] = [:], atMs: Int = 0) -> Script {
            Script(steps: [.init(atMs: atMs, kind: .respond(status, ["Content-Type": "application/json"].merging(headers) { $1 })),
                           .init(atMs: atMs, kind: .data(body)), .init(atMs: atMs, kind: .finish)])
        }
        /// Headers at `headersAtMs`, then nothing: the connection hangs until cancelled.
        static func hang(headersAtMs: Int? = 0) -> Script {
            Script(steps: headersAtMs.map { [.init(atMs: $0, kind: .respond(200, ["Content-Type": "text/event-stream"]))] } ?? [])
        }
        /// A streamed response: headers at `headersAtMs`, then events at their times, then finish.
        static func sse(headersAtMs: Int = 0, _ events: [(Int, String)], finishAtMs: Int? = nil) -> Script {
            var s: [Step] = [.init(atMs: headersAtMs, kind: .respond(200, ["Content-Type": "text/event-stream",
                                                                          "x-request-id": "req_fake"]))]
            for (t, e) in events { s.append(.init(atMs: t, kind: .data(e))) }
            if let f = finishAtMs ?? events.last.map({ $0.0 + 1 }) { s.append(.init(atMs: f, kind: .finish)) }
            return Script(steps: s)
        }
    }

    struct Recorded: Sendable {
        var leg: Leg
        var method: String
        var path: String
        var authorization: String?
        var clientRequestID: String?
    }

    struct State {
        var scripts: [Leg: [Script]] = [:]
        var requests: [Recorded] = []
        var stopped: [Leg: Int] = [:]
        var stoppedRequestIDs: Set<String> = []
    }

    static let state = Mutex(State())

    static func reset() { state.withLock { $0 = State() } }
    static func enqueue(_ leg: Leg, _ scripts: Script...) { state.withLock { $0.scripts[leg, default: []] += scripts } }
    static func requests(_ leg: Leg? = nil) -> [Recorded] { state.withLock { s in s.requests.filter { leg == nil || $0.leg == leg } } }
    static func stopped(_ leg: Leg) -> Int { state.withLock { $0.stopped[leg] ?? 0 } }
    static func wasStopped(_ requestID: String) -> Bool { state.withLock { $0.stoppedRequestIDs.contains(requestID) } }

    static func next(_ leg: Leg, _ r: URLRequest) -> Script {
        state.withLock { s in
            s.requests.append(Recorded(leg: leg, method: r.httpMethod ?? "GET", path: r.url?.path ?? "",
                                       authorization: r.value(forHTTPHeaderField: "Authorization"),
                                       clientRequestID: r.value(forHTTPHeaderField: "X-Client-Request-Id")))
            if var q = s.scripts[leg], !q.isEmpty {
                let first = q.removeFirst(); s.scripts[leg] = q; return first
            }
            return .json(404, #"{"error":{"code":"no_script","type":"test","message":"unscripted"}}"#)
        }
    }

    static func noteStopped(_ leg: Leg, requestID: String?) {
        state.withLock {
            $0.stopped[leg, default: 0] += 1
            if let requestID { $0.stoppedRequestIDs.insert(requestID) }
        }
    }

    // MARK: SSE event builders

    static func event(_ type: String, _ json: String) -> String { "event: \(type)\ndata: \(json)\n\n" }

    static func responseJSON(status: String, effort: String = "none", tier: String = "default", store: Bool? = false,
                             reasoningTokens: Int? = 0, incomplete: String? = nil) -> String {
        var parts = [#""id":"resp_fake""#, #""status":"\#(status)""#, #""reasoning":{"effort":"\#(effort)"}"#,
                     #""service_tier":"\#(tier)""#]
        if let store { parts.append(#""store":\#(store)"#) }
        if let incomplete { parts.append(#""incomplete_details":{"reason":"\#(incomplete)"}"#) }
        if let reasoningTokens {
            parts.append(#""usage":{"input_tokens":120,"output_tokens":9,"output_tokens_details":{"reasoning_tokens":\#(reasoningTokens)}}"#)
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func created(effort: String = "none", tier: String = "default", store: Bool? = false) -> String {
        event("response.created", #"{"type":"response.created","response":\#(responseJSON(status: "in_progress", effort: effort, tier: tier, store: store, reasoningTokens: nil))}"#)
    }
    static func delta(_ text: String) -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]), encoding: .utf8)!
        return event("response.output_text.delta", #"{"type":"response.output_text.delta","delta":\#(escaped.dropFirst().dropLast())}"#)
    }
    static func completed(effort: String = "none", tier: String = "default", store: Bool? = false, reasoningTokens: Int? = 0) -> String {
        event("response.completed", #"{"type":"response.completed","response":\#(responseJSON(status: "completed", effort: effort, tier: tier, store: store, reasoningTokens: reasoningTokens))}"#)
    }

    /// A good response: created at t, the text at t+dt, completed at t+2dt.
    static func good(_ text: String, at t: Int = 5, dt: Int = 10, headersAtMs: Int = 0, effort: String = "none") -> Script {
        .sse(headersAtMs: headersAtMs, [(t, created(effort: effort)), (t + dt, delta(text)), (t + 2 * dt, completed(effort: effort))])
    }
}

class FakeProtocol: URLProtocol, @unchecked Sendable {
    class var leg: Leg { .A }
    private let lock = NSLock()
    private var cancelled = false
    private var done = false
    private let queue = DispatchQueue(label: "talktalk.fake-protocol")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let leg = Self.leg
        let script = FakeServer.next(leg, request)
        let start = DispatchTime.now()
        let url = request.url!
        for step in script.steps {
            queue.asyncAfter(deadline: start + .milliseconds(step.atMs)) { [self] in
                let live: Bool = lock.withLock { !cancelled && !done }
                guard live, let client else { return }
                switch step.kind {
                case .respond(let status, let headers):
                    let r = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                    client.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
                case .data(let s):
                    client.urlProtocol(self, didLoad: Data(s.utf8))
                case .finish:
                    lock.withLock { done = true }
                    client.urlProtocolDidFinishLoading(self)
                case .fail(let code):
                    lock.withLock { done = true }
                    client.urlProtocol(self, didFailWithError: URLError(code))
                }
            }
        }
    }

    override func stopLoading() {
        let wasLive = lock.withLock { () -> Bool in
            defer { cancelled = true }
            return !cancelled && !done
        }
        if wasLive { FakeServer.noteStopped(Self.leg, requestID: request.value(forHTTPHeaderField: "X-Client-Request-Id")) }
    }
}

final class FakeA: FakeProtocol, @unchecked Sendable { override class var leg: Leg { .A } }
final class FakeB: FakeProtocol, @unchecked Sendable { override class var leg: Leg { .B } }

/// Collects every CloudEvent the client and the hedger emit.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CloudEvent] = []
    var sink: CloudEventSink { { [self] e in lock.withLock { items.append(e) } } }
    var events: [CloudEvent] { lock.withLock { items } }
    var rendered: String { events.map { String(reflecting: $0) }.joined(separator: "\n") }
}

enum CloudTestResources {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func profile() throws -> PolicyProfile {
        try PolicyProfile.load(from: repoRoot.appendingPathComponent("Resources/PolicyProfile.default.json"))
    }
    static func prompts() throws -> MTPrompts {
        try MTPrompts.load(from: repoRoot.appendingPathComponent("Resources/prompts/mt.json"))
    }
}
