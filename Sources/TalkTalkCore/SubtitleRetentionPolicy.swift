import Foundation

/// A rolling reading window, independent of recognition, translation and audio work.
/// The newest activity advances the window; wall-clock silence never erases its last lines.
public struct SubtitleRetentionPolicy: Sendable, Equatable {
    public static let meeting = SubtitleRetentionPolicy(windowNs: 60_000_000_000,
                                                        maxSegments: 24, maxCharacters: 6_000)
    public let windowNs: HostTime
    public let maxSegments: Int
    public let maxCharacters: Int

    public struct Entry: Sendable {
        public let at: HostTime
        /// Source, translation and provisional text together; pairs are never split.
        public let characters: Int
        public init(at: HostTime, characters: Int) {
            self.at = at; self.characters = max(0, characters)
        }
    }

    public init(windowNs: HostTime, maxSegments: Int, maxCharacters: Int) {
        self.windowNs = windowNs
        self.maxSegments = max(1, maxSegments)
        self.maxCharacters = max(1, maxCharacters)
    }

    /// Entries are in source order. Always retain the newest complete pair, even if that
    /// single pair exceeds the character budget; later arrivals can evict it normally.
    public func retainedStartIndex(in entries: [Entry]) -> Int {
        guard let latest = entries.map(\.at).max() else { return 0 }
        var start = entries.count - 1
        var characters = entries[start].characters
        while start > 0, entries.count - start < maxSegments {
            let previous = entries[start - 1]
            guard latest - previous.at <= windowNs,
                  previous.characters <= maxCharacters - min(characters, maxCharacters) else { break }
            characters += previous.characters
            start -= 1
        }
        return start
    }
}
