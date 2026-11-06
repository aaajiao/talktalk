// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore

// The settings window's flow diagrams (docs/decisions/2026-11-06-settings-visual-system.md
// §3.3–§3.5): where sound and text go, drawn as lanes of nodes on a SwiftUI `Grid` with fixed
// node heights and equal node columns. No overlay paths, no geometry read back, no fixed-size
// wrappers (8c87ba7) except the LoopRow capsule, a leaf at its own width (see `loopRow`). The
// scene factories that read session state live in the app. Text
// parameters are already localized.

private typealias Ladder = SubtitleTokens.SettingsIcon.Size
private typealias Icon = SubtitleTokens.SettingsIcon

/// How a node looks (§3.3 NodeState): shape and words as well as colour.
public enum NodeState: Sendable, Equatable {
    case ready
    /// In use now (the original voice reaches the other party): the icon takes the voice colour.
    case live
    /// Asks for something: a 1 pt orange outline at 60 %; give the node a badge too.
    case needsAction
    /// The other party can hear the original voice: a red outline, the risk badge and a red
    /// line under the title.
    case risk
    /// Switched off (字幕已隐藏): 40 % opacity and a dashed outline.
    case off
    /// Not available yet (a later step): 50 % opacity.
    case dimmed
}

/// A StepTrack step (§3.5).
public enum StepState: Sendable, Equatable {
    case todo, busy, done
}

/// A node's one graphic (§3.3): an 18 pt symbol, an app's real icon, or a step circle.
public enum FlowGlyph: Sendable, Equatable {
    case symbol(String)
    /// The app's own icon at 18 pt; `fallback` while the app is unknown or not installed.
    case app(bundleID: String?, fallback: String)
    /// The numbered circle, a spinner while in progress, the green check when done.
    case step(Int, StepState)
}

/// Where a node leads (§3.3, §6.3, §6.4): another page (with ReturnPill) or a section of this
/// page. `destination` ("模型 · 语音识别") is the VoiceOver hint and the default tooltip.
public struct NodeLink {
    let destination: String
    let action: () -> Void

    public init(_ destination: String, action: @escaping () -> Void) {
        self.destination = destination
        self.action = action
    }
}

/// The node's 20 pt accessory slot: NodeChips, a mini switch, a keycap, a capsule, a caption or
/// icon buttons. A node with controls is no button itself: only its chevron links (§0.2 #3).
public struct NodeAccessory {
    let content: AnyView
    let interactive: Bool

    /// Controls (chips, switches, buttons): the node keeps only the chevron as its link.
    public static func controls<Content: View>(@ViewBuilder _ content: () -> Content) -> NodeAccessory {
        NodeAccessory(content: AnyView(content()), interactive: true)
    }

    /// Something to read (a keycap, a value): the whole node can still be the link.
    public static func display<Content: View>(@ViewBuilder _ content: () -> Content) -> NodeAccessory {
        NodeAccessory(content: AnyView(content()), interactive: false)
    }
}

/// A 22 pt capsule under a node, joined by a dotted line (§3.3 FlowSatellite): dashed for a
/// fallback path (系统声音), solid for what is in effect or a link.
public struct FlowSatellite {
    let symbol: String
    let text: String
    let help: String
    let dashed: Bool
    let link: NodeLink?

    public init(_ text: String, symbol: String, help: String, dashed: Bool = false, link: NodeLink? = nil) {
        self.text = text
        self.symbol = symbol
        self.help = help
        self.dashed = dashed
        self.link = link
    }

    /// The dotted line and the capsule.
    static let height: Double = 32
}

/// One node of a flow diagram (§3.3 FlowNodeModel).
public struct FlowNode {
    let glyph: FlowGlyph
    let title: String
    let state: NodeState
    let badge: SettingsStatus?
    /// The badge's short cause ("Zoom 正在用 TalkTalk Mic"): tooltip and VoiceOver value.
    let badgeReason: String?
    /// The red line under the title in the risk state ("对方能听到原声").
    let riskText: String?
    let link: NodeLink?
    let accessory: NodeAccessory?
    let satellite: FlowSatellite?
    let help: String?

