import Foundation

/// Binary frames of the engine wire protocol (§4.4): `[u32 BE length][u8 kind][payload]`, where
/// length counts kind + payload. Mirrors `engine/talktalk_engine/frames.py`.
public enum FrameKind: UInt8, Sendable {
    case jsonHead = 1
    case pcmF32At24k = 2
    case jsonTail = 3
    case jsonError = 4
    case blob = 5
    case pcmS16At16k = 6
    /// `/v1/tts` while the engine guards hold audio back: `{held_s, attempt}`, no samples (§5.7).
    case jsonProgress = 7
}

public struct Frame: Sendable, Equatable {
    public let kind: FrameKind
    public let payload: Data

    public init(_ kind: FrameKind, _ payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

public enum FrameError: Error, Equatable {
    case badLength(UInt32)
    case unknownKind(UInt8)
    case truncated
}

public enum Frames {
    public static let maxFrame: UInt32 = 4 * 1024 * 1024
    public static let contentType = "application/x-talktalk-frames"

    public static func encode(_ kind: FrameKind, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        var len = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }

    public static func encodeJSON(_ kind: FrameKind, _ object: [String: Any]) throws -> Data {
        encode(kind, try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    /// s16 LE PCM for kind 6 (16 kHz), clipped from [-1, 1] floats.
    public static func pcmS16(_ samples: [Float]) -> Data {
        var d = Data(count: samples.count * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, x) in samples.enumerated() {
                p[i] = Int16(max(-32768, min(32767, (x * 32768).rounded()))).littleEndian
            }
        }
        return d
    }

    /// f32 LE PCM for kind 2 (24 kHz).
    public static func pcmF32(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }   // Apple silicon is little-endian
    }

    public static func floats(fromF32 data: Data) -> [Float] {
        let n = data.count / 4
        var out = [Float](repeating: 0, count: n)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0, count: n * 4) }
        return out
    }

    /// Parses a complete body.
    public static func decodeAll(_ data: Data) throws -> [Frame] {
        var d = StreamDecoder()
        let frames = try d.feed(data)
        guard d.pending == 0 else { throw FrameError.truncated }
        return frames
    }

    /// Incremental decoder for chunked responses (`/v1/tts`).
    public struct StreamDecoder: Sendable {
        private var buf = Data()
        public init() {}
        public var pending: Int { buf.count }

        public mutating func feed(_ data: Data) throws -> [Frame] {
            buf.append(data)
            var out: [Frame] = []
            var start = buf.startIndex
            while buf.endIndex - start >= 5 {
                let b0 = UInt32(buf[start]), b1 = UInt32(buf[start + 1]), b2 = UInt32(buf[start + 2]), b3 = UInt32(buf[start + 3])
                let length = b0 << 24 | b1 << 16 | b2 << 8 | b3
                guard length >= 1, length <= Frames.maxFrame else { throw FrameError.badLength(length) }
                guard let kind = FrameKind(rawValue: buf[start + 4]) else { throw FrameError.unknownKind(buf[start + 4]) }
                let end = start + 4 + Int(length)
                guard end <= buf.endIndex else { break }
                out.append(Frame(kind, Data(buf[(start + 5)..<end])))
                start = end
            }
            buf = Data(buf[start...])
            return out
        }
    }
}
