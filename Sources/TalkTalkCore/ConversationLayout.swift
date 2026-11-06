/// Geometry rules of the meeting/phone conversation window (redesign §4): one pair-row
/// timeline above the microphone status dock. Pure values; the app lays out its views from
/// them. The window frame never depends on any of this: only the split inside it changes.
public struct ConversationLayout: Sendable, Equatable {
    /// Below this content width, a pair stacks (translation on top) and the column header hides.
    public static let stackedBelowWidth: Double = 520
    /// Below this content height, the dock shrinks to one 28 pt line.
    public static let compactDockBelowHeight: Double = 260
    /// Below this content height, only the timeline's last row stays visible.
    public static let lastRowOnlyBelowHeight: Double = 140
    public static let compactDockHeight: Double = 28
    /// Speaking expansion: min(34% of the content height, 160 pt).
    public static let speakingHeightFraction: Double = 0.34
    public static let speakingMaxHeight: Double = 160
    /// "↓ N 条新字幕" floats this far above the dock.
    public static let jumpPillGap: Double = 8
    /// Gap between the translation and the source when a pair is stacked.
    public static let stackedGap: Double = 4

    public let contentWidth: Double
    public let contentHeight: Double

    public init(contentWidth: Double, contentHeight: Double) {
        self.contentWidth = contentWidth.isFinite ? max(0, contentWidth) : 0
        self.contentHeight = contentHeight.isFinite ? max(0, contentHeight) : 0
    }

    public var stacked: Bool { contentWidth < Self.stackedBelowWidth }
    public var compactDock: Bool { contentHeight < Self.compactDockBelowHeight }
    public var lastRowOnly: Bool { contentHeight < Self.lastRowOnlyBelowHeight }
    /// The column header appears once per window, only with side-by-side columns.
    public var showsColumnHeader: Bool { !stacked && !lastRowOnly }
    public var headerHeight: Double { showsColumnHeader ? SubtitleTokens.Size.columnHeaderHeight : 0 }
    public var idleDockHeight: Double { compactDock ? Self.compactDockHeight : SubtitleTokens.Size.statusBandIdleHeight }
    /// In the last-row-only window the live turn becomes that last row instead of expanding.
    public var dockExpands: Bool { !lastRowOnly }

    public func dockHeight(speaking: Bool) -> Double {
        guard speaking, dockExpands else { return idleDockHeight }
        return max(idleDockHeight, min(contentHeight * Self.speakingHeightFraction, Self.speakingMaxHeight))
    }

    public func timelineHeight(dockHeight: Double) -> Double {
        max(0, contentHeight - headerHeight - dockHeight)
    }

    /// Smallest content height that still shows the 28 pt dock and one two-line pair.
    public static func minimumContentHeight(translationSize: Double) -> Double {
        let size = translationSize.isFinite && translationSize > 0 ? translationSize : ConversationTypography.defaultBase
        return compactDockHeight + SubtitleTokens.Size.pairTopPadding + SubtitleTokens.Size.pairBottomPadding
            + (2 * size * 1.34).rounded(.up)
    }

    /// Column frames inside one row of `rowWidth` (speaker track included).
    public struct Columns: Sendable, Equatable {
        public var stacked: Bool
        public var sourceX: Double
        public var sourceWidth: Double
        public var translationX: Double
        public var translationWidth: Double
    }

    /// Track 24 + source 40% + gap 16 + translation 60%; stacked rows use the full width.
    public static func columns(rowWidth: Double, stacked: Bool) -> Columns {
        let track = SubtitleTokens.Size.speakerTrackWidth
        let width = rowWidth.isFinite ? max(0, rowWidth) : 0
        if stacked {
            let full = max(0, width - track)
            return Columns(stacked: true, sourceX: track, sourceWidth: full, translationX: track, translationWidth: full)
        }
        let available = max(0, width - track - SubtitleTokens.Size.columnGap)
        let source = (available * SubtitleTokens.Size.sourceColumnFraction).rounded(.down)
        return Columns(stacked: false, sourceX: track, sourceWidth: source,
                       translationX: track + source + SubtitleTokens.Size.columnGap,
                       translationWidth: available - source)
    }

    /// Long-source rule: a source taller than twice its translation shows the translation's
    /// height plus one source line, ending in "…展开". nil when the whole source shows.
    public static func truncatedSourceHeight(source: Double, translation: Double, sourceLine: Double) -> Double? {
        guard translation > 0, sourceLine > 0, source > 2 * translation else { return nil }
        let limit = translation + sourceLine
        return limit < source ? limit : nil
    }

    /// Row height: the taller column, top aligned, plus the pair padding.
    public static func rowHeight(source: Double, translation: Double, stacked: Bool) -> Double {
        let body = stacked
            ? translation + (source > 0 && translation > 0 ? stackedGap : 0) + source
            : max(source, translation)
        return SubtitleTokens.Size.pairTopPadding + body + SubtitleTokens.Size.pairBottomPadding
    }
}
