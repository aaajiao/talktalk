import Foundation

/// What is stored under diagnostics/, and the user's explicit "delete all of it".
/// The automatic 24-hour rule stays in `RetentionPolicy`.
public struct DiagnosticsStore: Sendable {
    public struct Inventory: Sendable, Equatable {
        public var recordings: Int
        public var analyses: Int
        public init(recordings: Int = 0, analyses: Int = 0) { self.recordings = recordings; self.analyses = analyses }
        public var total: Int { recordings + analyses }
    }

    public let root: URL
    public init(root: URL) { self.root = root }

    /// Hidden entries are Finder's bookkeeping, not data the user could be asked to delete.
    public func visibleEntryNames() -> Set<String> {
        Set(entryNames().filter { !$0.hasPrefix(".") })
    }

    public func inventory() -> Inventory {
        let names = visibleEntryNames()
        let analyses = names.filter { $0.hasPrefix(SubtitleAnalysisTrace.directoryPrefix) }.count
        return Inventory(recordings: names.count - analyses, analyses: analyses)
    }

    /// Removes every entry and returns the visible ones left, so a failed delete cannot pass as
    /// done. `removeItem` on a link removes the link, never what it points to.
    @discardableResult
    public func removeAll() -> Set<String> {
        for name in entryNames() { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        return visibleEntryNames()
    }

    /// A linked root is refused: its children would be someone else's files.
    private func entryNames() -> [String] {
        guard !FileSystem.isSymlink(root) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }
}
