import Darwin
import Foundation

/// READY payload (§4.4): `READY {"port","pid","api","engine","runtime","versions","models","voice"}`.
public struct ReadyInfo: Codable, Sendable, Equatable {
    public struct Model: Codable, Sendable, Equatable {
        public let id: String
        public let rev: String
        public let state: String
    }
    public struct Voice: Codable, Sendable, Equatable {
        public let state: String
    }
    public let port: Int
    public let pid: Int32
    public let api: Int
    public let engine: String
    public let runtime: String
    public let versions: [String: String]
    public let models: [String: Model]
    public let voice: Voice
}

/// `PROGRESS {"step":"tts","done":1,"count":4}` (drives the menu bar progress).
public struct EngineProgress: Codable, Sendable, Equatable {
    public let step: String
    public let done: Int
    public let count: Int
}

public enum HandshakeLine: Sendable, Equatable {
    case progress(EngineProgress)
    case ready(ReadyInfo)
    case fatal(String)
    /// Anything else on the handshake fd: a protocol error (the engine must keep it silent).
    case unexpected(String)
}

public enum ServerHandshake {
    /// The engine's handshake fd carries only these lines; library output goes to stderr (§4.4).
    public static let maxLineBytes = 64 * 1024

    public static func parse(_ line: String) -> HandshakeLine {
        func json<T: Decodable>(_ type: T.Type, _ s: Substring) -> T? {
            try? JSONDecoder().decode(type, from: Data(s.utf8))
        }
        if line.hasPrefix("PROGRESS "), let p = json(EngineProgress.self, line.dropFirst(9)) { return .progress(p) }
        if line.hasPrefix("READY "), let r = json(ReadyInfo.self, line.dropFirst(6)) { return .ready(r) }
        if line.hasPrefix("FATAL ") {
            struct F: Decodable { let message: String }
            return .fatal(json(F.self, line.dropFirst(6))?.message ?? String(line.dropFirst(6).prefix(500)))
        }
        return .unexpected(String(line.prefix(200)))
    }

    /// Reads lines from `fd` on its own thread and delivers them in order. The stream finishes
    /// at READY or FATAL (the engine closes its end there) or at EOF. Closes `fd` when done.
    public static func lines(fd: Int32) -> AsyncStream<HandshakeLine> {
        AsyncStream { cont in
            let t = Thread {
                defer { close(fd) }
                var buf = [UInt8]()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    buf.append(contentsOf: chunk[0..<n])
                    while let nl = buf.firstIndex(of: 0x0A) {
                        let line = String(decoding: buf[..<nl], as: UTF8.self)
                        buf.removeSubrange(...nl)
                        let parsed = parse(line)
                        cont.yield(parsed)
                        switch parsed {
                        case .ready, .fatal:
                            cont.finish()
                            return
                        default: break
                        }
                    }
                    if buf.count > maxLineBytes {
                        cont.yield(.unexpected("handshake line longer than \(maxLineBytes) bytes"))
                        break
                    }
                }
                cont.finish()
            }
            t.name = "engine-handshake"
            t.start()
        }
    }
}
