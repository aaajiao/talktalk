// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

// Video window chrome and quiet dimming (redesign §6 窗口 / 鼠标穿透, §1 长静默变暗). Pure
// timing and mapping; SubtitlePanel applies the results to AppKit. Times are monotonic seconds.

/// The hover-only 28 pt bar of the video window. It fades in over 200 ms while the pointer is
/// over the window and fades out 1.5 s after it leaves. A menu or popover opened from the
/// window holds a bar that is already shown. A locked (mouse-through) window never shows it.
public struct VideoHoverBar: Sendable, Equatable {
    public private(set) var pointerInside = false
    public private(set) var held = false
    public private(set) var locked = false
    /// Captions are off: the window is only its titlebar, which then stays shown (§6).
    public private(set) var pinned = false
    private var leftAt: Double?

    public init() {}

    public static var hideDelay: Double { SubtitleTokens.Motion.videoTitlebarHideDelay.seconds }

    public mutating func pointer(inside: Bool, at now: Double) {
        guard !locked, inside != pointerInside else { return }
        pointerInside = inside
        leftAt = inside ? nil : now
    }

    /// Holding keeps a shown bar; it never brings a hidden one back.
    public mutating func setHeld(_ on: Bool, at now: Double) {
        if on {
            held = isShown(at: now)
        } else if held {
            held = false
            if !pointerInside { leftAt = now }
        }
    }

    /// The window was ordered out or minimised: AppKit sends no mouseExited then, so the
    /// pointer counts as gone at once. Showing the window again re-samples the pointer.
    public mutating func windowHidden() {
        pointerInside = false
        held = false
        leftAt = nil
    }

    public mutating func setPinned(_ on: Bool) { pinned = on }

    /// Mouse-through: the window gets no pointer events, so the bar goes at once.
    public mutating func setLocked(_ on: Bool) {
        locked = on
        pointerInside = false
        held = false
        leftAt = nil
    }

    public func isShown(at now: Double) -> Bool {
        guard !locked else { return false }
        if pointerInside || held || pinned { return true }
        guard let leftAt else { return false }
        return now < leftAt + Self.hideDelay
    }

    /// When the bar starts fading out unless the pointer comes back; nil when nothing waits.
    public func hideDeadline(at now: Double) -> Double? {
        guard !locked, !pointerInside, !held, !pinned, let leftAt, now < leftAt + Self.hideDelay else { return nil }
        return leftAt + Self.hideDelay
    }

    /// 200 ms both ways (the spec gives only the fade-in; the fade-out uses the same value).
    /// Reduce Motion switches at once.
    public static func fadeDuration(reduceMotion: Bool) -> Double {
        SubtitleTokens.Motion.videoTitlebarFadeIn.duration(reduceMotion: reduceMotion)
    }
}

/// The persistent 8 pt dot in the video window's top-right corner: yellow for a warning
/// (including captions more than 5 s behind), red for a risk. Notifications and information
/// do not light it. Clicking it opens the details popover.
public enum VideoStatusDot: Sendable, Equatable {
    case warn, risk

    public static let diameter: Double = 8
    /// Distance of the dot (and the lock indicator) from the window's right edge.
    public static let edgeInset: Double = 10
    /// Room the hover bar's trailing controls leave for the dot.
    public static let reservedTrailingWidth: Double = edgeInset + diameter + 8

    public static func make(issue: IssueSlot?) -> VideoStatusDot? {
        guard let chip = issue?.chip else { return nil }
        switch chip.tone {
        case .risk: return .risk
        case .warn: return .warn
        case .notice, .info: return nil
        }
    }

    public var color: SubtitleTokens.Color { self == .risk ? .riskStroke : .warn }

    /// "字幕落后约 N 秒" (§6 视觉反馈): a warning chip in the hover bar, which turns the dot yellow.
    public static func lagChip(seconds: Int) -> HUDChip {
        HUDChip(titlebarLabel("字幕落后约 \(seconds) 秒"), symbol: "clock", tone: .warn,
                detail: String(localized: "字幕落后声音约 \(seconds) 秒：先加快翻页追赶，追不上时跳过较旧的句子。"))
    }
}

