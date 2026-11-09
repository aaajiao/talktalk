import Foundation
import TalkTalkCore

/// One server-sent event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public init(event: String?, data: String) { self.event = event; self.data = data }
}

/// Incremental `text/event-stream` parser (WHATWG rules that matter here: `event:` / `data:`
/// fields, multi-line data joined with "\n", blank line dispatches, `:` comments, CRLF/LF/CR).
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var event: String?
    private var data: [String] = []
    private var lastWasCR = false

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        var out: [SSEEvent] = []
        for b in bytes { if let e = feed(byte: b) { out.append(e) } }
        return out
    }

    public mutating func feed(byte b: UInt8) -> SSEEvent? {
        if b == 0x0A, lastWasCR { lastWasCR = false; return nil }   // the LF of a CRLF
        lastWasCR = b == 0x0D
        guard b == 0x0A || b == 0x0D else { line.append(b); return nil }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !data.isEmpty || event != nil else { return nil }
            let e = SSEEvent(event: event, data: data.joined(separator: "\n"))
            event = nil; data = []
            return e
        }
        let s = String(decoding: line, as: UTF8.self)
        if s.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let c = s.firstIndex(of: ":") {
            field = s[..<c]
            var v = s[s.index(after: c)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else { field = Substring(s); value = "" }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// At end of stream: a last event without the trailing blank line.
    public mutating func finish() -> SSEEvent? {
        var e: SSEEvent?
        if !line.isEmpty { e = feed(byte: 0x0A) }
        if e == nil, !data.isEmpty { e = SSEEvent(event: event, data: data.joined(separator: "\n")); data = []; event = nil }
        return e
    }
}

/// Folds one Responses stream into what HedgedRequest and validation need (§5.4). Pure.
public struct ResponseAccumulator: Sendable {
    public enum Signal: Sendable, Equatable {
        case delta
        case progress
        /// The first newline arrived (start the afterNewlineGraceMs timer).
        case firstLineComplete
        /// response.completed / .incomplete / .failed, or an `error` event.
        case terminal
    }

    public private(set) var firstLine = FirstLine()
    public private(set) var created: ResponseEcho?
    public private(set) var final: ResponseEcho?
    public private(set) var finalType: String?
    public private(set) var error: OpenAIErrorInfo?
    public private(set) var sawDelta = false
    public private(set) var eventCount = 0

    public init() {}

    public mutating func consume(_ e: SSEEvent) -> [Signal] {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(e.data.utf8))) as? [String: Any] else { return [] }
        eventCount += 1
        let type = (obj["type"] as? String) ?? e.event ?? ""
        switch type {
        case "response.output_text.delta":
            sawDelta = true
            let completed = firstLine.append((obj["delta"] as? String) ?? "")
            return completed ? [.delta, .firstLineComplete] : [.delta]
        case "response.created":
            if let r = obj["response"] as? [String: Any] { created = ResponseEcho(response: r) }
            return [.progress]
        case "response.completed", "response.incomplete", "response.failed":
            finalType = type
            if let r = obj["response"] as? [String: Any] {
                final = ResponseEcho(response: r)
                if let err = r["error"] as? [String: Any] { error = OpenAIErrorInfo.parse(event: ["error": err]) }
            }
            return [.terminal]
        case "error":
            finalType = "error"
            error = OpenAIErrorInfo.parse(event: obj)
            return [.terminal]
        default:
            return [.progress]
        }
    }

    /// The result of a terminal event, per §5.4 (sentEffort = the request's effort).
    public func terminalResult(sentEffort: String, cloud: PolicyProfile.Cloud,
                               sentTier: String? = nil) -> (LegResult, ResponseValidation?) {
        switch finalType {
        case "response.completed", "response.incomplete":
            guard let f = final else { return (.failed(.validationReject("finalMissing")), nil) }
            let v = OpenAIRequestBuilder.validate(f, sentEffort: sentEffort,
                                                  firstLineComplete: firstLine.isComplete || (finalType == "response.completed" && sawDelta),
                                                  expectedServiceTier: sentTier ?? cloud.serviceTier)
            if v.isUsable, firstLine.trimmed.isEmpty { return (.failed(.validationReject("emptyText")), v) }
            return (v.isUsable ? .valid : .failed(.validationReject(v.rejectReason ?? "")), v)
        case "response.failed":
            return (.failed(.responseFailed), nil)
        case "error":
            if let code = error?.code, cloud.pauseOn.errorCode.contains(code) { return (.failed(.pause(code)), nil) }
            if let type = error?.type, cloud.pauseOn.errorType.contains(type) { return (.failed(.pause(type)), nil) }
            if let code = error?.code, cloud.rateLimitOnly.errorCode.contains(code) { return (.failed(.rateLimited(retryAfterS: nil)), nil) }
            return (.failed(.responseFailed), nil)
        default:
            return (.failed(.connectionError), nil)
        }
    }

    /// After the newline grace expired: partial validation on response.created.
    public func partialResult(sentEffort: String, cloud: PolicyProfile.Cloud,
                              sentTier: String? = nil) -> (LegResult, ResponseValidation?) {
        guard let c = created else { return (.failed(.validationReject("createdMissing")), nil) }
        let v = OpenAIRequestBuilder.validatePartial(created: c, sentEffort: sentEffort,
                                                     expectedServiceTier: sentTier ?? cloud.serviceTier)
        if v.isUsable, firstLine.trimmed.isEmpty { return (.failed(.validationReject("emptyText")), v) }
        return (v.isUsable ? .valid : .failed(.validationReject(v.rejectReason ?? "")), v)
    }
}
