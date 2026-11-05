import Foundation

/// Bench record writer (one JSON object per line, file mode 0600). Records carry numbers, codes
/// and counts only, never recognized or translated text.
public final class JSONLWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    public let url: URL?
    private let t0 = Date()

    public init(path: String?) {
        guard let path else { url = nil; handle = nil; return }
        let u = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: u.path, contents: nil, attributes: [.posixPermissions: 0o600])
        url = u
        handle = try? FileHandle(forWritingTo: u)
    }

    public func write(_ type: String, _ fields: [String: Any]) {
        var o = fields
        o["type"] = type
        o["t_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        lock.withLock { if let handle { handle.write(d); handle.write(Data("\n".utf8)) } }
    }

    public func close() { lock.withLock { try? handle?.close() } }
}

/// Percentiles (nearest rank) as a JSON object.
public func benchDist(_ xs: [Int]) -> [String: Any] {
    guard !xs.isEmpty else { return ["n": 0] }
    let s = xs.sorted()
    func p(_ q: Double) -> Int { s[min(s.count - 1, max(0, Int((q * Double(s.count)).rounded(.up)) - 1))] }
    return ["n": s.count, "p50": p(0.5), "p90": p(0.9), "p95": p(0.95), "p99": p(0.99), "min": s.first!, "max": s.last!]
}

/// `say` → 16 kHz mono Int16 WAV in a private temp dir (bench audio, §12.1: synthesized speech).
public enum SaySynth {
    public static func render(_ text: String, voice: String, to url: URL, timeoutS: Double = 20) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        // `say` occasionally hangs (seen with a Premium voice): give up after `timeoutS` and skip the clip.
        let deadline = Date().addingTimeInterval(timeoutS)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); throw NSError(domain: "say", code: -1, userInfo: [NSLocalizedDescriptionKey: "say timed out"]) }
        guard p.terminationStatus == 0 else { throw NSError(domain: "say", code: Int(p.terminationStatus)) }
    }
}
