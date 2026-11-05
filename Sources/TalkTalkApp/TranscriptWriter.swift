import Foundation
import TalkTalkCore

/// Optional text records only. The caller checks the user's switch for each entry; a writer
/// creates nothing until append. Files are private, excluded from backup, and swept at 30 days.
final class TranscriptWriter: @unchecked Sendable {
    private struct Entry: Codable, Sendable {
        let direction, source, target: String
        let at: HostTime
    }
    private let queue = DispatchQueue(label: "com.aaajiao.talktalk.transcript", qos: .utility)
    private let directory: URL
    private let name = UUID().uuidString.lowercased() + ".jsonl"
    private var handle: FileHandle?
    private var stopped = false

    init(directory: URL) { self.directory = directory }
    func append(direction: String, source: String, target: String, at: HostTime) {
        let entry = Entry(direction: direction, source: source, target: target, at: at)
        queue.async { [self] in
            guard !stopped else { return }
            do {
                if handle == nil {
                    try FileSystem.ensurePrivateDirectory(directory)
                    handle = try FileSystem.openForAppending(directory.appendingPathComponent(name))
                }
                let data = try JSONEncoder().encode(entry)
                try handle?.write(contentsOf: data + Data([10]))
            } catch {
                // No source text, pathname or provider message in the event log.
                try? handle?.close(); handle = nil; stopped = true
            }
        }
    }
    func finish() {
        queue.async { [self] in stopped = true; try? handle?.close(); handle = nil }
    }
    deinit { try? handle?.close() }
}