    public init(_ title: String, glyph: FlowGlyph, state: NodeState = .ready, badge: SettingsStatus? = nil,
                badgeReason: String? = nil, riskText: String? = nil, link: NodeLink? = nil,
                accessory: NodeAccessory? = nil, satellite: FlowSatellite? = nil, help: String? = nil) {
        self.title = title
        self.glyph = glyph
        self.state = state
        // The risk state always carries the risk badge; `ok` badges are kept (a passed check).
        self.badge = state == .risk ? .risk : badge
        self.badgeReason = badgeReason
        self.riskText = state == .risk ? (riskText ?? SettingsStatus.risk.spokenName) : nil
        self.link = link
        self.accessory = accessory
        self.satellite = satellite
        self.help = help
    }

    /// The node's own button (no controls in it) or a chevron link beside its controls.
    var isCardButton: Bool { link != nil && accessory?.interactive != true }

    /// "第 2 步，拨号／接听" for steps, else the title.
    var accessibilityLabel: String {
        if case let .step(number, _) = glyph { return String(localized: "第 \(number) 步，\(title)") }
        return title
    }

    /// The state in words (§3.3): the step's progress, the risk, off or in use, and the badge's
    /// cause; "已就绪" when nothing else applies.
    var accessibilityValue: String {
        var parts: [String] = []
        if case let .step(_, step) = glyph {
            switch step {
            case .todo: parts.append(String(localized: "未完成"))
            case .busy: parts.append(String(localized: "进行中"))
            case .done: parts.append(String(localized: "已完成"))
            }
        }
        switch state {
        case .risk: parts.append(riskText ?? SettingsStatus.risk.spokenName)
        case .off: parts.append(String(localized: "已关闭"))
        case .live: parts.append(String(localized: "使用中"))
        case .dimmed: parts.append(String(localized: "暂不可用"))
        case .ready, .needsAction: break
        }
        if let badge, state != .risk { parts.append(badgeReason ?? badge.spokenName) }
        if parts.isEmpty { parts.append(SettingsStatus.ok.spokenName) }
        return parts.joined(separator: String(localized: "，"))
    }

    /// The tooltip: the badge's cause and the node's own help, else where it leads.
    var tooltip: String? {
        let parts = [badgeReason, help].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return link?.destination
    }
}

/// One column of a lane.
public enum FlowCell {
    case node(FlowNode)
    /// A short lane passes this column: a 1 pt line through it.
    case pass
    /// Nothing in this column; the columns stay aligned with the other diagrams.
    case empty
}

/// The lane's gutter (§3.3 LaneLabel): the voice capsule (原声 / 译音, with a caption under it
/// such as "默认") or a 15 pt symbol (`ear`: listening to the other party).
public enum LaneLabel {
    case voice(VoiceState, caption: String? = nil)
    case symbol(String)
}

/// One lane: a gutter and up to four node columns, left to right. `label` names the lane for
/// VoiceOver ("听对方", "我说话 · 原声"). `arrows` replaces the arrow after a column.
public struct FlowLane {
    let label: String
    let gutter: LaneLabel?
    let cells: [FlowCell]
    let arrows: [Int: String]

    public init(_ label: String, gutter: LaneLabel? = nil, cells: [FlowCell], arrows: [Int: String] = [:]) {
        self.label = label
        self.gutter = gutter
        self.cells = Array(cells.prefix(FlowGrid.columns))
        self.arrows = arrows
    }

    func cell(_ index: Int) -> FlowCell { index < cells.count ? cells[index] : .empty }

    func hasArrow(after index: Int) -> Bool {
        if case .empty = cell(index) { return false }
        if case .empty = cell(index + 1) { return false }
        return true
    }
}

/// The loop between the original and the translated lane (§3.3 LoopRow): 22 pt, from node
/// column 2 on: `arrow.uturn.backward`, the 右⌥ keycap, `stop.fill` and "播完回到原声".
public struct LoopRow {
    let after: Int
    let key: TitlebarKey
    let text: String
    let spoken: String

    /// `after`: the lane it follows. `spoken`: the whole loop for VoiceOver and the tooltip.
    public init(after: Int = 1, key: TitlebarKey, text: String, spoken: String) {
        self.after = after
        self.key = key
        self.text = text
        self.spoken = spoken
    }
}

