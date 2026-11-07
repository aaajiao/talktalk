import Foundation

/// Whether the subtitle window may be on screen (redesign §9.2.2). Only an explicit session start
/// opens it; ending closes it at once, before any layout, so the window leaves in one step.
/// Late status for an ended session (a restore notice, a fading chip) then has no window to
/// bring back, and an idle notice never shows one. Meeting/phone status can keep a titlebar-only
/// window. Video waits for actual caption text, so a source-app title never appears by itself.
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
    public func hasContent(subtitles: Bool, conversation: Bool, status: Bool, sessionActions: Bool,
                           scene: SubtitleScene = .meeting, videoSource: String = "", videoTranslation: String = "") -> Bool {
        guard sessionOpen else { return false }
        if scene == .video {
            return subtitles && [videoSource, videoTranslation].contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return subtitles || conversation || status || sessionActions
    }

    /// New content can reveal an automatically withheld window, never one the user closed or
    /// minimized. These intents are reset only by a new session or explicit user restoration.
    public func allowsAutomaticDisplay(contentAvailable: Bool, userHidden: Bool, minimized: Bool) -> Bool {
        sessionOpen && contentAvailable && !userHidden && !minimized
    }
}
