import Darwin
import Foundation

/// The version-1 glossary (§5.4). Snapshots are safe to read from translation/ASR workers.
/// All saved entries are resident in v1, so the editor caps them at the 30-entry injection limit.
public final class GlossaryStore: @unchecked Sendable {
    public static let limit = 30
    public static let changed = Notification.Name("TalkTalk.glossaryChanged")
    public let url: URL
    private let lock = NSLock()
    private var entries: [GlossaryEntry] = []
    public enum Failure: Error { case version, tooManyEntries, missingTerm }
    private struct Document: Codable { var version: Int; var entries: [GlossaryEntry] }

    public init(url: URL) { self.url = url; try? reload() }
    public func snapshot(target: Lang? = nil) -> [GlossaryEntry] {
        lock.withLock { entries.filter { target == nil || !$0.rendering(for: target!).isEmpty } }
    }
    public func reload() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { entries = []; return }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FileSystem.Failure.posix("open glossary", errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fchmod(fd, 0o600) == 0 else { throw FileSystem.Failure.posix("chmod glossary", errno) }
            let document = try JSONDecoder().decode(Document.self, from: handle.readToEnd() ?? Data())
            guard document.version == 1 else { throw Failure.version }
            entries = try Self.normalized(document.entries)
        }
    }
    public func save(_ values: [GlossaryEntry]) throws {
        let clean = try Self.normalized(values)
        try lock.withLock {
            try FileSystem.ensurePrivateDirectory(url.deletingLastPathComponent())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileSystem.writeAtomically(encoder.encode(Document(version: 1, entries: clean)), to: url)
            entries = clean
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    private static func normalized(_ entries: [GlossaryEntry]) throws -> [GlossaryEntry] {
        guard entries.count <= limit else { throw Failure.tooManyEntries }
        return try entries.map { entry in
            func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
            let clean = GlossaryEntry(zh: trim(entry.zh), en: trim(entry.en), de: trim(entry.de), note: entry.note.map(trim))
            guard !clean.zh.isEmpty, !clean.en.isEmpty || !clean.de.isEmpty else { throw Failure.missingTerm }
            return clean
        }
    }
}
