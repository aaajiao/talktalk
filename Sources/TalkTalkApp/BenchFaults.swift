#if TALKTALK_DEV
import Foundation
import Synchronization
import TalkTalkCloud
import TalkTalkCore

/// Dev-only fault injection for `--bench cloud` (T4 ⑥ ⑨). Installed as the first protocol class of
/// session A / session B. It claims a request only while a fault is armed for that leg (or in
/// `--dry-run`, where it answers everything locally); every other request goes to the real
/// network through the session's own connection pool, so A/B pool identity is unchanged.
/// The release build has no such hook.
enum FaultInjector {
    enum Target: Sendable, Equatable { case responses, get }

    enum Fault: Sendable, Equatable {
        /// An HTTP error with a JSON error body (code/type only) and optional Retry-After.
        case status(Int, retryAfterS: Int?, code: String?, type: String?)
        /// Accepts the request and never sends response headers (timeouts, "A gives no headers").
        case blackhole
        /// Fails like a dead network.
        case offline
    }

    struct Armed: Sendable { var target: Target; var fault: Fault }

    struct State {
        var armed: [Leg: [Armed]] = [:]
        var simulate = false
        var injected: [Leg: Int] = [:]
    }

    static let state = Mutex(State())

    static func arm(_ leg: Leg, _ fault: Fault, target: Target = .responses, count: Int = 1) {
        state.withLock { $0.armed[leg, default: []] += Array(repeating: Armed(target: target, fault: fault), count: count) }
    }
    static func disarmAll() { state.withLock { $0.armed = [:] } }
    static func setSimulate(_ on: Bool) { state.withLock { $0.simulate = on } }
    static func injectedCount(_ leg: Leg) -> Int { state.withLock { $0.injected[leg] ?? 0 } }

    static func target(of r: URLRequest) -> Target { r.httpMethod == "POST" ? .responses : .get }

    static func claims(_ leg: Leg, _ r: URLRequest) -> Bool {
        state.withLock { s in s.simulate || (s.armed[leg]?.first?.target == target(of: r)) }
    }

    /// Pops the fault for this request; nil = simulate (dry run).
    static func take(_ leg: Leg, _ r: URLRequest) -> Fault? {
        state.withLock { s in
            if var q = s.armed[leg], let first = q.first, first.target == target(of: r) {
                q.removeFirst(); s.armed[leg] = q
                s.injected[leg, default: 0] += 1
                return first.fault
            }
            return nil
        }
    }
}

class FaultProtocol: URLProtocol, @unchecked Sendable {
    class var leg: Leg { .A }
    private let lock = NSLock()
    private var stopped = false
    private let queue = DispatchQueue(label: "talktalk.bench.fault")

    override class func canInit(with request: URLRequest) -> Bool { FaultInjector.claims(leg, request) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let fault = FaultInjector.take(Self.leg, request)
        let isPost = request.httpMethod == "POST"
        let path = url.path
        func send(_ status: Int, _ headers: [String: String], chunks: [(Int, String)]) {
            let start = DispatchTime.now()
            queue.asyncAfter(deadline: start + .milliseconds(chunks.first?.0 ?? 0)) { [self] in
                guard live, let client else { return }
                client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                                   cacheStoragePolicy: .notAllowed)
            }
            for (t, c) in chunks {
                queue.asyncAfter(deadline: start + .milliseconds(t)) { [self] in
                    guard live, let client else { return }
                    client.urlProtocol(self, didLoad: Data(c.utf8))
                }
            }
            queue.asyncAfter(deadline: start + .milliseconds((chunks.last?.0 ?? 0) + 1)) { [self] in
                guard live, let client else { return }
                client.urlProtocolDidFinishLoading(self)
            }
        }
        switch fault {
        case .status(let code, let ra, let ecode, let etype):
            var h = ["Content-Type": "application/json", "x-request-id": "req_injected"]
            if let ra { h["Retry-After"] = String(ra) }
            let body = try! JSONSerialization.data(withJSONObject: ["error": ["code": ecode as Any, "type": etype as Any,
                                                                              "message": "injected"]])
            send(code, h, chunks: [(5, String(decoding: body, as: UTF8.self))])
        case .blackhole:
            break   // nothing until stopLoading
        case .offline:
            queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [self] in
                guard live, let client else { return }
                client.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            }
        case nil:
            // --dry-run: a plausible local OpenAI.
            if isPost {
                let first = Int.random(in: 250...1500)
                send(200, ["Content-Type": "text/event-stream", "x-request-id": "req_sim", "openai-processing-ms": String(first - 40)],
                     chunks: [(Int.random(in: 40...120), Simulated.created),
                              (first, Simulated.delta("Simulated ")),
                              (first + 40, Simulated.delta("translation.")),
                              (first + 80, Simulated.completed)])
            } else if path.hasPrefix("/v1/responses/") {
                send(404, ["Content-Type": "application/json"], chunks: [(30, #"{"error":{"code":null,"type":"invalid_request_error","message":"x"}}"#)])
            } else if path == "/v1/models" {
                send(200, ["Content-Type": "application/json"], chunks: [(60, Simulated.modelList)])
            } else {
                send(200, ["Content-Type": "application/json"], chunks: [(Int.random(in: 30...90), #"{"id":"gpt-6-luna","object":"model","created":1}"#)])
            }
        }
    }

    private var live: Bool { lock.withLock { !stopped } }

    override func stopLoading() { lock.withLock { stopped = true } }
}

final class FaultA: FaultProtocol, @unchecked Sendable { override class var leg: Leg { .A } }
final class FaultB: FaultProtocol, @unchecked Sendable { override class var leg: Leg { .B } }

enum Simulated {
    static func event(_ type: String, _ json: String) -> String { "event: \(type)\ndata: \(json)\n\n" }
    static let echo = #""id":"resp_sim","reasoning":{"effort":"none"},"service_tier":"default","store":false"#
    static let created = event("response.created", #"{"type":"response.created","response":{"status":"in_progress",\#(echo)}}"#)
    static func delta(_ t: String) -> String {
        event("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"\#(t)"}"#)
    }
    static let completed = event("response.completed", #"{"type":"response.completed","response":{"status":"completed",\#(echo),"usage":{"input_tokens":420,"input_tokens_details":{"cached_tokens":256},"output_tokens":9,"output_tokens_details":{"reasoning_tokens":0}}}}"#)
    static let modelList = #"{"object":"list","data":[{"id":"gpt-6-luna","object":"model","created":1790000000,"owned_by":"system"},{"id":"gpt-6-terra","object":"model","created":1790000001,"owned_by":"system"},{"id":"gpt-5.5","object":"model","created":1700000000,"owned_by":"system"}]}"#
}
#endif