/// A flow diagram (§3.3): a `Grid` with a 64 pt gutter column, four equal node columns and
/// 16 pt arrow columns between them; lanes 10 pt apart. Every node of a diagram has one fixed
/// height: 60, or 82 once any node has an accessory. A node meaning the same thing sits in the
/// same column in every diagram. VoiceOver gets one container named `label`; each lane begins
/// with its gutter, announced as a heading.
public struct FlowGrid: View {
    nonisolated public static let columns = 4
    static let gutterWidth: Double = 64
    static let arrowWidth: Double = 16
    static let compactHeight: Double = 60
    static let accessoryHeight: Double = 82

    private enum Row {
        case lane(FlowLane)
        case loop(LoopRow)
    }

    private let label: String
    private let rows: [Row]
    private let showsGutter: Bool
    private let nodeHeight: Double

    public init(_ label: String, lanes: [FlowLane], loop: LoopRow? = nil) {
        self.label = label
        var rows: [Row] = []
        for (index, lane) in lanes.enumerated() {
            rows.append(.lane(lane))
            if let loop, loop.after == index { rows.append(.loop(loop)) }
        }
        self.rows = rows
        showsGutter = lanes.contains { $0.gutter != nil }
        let hasAccessory = lanes.contains { lane in
            lane.cells.contains { if case let .node(node) = $0 { node.accessory != nil } else { false } }
        }
        nodeHeight = hasAccessory ? Self.accessoryHeight : Self.compactHeight
    }

    public var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                switch rows[index] {
                case let .lane(lane): laneRow(lane)
                case let .loop(loop): loopRow(loop)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }

    private func laneRow(_ lane: FlowLane) -> some View {
        GridRow(alignment: .top) {
            if showsGutter { FlowGutter(lane: lane, height: nodeHeight) }
            cell(lane, 0)
            arrow(lane, 0)
            cell(lane, 1)
            arrow(lane, 1)
            cell(lane, 2)
            arrow(lane, 2)
            cell(lane, 3)
        }
    }

    @ViewBuilder private func cell(_ lane: FlowLane, _ index: Int) -> some View {
        switch lane.cell(index) {
        case let .node(node):
            FlowNodeView(node: node, height: nodeHeight)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        case .pass:
            Rectangle().fill(.tertiary).frame(height: 1)
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: nodeHeight)
                .accessibilityHidden(true)
        case .empty:
            Color.clear
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: nodeHeight)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func arrow(_ lane: FlowLane, _ index: Int) -> some View {
        if lane.hasArrow(after: index) {
            Image(systemName: lane.arrows[index] ?? Icon.flowArrow)
                .font(.system(size: Ladder.badge, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: Self.arrowWidth, height: nodeHeight)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: Self.arrowWidth, height: nodeHeight).accessibilityHidden(true)
        }
    }

    /// The loop sits in node column 2 and draws on across columns 3–4. It does not span them
    /// with `gridCellColumns`: a spanning cell stops `Grid` from sharing the width equally among
    /// the flexible node columns (they fall back to their ideal widths), which the 820 pt
    /// minimum width cannot afford. `gridCellUnsizedAxes(.horizontal)` on the span does not
    /// help either (measured offscreen at 630 pt); spec §3.3 records the exception.
    private func loopRow(_ loop: LoopRow) -> some View {
        GridRow {
            if showsGutter { Color.clear.frame(width: Self.gutterWidth, height: 22) }
            Color.clear.frame(minWidth: 0, maxWidth: .infinity).frame(height: 22)
            Color.clear.frame(width: Self.arrowWidth, height: 22)
            FlowLoop(loop: loop)
        }
    }
}

/// The gutter cell: the lane's capsule or symbol, centred in 64 pt at node height.
private struct FlowGutter: View {
    let lane: FlowLane
    let height: Double

