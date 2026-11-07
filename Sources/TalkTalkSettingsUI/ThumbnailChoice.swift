import SwiftUI
import TalkTalkCore

// A choice that is itself a look (docs/decisions/2026-11-06-settings-visual-system.md §3.12):
// the video caption style and arrangement. Text parameters are already localized.

/// Small pictures of the options in a row, each a button with its caption2 name (≤ 4
/// characters) underneath, so the choice reads without hovering. The thumbnails sit on the
/// backdrop the 字幕 preview uses (white in Light Mode, black in Dark Mode) inside 8 pt corners;
/// callers draw only the content, from SubtitleTokens, never an image file. Selected: a 2 pt
/// accent outline and primary name text; VoiceOver hears each name, `.isSelected` on the chosen
/// one, and the option's help as the hint.
public struct ThumbnailChoice<V: Hashable>: View {
    /// One option: its value, visible name, optional help, and the picture.
    public struct Option {
        let value: V
        let name: String
        let help: String?
        let thumbnail: AnyView

        public init(_ value: V, name: String, help: String? = nil, @ViewBuilder thumbnail: () -> some View) {
            self.value = value
            self.name = name
            self.help = help
            self.thumbnail = AnyView(thumbnail())
        }
    }

    /// The two thumbnail sizes of §3.12.
    public enum Size: Sendable {
        /// 72 × 40: the caption styles.
        case wide
        /// 48 × 32: the caption arrangement.
        case compact

        var width: Double { self == .wide ? 72 : 48 }
        var height: Double { self == .wide ? 40 : 32 }
    }

    private static var radius: Double { 8 }

    private let label: String
    private let options: [Option]
    private let selection: Binding<V>
    private let size: Size
    @Environment(\.colorScheme) private var colorScheme

    /// `label`: the setting's name, for VoiceOver's container ("样式", "排列").
    public init(_ label: String, options: [Option], selection: Binding<V>, size: Size) {
        self.label = label
        self.options = options
        self.selection = selection
        self.size = size
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(options.indices, id: \.self) { index in
                choice(options[index])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }

    private func choice(_ option: Option) -> some View {
        let selected = option.value == selection.wrappedValue
        let shape = RoundedRectangle(cornerRadius: Self.radius)
        return Button {
            selection.wrappedValue = option.value
        } label: {
            VStack(spacing: 4) {
                option.thumbnail
                    .frame(width: size.width, height: size.height)
                    .background(colorScheme == .dark ? Color.black : Color.white)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(selected ? AnyShapeStyle(Color.accentColor)
                                                         : AnyShapeStyle(Color(nsColor: .separatorColor)),
                                                lineWidth: selected ? 2 : 1))
                    .accessibilityHidden(true)
                Text(verbatim: option.name)
                    .font(.caption2)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ifPresent: option.help)
        .accessibilityLabel(Text(verbatim: option.name))
        .accessibilityHint(Text(verbatim: option.help ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
