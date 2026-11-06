// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore

/// One status vocabulary across Settings (settings visual system §3.7; shape first, then
/// colour, then words): passed, needs action, blocks speech (the other party hears the original
/// voice), failed, not yet checked, waiting, in progress and recording. `risk` draws the
/// titlebar's risk glyph (mic with a warning badge; the menu bar and onboarding use it too).
/// There is no neutral "info" state: `info.circle` is ⓘ alone (§3.7, §4).
public enum SettingsStatus: Sendable, Equatable {
    case ok, warn, risk, failed, pending, waiting, busy, recording

    /// The plain SF Symbol of the state. `StatusGlyph` draws the composed risk glyph and a
    /// spinner for `busy` instead; these two fall back to the warning triangle and the clock
    /// where only a symbol name fits.
    public var symbol: String {
        typealias I = SubtitleTokens.SettingsIcon
        return switch self {
        case .ok: I.statusOK
        case .warn, .risk: I.statusWarn
        case .failed: I.statusFailed
        case .pending: I.statusPending
        case .waiting, .busy: I.statusWaiting
        case .recording: I.statusRecording
        }
    }

    /// The glyph's colour.
    public var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .risk, .failed, .recording: .red
        case .pending, .waiting, .busy: .secondary
        }
    }

    /// The colour of a status label's words: warnings in the warn token's ink (dark orange on
    /// light surfaces, as the titlebar), risk and failure red, everything else secondary.
    public var textColor: Color {
        switch self {
        case .warn: Self.warnInk
        case .risk, .failed: .red
        case .ok, .pending, .waiting, .busy, .recording: .secondary
        }
    }

    /// The state's word for VoiceOver when the glyph stands alone.
    public var spokenName: String {
        switch self {
        case .ok: String(localized: "已就绪")
        case .warn: String(localized: "需处理")
        case .risk: String(localized: "对方能听到原声")
        case .failed: String(localized: "失败")
        case .pending: String(localized: "未检查")
        case .waiting: String(localized: "等待中")
        case .busy: String(localized: "进行中")
        case .recording: String(localized: "录音中")
        }
    }

    private static let warnInk = Color(nsColor: NSColor(name: nil) { appearance in
        let light = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let value = SubtitleTokens.Color.warn.rgba(lightSurface: light)
        return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    })
}

/// A status glyph in its colour at one of the two fixed sizes (§3.7, §4): `inline` 13 pt for
/// row ends, problem rows and results; `badge` 11 pt on a 15 pt window-coloured disc for card
/// and node corners. The risk glyph is drawn at a fixed point size, not the system font size.
/// Beside text it sits where an SF Symbol would: the composed risk image and the spinner carry
/// no text baseline of their own, so they get the symbols' one (centred on the cap height).
public struct StatusGlyph: View {
    public enum Size: Sendable { case inline, badge }

    private let status: SettingsStatus
    private let size: Size

    public init(_ status: SettingsStatus, size: Size = .inline) {
        self.status = status
        self.size = size
    }

    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    public var body: some View {
        Group {
            switch size {
            case .inline:
                glyph(Ladder.inline)
            case .badge:
                glyph(Ladder.badge)
                    .frame(width: Ladder.badgeDisc, height: Ladder.badgeDisc)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spokenName)
    }

    @ViewBuilder private func glyph(_ points: Double) -> some View {
        switch status {
        case .busy:
            ProgressView().controlSize(.mini).frame(width: points, height: points)
                .alignmentGuide(.firstTextBaseline, computeValue: Self.symbolBaseline(points))
        case .risk:
            if let image = RiskGlyph.image(points) {
                Image(nsImage: image)
                    .alignmentGuide(.firstTextBaseline, computeValue: Self.symbolBaseline(points))
            } else {
                Image(systemName: status.symbol).font(.system(size: points)).foregroundStyle(status.color)
            }
        default:
            Image(systemName: status.symbol).font(.system(size: points, weight: .regular)).foregroundStyle(status.color)
        }
    }

    /// The text baseline an SF Symbol of this size has: half the font's cap height below the
    /// glyph's centre. Without it a view with no text aligns its bottom edge on the baseline and
    /// stands about 3 pt above the symbols in the same column.
    private static func symbolBaseline(_ points: Double) -> @Sendable (ViewDimensions) -> CGFloat {
        let halfCap = NSFont.systemFont(ofSize: points).capHeight / 2
        return { $0[VerticalAlignment.center] + halfCap }
    }
}

/// The composed risk glyph (`SubtitleStyle.symbol` overlays the badge where the system lacks
/// `mic.badge.exclamationmark`), tinted red, one image per point size.
@MainActor
enum RiskGlyph {
    private static var images: [Double: NSImage] = [:]

    static func image(_ points: Double) -> NSImage? {
        if let image = images[points] { return image }
        guard let base = SubtitleStyle.symbol(SubtitleTokens.VoiceIcon.originalRisk, size: points, weight: .regular)
        else { return nil }
        let image = SubtitleStyle.tinted(base, .systemRed)
        images[points] = image
        return image
    }
}

/// A status in words (§3.7): the 13 pt glyph, 4 pt, then the shortest text in 13 pt; warnings
/// orange, risk and failure red, the rest secondary. The full reason goes in `help`.
public struct StatusLabel: View {
    private let text: String
    private let status: SettingsStatus
    private let help: String?

    public init(_ text: String, _ status: SettingsStatus, help: String? = nil) {
        self.text = text
        self.status = status
        self.help = help
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            StatusGlyph(status).accessibilityHidden(true)
            Text(verbatim: text).font(.body).foregroundStyle(status.textColor)
        }
        .accessibilityElement(children: .combine)
        .help(ifPresent: help)
    }
}

extension View {
    /// `.help` only when there is something to say.
    @ViewBuilder func help(ifPresent text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