    var body: some View {
        VStack(spacing: 3) {
            switch lane.gutter {
            case let .voice(voice, caption)?:
                VoiceCapsule(state: voice)
                if let caption {
                    Text(verbatim: caption).font(.caption2).foregroundStyle(.secondary)
                }
            case let .symbol(symbol)?:
                Image(systemName: symbol)
                    .font(.system(size: Ladder.row, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
        .frame(width: FlowGrid.gutterWidth, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: lane.label))
        .accessibilityAddTraits(.isHeader)
    }
}

/// The loop row's dashed capsule at its own width, left aligned in column 2 and overflowing to
/// the right over the loop row's empty columns.
private struct FlowLoop: View {
    let loop: LoopRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Icon.loopBack).font(.system(size: Ladder.badge, weight: .semibold))
            Keycap(key: loop.key)
            Image(systemName: Icon.stop).font(.system(size: Ladder.badge, weight: .regular))
            Text(verbatim: loop.text).font(.system(size: Ladder.badge)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: loop.spoken))
        .help(loop.spoken)
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// A node (§3.3): radius 10, quaternary fill, 8 pt padding; the 18 pt glyph in a 24 × 22 box
/// with its badge at the top right, a one-line 12 pt title that may shrink to 85 % but never
/// wraps, an optional red risk line, and the 20 pt accessory slot at the bottom. A node without
/// controls is one plain button (pressed: tertiary fill); a node with controls links only
/// through its 24 × 24 chevron at the bottom right. The chevron always shows.
struct FlowNodeView: View {
    let node: FlowNode
    let height: Double

    var body: some View {
        VStack(spacing: 0) {
            if let link = node.link, node.isCardButton {
                Button(action: link.action) { content(chevron: true) }
                    .buttonStyle(FlowNodeButtonStyle(state: node.state))
                    .accessibilityLabel(Text(verbatim: node.accessibilityLabel))
                    .accessibilityValue(Text(verbatim: node.accessibilityValue))
                    .accessibilityHint(Text(verbatim: link.destination))
                    .help(ifPresent: node.tooltip)
            } else {
                content(chevron: false)
                    .modifier(FlowNodeChrome(state: node.state, pressed: false))
                    .overlay(alignment: .bottomTrailing) { chevronLink }
                    .accessibilityElement(children: .contain)
                    .help(ifPresent: node.tooltip)
            }
            if let satellite = node.satellite {
                FlowSatelliteView(satellite: satellite)
            }
        }
    }

    /// The card's contents at the diagram's fixed height. `chevron`: the decorative chevron of a
    /// whole-card link.
    private func content(chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            Spacer(minLength: 0)
            if let accessory = node.accessory {
                accessory.content
                    .frame(height: Ladder.chipHeight)
                    .padding(.trailing, node.link != nil && accessory.interactive ? 18 : 0)
            }
        }
        .padding(8)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if chevron { FlowChevron().accessibilityHidden(true) }
        }
        .contentShape(RoundedRectangle(cornerRadius: SubtitleTokens.Radius.settingsCard))
    }

    /// Glyph, title and risk line: one VoiceOver element unless the whole node is the button.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            FlowNodeGlyph(glyph: node.glyph, live: node.state == .live)
                .overlay(alignment: .topTrailing) {
                    if let badge = node.badge {
                        StatusGlyph(badge, size: .badge).offset(x: 9, y: -6).accessibilityHidden(true)
                    }
                }
            Text(verbatim: node.title)
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let risk = node.riskText {
                Text(verbatim: risk)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: node.accessibilityLabel))
        .accessibilityValue(Text(verbatim: node.accessibilityValue))
    }

    /// The link beside a node's controls: 24 × 24, always visible.
    @ViewBuilder private var chevronLink: some View {
        if let link = node.link, !node.isCardButton {
            Button(action: link.action) { FlowChevron() }
                .buttonStyle(.plain)
                .help(link.destination)
                .accessibilityLabel(Text(verbatim: String(localized: "打开\(node.title)")))
                .accessibilityHint(Text(verbatim: link.destination))
        }
    }
}

