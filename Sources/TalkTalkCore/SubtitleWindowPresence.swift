import Foundation

/// Whether the subtitle window may be on screen (redesign §9.1). Only an explicit session start
/// opens it; ending closes it at once, before any layout, so the window leaves in one step.
/// Late status for an ended session (a restore notice, a fading chip) then has no window to
/// bring back, and an idle notice never shows one. While a session runs with subtitles off,
/// status alone still keeps the titlebar-only window.
public struct SubtitleWindowPresence: Sendable, Equatable {
    public private(set) var sessionOpen = false

    public init() {}

    public mutating func begin() { sessionOpen = true }

    /// Returns whether a session was open, so one-time end effects run once.
    @discardableResult
    public mutating func end() -> Bool {
        defer { sessionOpen = false }
        return sessionOpen
    }

    /// Phone's preparation context alone never shows the window: it is first ordered front by
    /// the running session, already at its final size (no bare titlebar strip while preparing).
    public func hasContent(subtitles: Bool, conversation: Bool, status: Bool, sessionActions: Bool) -> Bool {
        sessionOpen && (subtitles || conversation || status || sessionActions)
    }
}