/// "锁定字幕位置（鼠标穿透）" (§6 鼠标穿透). Only the video window can be locked; the state is
/// saved for that scene and only the menu-bar menu unlocks it.
public enum SubtitleClickThrough {
    public static func ignoresMouse(locked: Bool, scene: SubtitleScene) -> Bool { locked && scene == .video }

    /// The menu-bar item appears during a video session; locking from the hover bar's ⋯ menu
    /// uses the same preference.
    public static func offersLock(scene: SubtitleScene, sessionActive: Bool) -> Bool {
        sessionActive && scene == .video
    }

    /// The 10 pt `lock.fill` indicator at 40% white.
    public static let indicatorSize: Double = 10
    public static let indicatorAlpha: Double = 0.4
}

/// Long-silence dimming (§1): 8 s after the last page has been read, with no pending cue and
/// no source update, the captions fade to 35% text and a background of at most 40% over
/// 300 ms. New content restores them at once. The preference is on by default.
public struct VideoQuietDim: Sendable, Equatable {
    public static let delay: Double = 8
    public static let dimmedTextAlpha: Double = 0.35
    public static let dimmedBackgroundAlpha: Double = 0.40

    public var enabled: Bool
    private var quietSince: Double?

    public init(enabled: Bool = true) { self.enabled = enabled }

    /// A new cue, a draft revision or changed source text: restore immediately.
    public mutating func contentArrived() { quietSince = nil }

    /// Each clock tick. `lastPageRead`: the current caption's last page has used up its reading
    /// time. `pending`: cues wait to be shown.
    public mutating func update(lastPageRead: Bool, pending: Bool, at now: Double) {
        if lastPageRead, !pending {
            if quietSince == nil { quietSince = now }
        } else {
            quietSince = nil
        }
    }

    public func isDimmed(at now: Double) -> Bool {
        guard enabled, let quietSince else { return false }
        return now - quietSince >= Self.delay
    }

    public static func textAlpha(dimmed: Bool) -> Double { dimmed ? dimmedTextAlpha : 1 }

    /// The glass or plate alpha. Dimming never raises a background that is already fainter.
    public static func backgroundAlpha(normal: Double, dimmed: Bool) -> Double {
        dimmed ? min(normal, dimmedBackgroundAlpha) : normal
    }

    /// Dimming fades over 300 ms (instant with Reduce Motion); restoring is always instant.
    public static func transition(dimming: Bool, reduceMotion: Bool) -> Double {
        dimming ? SubtitleTokens.Motion.longSilenceDim.duration(reduceMotion: reduceMotion) : 0
    }
}

/// The one-time hint the first time the video window appears on a full-screen Space (§6).
public enum FullScreenSpaceHint {
    /// A window on screen in the current Space, in global display coordinates.
    public struct Window: Sendable, Equatable {
        public var layer: Int
        public var ownerPID: Int32
        public var x: Double, y: Double, width: Double, height: Double

        public init(layer: Int, ownerPID: Int32, x: Double, y: Double, width: Double, height: Double) {
            self.layer = layer; self.ownerPID = ownerPID; self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public static let seconds: Double = 6
    public static var text: String { String(localized: "可拖到画面外，或在菜单中锁定") }

    /// Another app's normal-level window covers the whole display, menu-bar area included. A
    /// zoomed desktop window never covers the menu bar, so this means a full-screen Space.
    public static func isFullScreenSpace(windows: [Window], display: (x: Double, y: Double, width: Double, height: Double),
                                         ownPID: Int32) -> Bool {
        windows.contains { window in
            window.layer == 0 && window.ownerPID != ownPID
                && abs(window.x - display.x) < 1 && abs(window.y - display.y) < 1
                && abs(window.width - display.width) < 1 && abs(window.height - display.height) < 1
        }
    }

    public static func shouldShow(alreadyShown: Bool, scene: SubtitleScene, windowVisible: Bool, locked: Bool,
                                  onFullScreenSpace: Bool) -> Bool {
        !alreadyShown && scene == .video && windowVisible && !locked && onFullScreenSpace
    }
}
