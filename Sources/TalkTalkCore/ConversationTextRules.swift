/// Draft / live / final presentation rules shared by the remote rows and my rows
/// (redesign §4 三态). Pure values; the app builds attributed text from them.
public enum ConversationTextRules {
    public static let draftEllipsis = "…"
    /// The open draft translation's bar at the column's leading edge.
    public static let draftBarWidth: Double = 2
    public static let draftBarAlpha: Double = 0.5
    /// Static caret after live recognized source: 2 pt wide, 0.7 × F tall. It never blinks.
    public static let caretWidth: Double = 2
    public static let caretHeightFactor: Double = 0.7
    /// "未发送" badge: warn 15% fill, warn text, at the source size.
    public static let unsentBadgeFillAlpha: Double = 0.15
    public static let unsentSymbol = "exclamationmark.bubble"

    /// Drafts end with "…" (once); finals never do.
    public static func draftDisplay(_ text: String) -> String {
        let trimmed = text.trimmingTrailingWhitespace
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasSuffix(draftEllipsis) || trimmed.hasSuffix("...") { return trimmed }
        return trimmed + draftEllipsis
    }

    /// Caret height for the remote translation size F.
    public static func caretHeight(translationSize: Double) -> Double {
        caretHeightFactor * (translationSize.isFinite && translationSize > 0 ? translationSize : ConversationTypography.defaultBase)
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        var value = self
        while let last = value.last, last.isWhitespace { value.removeLast() }
        return value
    }
}
