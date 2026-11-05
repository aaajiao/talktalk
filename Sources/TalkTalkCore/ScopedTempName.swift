import Foundation

/// Temp entry names owned by one build: `<tag>+<bundle id>+<unique>`. The Dev and release apps
/// share the per-user $TMPDIR, so a cleanup that matched on the tag alone would delete the other
/// build's live files. "+" never occurs in a bundle id (letters, digits, "-", "."), so
/// `com.aaajiao.talktalk` never matches `com.aaajiao.talktalk.dev`'s entries.
public struct ScopedTempName: Sendable, Equatable {
    public let tag: String
    public let bundleID: String

    public init(tag: String, bundleID: String?) {
        self.tag = tag
        self.bundleID = bundleID ?? "unknown"
    }

    public var prefix: String { "\(tag)+\(bundleID)+" }

    public func make(_ unique: String = UUID().uuidString) -> String { prefix + unique }

    public func owns(_ name: String) -> Bool {
        name.hasPrefix(prefix) && !name.dropFirst(prefix.count).isEmpty
    }
}