/// `chevron.right` 9 pt semibold tertiary in a 24 × 24 box, 2 pt inside the bottom-right corner.
private struct FlowChevron: View {
    var body: some View {
        Image(systemName: Icon.link)
            .font(.system(size: Ladder.micro, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .padding(2)
    }
}

/// The node's one graphic, 18 pt in its 24 × 22 box.
private struct FlowNodeGlyph: View {
    let glyph: FlowGlyph
    let live: Bool

    private static let liveColor = Color(nsColor: SubtitleStyle.color(.voiceOriginal))

    var body: some View {
        Group {
            switch glyph {
            case let .symbol(name):
                symbol(name)
            case let .app(bundleID, fallback):
                if let bundleID, let icon = AppIcon.image(bundleID) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .frame(width: Ladder.node, height: Ladder.node)
                } else {
                    symbol(fallback)
                }
            case let .step(number, step):
                switch step {
                case .todo:
                    Image(systemName: "\(number).circle")
                        .font(.system(size: Ladder.node, weight: .regular))
                        .foregroundStyle(.secondary)
                case .busy:
                    ProgressView().controlSize(.small).frame(width: Ladder.node, height: Ladder.node)
                case .done:
                    Image(systemName: Icon.statusOK)
                        .font(.system(size: Ladder.node, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                }
            }
        }
        .frame(width: 24, height: 22)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: Ladder.node, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(live ? AnyShapeStyle(Self.liveColor) : AnyShapeStyle(.secondary))
    }
}

/// Fill, outline and opacity of a node in its state.
private struct FlowNodeChrome: ViewModifier {
    let state: NodeState
    let pressed: Bool

    private static let radius = SubtitleTokens.Radius.settingsCard

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Self.radius)
                .fill(pressed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary)))
            .overlay { outline }
            .opacity(state == .off ? 0.4 : state == .dimmed ? 0.5 : 1)
    }

    @ViewBuilder private var outline: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius)
        switch state {
        case .needsAction:
            shape.strokeBorder(Color.orange.opacity(0.6), lineWidth: 1).allowsHitTesting(false)
        case .risk:
            shape.strokeBorder(Color.red, lineWidth: 1).allowsHitTesting(false)
        case .off:
            shape.strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .allowsHitTesting(false)
        case .ready, .live, .dimmed:
            EmptyView()
        }
    }
}

/// A whole-card node link: plain, with the tertiary fill while pressed.
private struct FlowNodeButtonStyle: ButtonStyle {
    let state: NodeState

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(FlowNodeChrome(state: state, pressed: configuration.isPressed))
    }
}

/// The satellite under a node: a 10 pt dotted line and a 22 pt capsule with an 11 pt glyph and
/// text, dashed for a fallback path; a link gets a 9 pt chevron.
private struct FlowSatelliteView: View {
    let satellite: FlowSatellite

    var body: some View {
        VStack(spacing: 0) {
            Path { path in
                path.move(to: CGPoint(x: 0.5, y: 0))
                path.addLine(to: CGPoint(x: 0.5, y: 10))
            }
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
            .foregroundStyle(.tertiary)
            .frame(width: 1, height: 10)
            .accessibilityHidden(true)
            if let link = satellite.link {
                Button(action: link.action) { pill(chevron: true) }
                    .buttonStyle(.plain)
                    .help(satellite.help)
                    .accessibilityLabel(Text(verbatim: satellite.text))
                    .accessibilityHint(Text(verbatim: link.destination))
            } else {
                pill(chevron: false)
                    .help(satellite.help)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: satellite.text))
                    .accessibilityHint(Text(verbatim: satellite.help))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pill(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: satellite.symbol).font(.system(size: Ladder.badge, weight: .regular))
            Text(verbatim: satellite.text).font(.system(size: Ladder.badge)).lineLimit(1)
            if chevron {
                Image(systemName: Icon.link).font(.system(size: Ladder.micro, weight: .semibold))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor),
                                        style: StrokeStyle(lineWidth: 1, dash: satellite.dashed ? [3, 2] : [])))
        .contentShape(Capsule())
    }
}

/// The section a node scrolled to (§2, §6.3): a 2 pt accent outline once for 0.8 s. Nothing
/// under Reduce Motion (`FlowInteraction.flash` never sets it then).
private struct FlowFlash: ViewModifier {
    let id: String
    let interaction: FlowInteraction

    func body(content: Content) -> some View {
        let on = interaction.flashed == id
        content.overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-4)
                .opacity(on ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: on)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Outlines this view while `interaction` flashes `id` (the anchor a node scrolled to).
    public func flowFlash(_ id: String, in interaction: FlowInteraction) -> some View {
        modifier(FlowFlash(id: id, interaction: interaction))
    }
}

/// An app's own icon by bundle id (NSWorkspace), looked up once per id; nil when the app is not
/// installed.
@MainActor
public enum AppIcon {
    private static var icons: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    public static func image(_ bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard !missing.contains(bundleID) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}
