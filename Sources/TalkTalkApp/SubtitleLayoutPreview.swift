// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// Settings › 字幕 preview (settings visual system §7.4, the page's main graphic). It renders
/// the live window's own titlebar, conversation timeline, microphone dock and video caption
/// view with fixed examples, at the real logical window size, scaled into the settings column.
/// Numbered hotspots on the titlebar's capsule, 右⌥ keycap and end button (phone adds a glyph
/// dot on its Phone button; video, a pointer on the hover bar's corner) say what those do in
/// their tooltip and VoiceOver label, in place of a caption. It never starts audio, a session or an animation timer, and it takes no
/// clicks.
struct SubtitleLayoutPreview: NSViewRepresentable {
    struct Configuration: Equatable {
        var scene: SubtitleScene
        var fontSize: Double
        var opacity: Double
        var videoStyle: VideoCaptionStyle
        var videoArrangement: VideoCaptionArrangement
        /// Follows the settings window's appearance: black page in Dark Mode, white page in Light.
        var darkBackdrop: Bool
        /// Passed in (not read inside) so SwiftUI's accessibility environment refreshes it.
        var display: SubtitleStyle.Display
    }

    let configuration: Configuration

    func makeNSView(context: NSViewRepresentableContext<Self>) -> SubtitlePreviewCanvas { SubtitlePreviewCanvas() }

    func updateNSView(_ view: SubtitlePreviewCanvas, context: NSViewRepresentableContext<Self>) {
        view.configure(configuration)
    }

    /// Locked aspect: the height follows the offered width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SubtitlePreviewCanvas,
                      context: NSViewRepresentableContext<Self>) -> CGSize? {
        let width = proposal.width.map(Double.init) ?? SubtitlePreviewLayout.fallbackWidth
        return CGSize(width: width, height: SubtitlePreviewLayout.canvasHeight(for: configuration.scene, width: width))
    }
}

/// Backdrop, then a rounded window with a shadow. Inside it, `root` has logical bounds
/// (760×480 or 960×150) so every component lays out exactly as in the live window.
@MainActor
final class SubtitlePreviewCanvas: NSView {
    private let backdrop = SubtitlePreviewBackdropView()
    private let shadowHost = NSView()
    private let windowClip = NSView()
    private let root = FlippedView()
    private let glass = NSVisualEffectView()
    private let opaqueBackground = NSView()
    private let titlebarTint = NSView()
    private let titlebarSeparator = NSView()
    private let hoverStrip = NSVisualEffectView()
    private let lights = PreviewTrafficLightsView()
    private let titleView = SubtitleTitleView()
    private let titlebar = SubtitleTitlebarView()
    private let timeline = ConversationTimelineView()
    private let dock = MicStatusDock()
    private let videoCaption = VideoSubtitleView()
    /// ① capsule, ② 右⌥ keycap, ③ end button (meeting and phone).
    private let titlebarHotspots = (1...3).map { PreviewHotspotView(.number($0)) }
    /// Phone only: the titlebar's Phone button, where calls are dialled, answered and hung up.
    private let phoneHotspot = PreviewHotspotView(.symbol(SubtitleTokens.SettingsIcon.callsInPhone))
    /// The video hover bar shows only under the pointer.
    private let hoverHotspot = PreviewHotspotView(.symbol(SubtitleTokens.SettingsIcon.hoverOnly))
    /// In titlebar reading order, for VoiceOver.
    private var hotspots: [PreviewHotspotView] {
        [titlebarHotspots[0], titlebarHotspots[1], phoneHotspot, titlebarHotspots[2], hoverHotspot]
    }
    private var configuration: SubtitleLayoutPreview.Configuration?
    private var laidOut: (configuration: SubtitleLayoutPreview.Configuration, size: NSSize)?

    override var isFlipped: Bool { true }
    // A picture of the window: clicks, hover and drags go nowhere. Only the hotspots take the
    // pointer, for their tooltips.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hotspots.first { !$0.isHidden && $0.frame.contains(local) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The preview has the subtitle window's own 12 pt corners (§7.4).
        layer?.cornerRadius = CGFloat(SubtitleTokens.Radius.window)
        layer?.masksToBounds = true
        addSubview(backdrop)
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.35
        shadowHost.layer?.shadowRadius = 10
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -4)
        addSubview(shadowHost)
        windowClip.wantsLayer = true
        windowClip.layer?.cornerRadius = CGFloat(SubtitleTokens.Radius.window)
        windowClip.layer?.masksToBounds = true
        shadowHost.addSubview(windowClip)
        root.wantsLayer = true
        // The subtitle window is always darkAqua (§2).
        root.appearance = NSAppearance(named: .darkAqua)
        windowClip.addSubview(root)
        for effect in [glass, hoverStrip] {
            effect.material = .hudWindow
            // The settings window has nothing of ours behind it: blur the in-window backdrop.
            effect.blendingMode = .withinWindow
            effect.state = .active
        }
        opaqueBackground.wantsLayer = true
        titlebarTint.wantsLayer = true
        titlebarTint.layer?.backgroundColor = SubtitleStyle.white(0.04).cgColor
        titlebarSeparator.wantsLayer = true
        videoCaption.glassBlendingMode = .withinWindow
        dock.setAccessibilityElement(false)
        for view in [opaqueBackground, glass, titlebarTint, titlebarSeparator, timeline, dock, videoCaption,
                     hoverStrip, lights, titleView, titlebar] as [NSView] {
            root.addSubview(view)
        }
        // Above the window picture, in canvas points: they keep their size at any scale.
        for hotspot in hotspots {
            hotspot.isHidden = true
            addSubview(hotspot)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "字幕窗口布局预览"))
    }

    required init?(coder: NSCoder) { nil }

    // The sample rows are not content: VoiceOver reads the preview's name and its hotspots.
    override func accessibilityChildren() -> [Any]? { hotspots.filter { !$0.isHidden } }

    func configure(_ next: SubtitleLayoutPreview.Configuration) {
        guard next != configuration else { return }
        configuration = next
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let configuration, bounds.width > 0 else { return }
        if let laidOut, laidOut.configuration == configuration, laidOut.size == bounds.size { return }
        laidOut = (configuration, bounds.size)
        let geometry = SubtitlePreviewLayout(scene: configuration.scene, canvasWidth: Double(bounds.width))
        backdrop.frame = bounds
        backdrop.isDark = configuration.darkBackdrop
        let windowRect = NSRect(x: geometry.windowX, y: geometry.windowY,
                                width: geometry.windowWidth, height: geometry.windowHeight)
        shadowHost.frame = windowRect
        windowClip.frame = shadowHost.bounds
        let radius = CGFloat(SubtitleTokens.Radius.window)
        // A clear video window casts its shadow from what it draws, like the live one.
        shadowHost.layer?.shadowPath = configuration.scene == .video ? nil
            : CGPath(roundedRect: shadowHost.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let logical = SubtitlePreviewLayout.logicalSize(for: configuration.scene)
        root.frame = windowClip.bounds
        root.bounds = NSRect(x: 0, y: 0, width: logical.width, height: logical.height)
        if configuration.scene == .video { layoutVideo(configuration) } else { layoutConversation(configuration) }
        layoutHotspots(configuration.scene)
    }

    // MARK: hotspots

    /// Every dot sits on its control's top-right corner, like a badge: the numbered ones on the
    /// titlebar's capsule, keycap and end button, phone's glyph dot on the Phone button, and the
    /// video's pointer on the hover bar (clear of the canvas edge and of the bar's controls).
    private func layoutHotspots(_ scene: SubtitleScene) {
        let diameter = PreviewHotspotView.diameter
        /// `spoken` names the subject for VoiceOver where the tooltip leaves it to the picture.
        func place(_ hotspot: PreviewHotspotView, on control: NSView, help: String, spoken: String? = nil) {
            let rect = convert(control.bounds, from: control)
            hotspot.frame = NSRect(x: rect.maxX - 2 - diameter / 2, y: rect.minY - diameter / 2,
                                   width: diameter, height: diameter)
            hotspot.describe(help: help, spoken: spoken)
            hotspot.isHidden = false
        }
        for hotspot in hotspots { hotspot.isHidden = true }
        if scene == .video {
            place(hoverHotspot, on: hoverStrip, help: String(localized: "悬停时显示"),
                  spoken: String(localized: "标题栏：鼠标悬停时显示"))
            return
        }
        let helps = [String(localized: "发声状态：点开看说明"), String(localized: "右⌥：开始或结束翻译"),
                     scene == .phone ? String(localized: "结束同传，不挂断电话") : String(localized: "结束同传")]
        for (index, control) in ([titlebar.capsule, titlebar.keycap, titlebar.end] as [NSView]).enumerated()
        where !control.isHidden {
            place(titlebarHotspots[index], on: control, help: helps[index])
        }
        if scene == .phone, !titlebar.phone.isHidden {
            place(phoneHotspot, on: titlebar.phone, help: String(localized: "打开 Phone：拨号、接听或挂断"))
        }
    }

    private func effectiveOpacity(_ configuration: SubtitleLayoutPreview.Configuration) -> Double {
        SubtitleTokens.effectiveOpacity(configuration.opacity, increaseContrast: configuration.display.increaseContrast)
    }

    // MARK: titlebar

    private func layoutTitlebar(_ content: SubtitleTitlebarContent, height: CGFloat, trailingMargin: CGFloat,
                                display: SubtitleStyle.Display) {
        let width = root.bounds.width
        lights.showsZoom = content.scene != .video
        lights.frame = NSRect(x: 0, y: 0, width: SubtitleTitlebarView.leadingTitleX, height: height)
        titleView.apply(scene: content.scene, source: content.sourceTitle)
        titlebar.trailingInset = content.scene == .video ? CGFloat(VideoStatusDot.reservedTrailingWidth) : 0
        titlebar.frame = NSRect(x: 0, y: 0, width: titlebar.frame.width, height: height)
        let reserved = Double(SubtitleTitlebarView.windowChrome + titleView.minimumWidth)
        let compaction = TitlebarCompaction.choose(windowWidth: Double(width), reservedLeading: reserved) {
            Double(titlebar.measure(content, $0))
        }
        titlebar.apply(content, compaction: compaction, display: display)
        let barWidth = titlebar.frame.width
        titlebar.frame = NSRect(x: width - trailingMargin - barWidth, y: 0, width: barWidth, height: height)
        titleView.frame = NSRect(x: SubtitleTitlebarView.leadingTitleX, y: 0, width: titleView.frame.width, height: height)
        titleView.setWidth(min(titleView.naturalWidth,
                               max(titleView.minimumWidth, width - SubtitleTitlebarView.windowChrome - barWidth)))
    }

    // MARK: meeting / phone

    private func layoutConversation(_ configuration: SubtitleLayoutPreview.Configuration) {
        let scene = configuration.scene
        let phone = scene == .phone
        let display = configuration.display
        let width = root.bounds.width, height = root.bounds.height
        let titleHeight = CGFloat(SubtitlePreviewLayout.titlebarHeight(for: scene))
        let opacity = effectiveOpacity(configuration)
        // Same rule as the live window: Reduce Transparency or 100% makes it opaque.
        let opaque = display.reduceTransparency || opacity >= 1
        glass.isHidden = opaque
        glass.alphaValue = CGFloat(opacity)
        glass.frame = root.bounds
        opaqueBackground.isHidden = !opaque
        opaqueBackground.frame = root.bounds
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            opaqueBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            titlebarSeparator.layer?.backgroundColor = SubtitleStyle.color(.separator, display: display).cgColor
        }
        titlebarTint.isHidden = false
        titlebarTint.frame = NSRect(x: 0, y: 0, width: width, height: titleHeight)
        titlebarSeparator.isHidden = false
        titlebarSeparator.frame = NSRect(x: 0, y: titleHeight - 0.5, width: width, height: 0.5)
        hoverStrip.isHidden = true
        videoCaption.isHidden = true
        timeline.isHidden = false
        dock.isHidden = false

        let audio = HUDModel.MeetingAudio.original
        let voice = VoiceState.resolve(audio: audio, scene: scene, phoneInputConfirmed: phone)
        let key = TitlebarKey.make(SpeechStatusPresentation(audio: audio, phoneInputConfirmed: phone ? true : nil), voice: voice)
        layoutTitlebar(SubtitleTitlebarContent(scene: scene, source: phone ? nil : "Zoom", voice: voice, key: key,
                                               showsPhone: phone, showsEnd: true),
                       height: titleHeight, trailingMargin: 8, display: display)

        let contentHeight = height - titleHeight
        let rules = ConversationLayout(contentWidth: Double(width), contentHeight: Double(contentHeight))
        let style = ConversationStyle(typography: ConversationTypography(base: configuration.fontSize, width: Double(width)),
                                      opacity: opacity, display: display, scene: scene, stacked: rules.stacked)
        let language = String(localized: "英语")
        timeline.setHeader(source: phone ? String(localized: "通话对方 · \(language)") : String(localized: "原文 · \(language)"),
                           translation: String(localized: "译文 · 中文"))
        timeline.apply(rows: Self.sampleRows(phone: phone), style: style,
                       lastRowOnly: rules.lastRowOnly, showsHeader: rules.showsColumnHeader)
        dock.apply(.init(presentation: MicDockPresentation.make(voice, scene: scene), turn: nil,
                         expanded: false, showsStartHint: false), style: style, compact: rules.compactDock)
        let dockHeight = CGFloat(rules.dockHeight(speaking: false))
        let padding = CGFloat(SubtitleTokens.Size.panelHorizontalPadding)
        timeline.frame = NSRect(x: padding, y: titleHeight, width: max(0, width - 2 * padding),
                                height: max(0, contentHeight - dockHeight))
        dock.frame = NSRect(x: 0, y: height - dockHeight, width: width, height: dockHeight)
        timeline.layoutSubtreeIfNeeded()
        dock.layoutSubtreeIfNeeded()
        // A fixed example level: the preview never starts audio, and this curve never expires.
        dock.setPreviewLevel(0.04)
    }

    private static func row(_ id: ConversationTimeline.RowID, _ speaker: ConversationTimeline.Speaker, source: String,
                            translation: String, final: Bool = true, delivery: ConversationTimeline.Delivery? = nil,
                            order: UInt64) -> ConversationTimeline.Row {
        .init(id: id, speaker: speaker, source: source, sourceIsLive: false, translation: translation, translationIsFinal: final,
              fallback: false, unsentSource: "", delivery: delivery, arrivedAt: HostTime(order),
              settledAt: final ? HostTime(order) : nil, order: order)
    }

    /// Two remote pairs (the second still a draft) around one of my turns.
    private static func sampleRows(phone: Bool) -> [ConversationTimeline.Row] {
        if phone {
            return [
                row(.remote(1), .remote, source: "Hi, I'm calling to confirm your appointment. Would Tuesday morning work for you?",
                    translation: String(localized: "您好，我打电话来确认您的预约。周二上午您方便吗？"), order: 1),
                row(.me(1), .me, source: String(localized: "周二上午可以，谢谢。请再告诉我一下具体地址。"),
                    translation: "Tuesday morning works, thank you. Could you give me the address again?",
                    delivery: .phoneSent, order: 2),
                row(.remote(2), .remote, source: "Of course. We're on Market Street, on the second floor.",
                    translation: String(localized: "当然。我们在市场街，二楼"), final: false, order: 3),
            ]
        }
        return [
            row(.remote(1), .remote, source: "Let's confirm the plan for next week. Would Tuesday morning work for you?",
                translation: String(localized: "我们确认一下下周的安排。周二上午你方便吗？"), order: 1),
            row(.me(1), .me, source: String(localized: "周二上午可以。我们可以先看演示，再讨论接下来的安排。"),
                translation: "Tuesday morning works. Let's start with the demo, then talk about next steps.",
                delivery: .sent, order: 2),
            row(.remote(2), .remote, source: "Great. I'll send the agenda and the meeting link this afternoon.",
                translation: String(localized: "好的。我今天下午把议程和"), final: false, order: 3),
        ]
    }

    // MARK: video

    private func layoutVideo(_ configuration: SubtitleLayoutPreview.Configuration) {
        let display = configuration.display
        let width = root.bounds.width
        let barHeight = CGFloat(SubtitlePreviewLayout.titlebarHeight(for: .video))
        // Clear window: only the caption style and the shown hover bar draw anything (§6).
        glass.isHidden = true
        opaqueBackground.isHidden = true
        titlebarTint.isHidden = true
        titlebarSeparator.isHidden = true
        timeline.isHidden = true
        dock.isHidden = true
        dock.stopLevel()
        videoCaption.isHidden = false
        hoverStrip.isHidden = false
        hoverStrip.alphaValue = 1
        hoverStrip.frame = NSRect(x: 0, y: 0, width: width, height: barHeight)
        layoutTitlebar(SubtitleTitlebarContent(scene: .video, source: "Google Chrome",
                                               voice: VoiceState.resolve(audio: nil, scene: .video),
                                               showsEnd: true, showsMore: true),
                       height: barHeight, trailingMargin: 0, display: display)

        let typography = VideoCaptionTypography(base: configuration.fontSize, width: Double(width))
        videoCaption.frame = root.bounds
        videoCaption.appearanceSettings = .init(
            style: configuration.videoStyle.effective(reduceTransparency: display.reduceTransparency),
            arrangement: configuration.videoArrangement, opacity: CGFloat(effectiveOpacity(configuration)),
            reduceTransparency: display.reduceTransparency,
            // A still picture: no page or finalization fades.
            reduceMotion: true, increaseContrast: display.increaseContrast)
        let translation = String(localized: "最简单的想法，往往始于换一种方式去看待我们身边的世界")
        let source = VideoSubtitleView.sourceText("The simplest ideas often begin with a different way of looking at the world around us.",
                                                  font: SubtitleStyle.font(typography.source), display: display)
        // An unfinished tail: the last three characters are still changing.
        let target = VideoSubtitleView.translationText(translation, isFinal: false, stablePrefix: translation.count - 3,
                                                       font: SubtitleStyle.font(typography.translation))
        videoCaption.setCaption(source: source, translation: target, sentence: 1, isFinal: false, at: 0)
        videoCaption.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The red, yellow (and, outside video, green) window buttons, drawn only.
@MainActor
private final class PreviewTrafficLightsView: NSView {
    var showsZoom = true { didSet { if showsZoom != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let colors: [UInt32] = showsZoom ? [0xFF5F57, 0xFEBC2E, 0x28C840] : [0xFF5F57, 0xFEBC2E]
        let diameter: CGFloat = 12
        for (index, hex) in colors.enumerated() {
            SubtitleStyle.nsColor(SubtitleTokens.RGBA(hex: hex)).setFill()
            let center = NSPoint(x: 14 + CGFloat(index) * 20, y: bounds.midY)
            NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                        width: diameter, height: diameter)).fill()
        }
    }
}

/// A preview hotspot (§7.4): an 11 pt number or glyph on a 16 pt disc of thin HUD material
/// (the dots sit on the always-dark subtitle window), with what the control does as its
/// tooltip and VoiceOver label. It takes no clicks.
///
/// The tooltip is a rect tooltip, not `toolTip`: AppKit reports a view's `toolTip` as its
/// AXHelp (even over `accessibilityHelp()`), so VoiceOver would read the same words twice.
@MainActor
final class PreviewHotspotView: NSView, NSViewToolTipOwner {
    enum Mark {
        case number(Int)
        case symbol(String)
    }

    static let diameter: CGFloat = 16

    /// The tooltip text.
    private(set) var help = ""

    /// `spoken`: the VoiceOver label where it must name the subject the picture shows; the
    /// tooltip otherwise.
    func describe(help: String, spoken: String? = nil) {
        self.help = help
        let label = spoken ?? help
        if accessibilityLabel() != label { setAccessibilityLabel(label) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        help
    }

    private let material = NSVisualEffectView()

    init(_ mark: Mark) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        let face = PreviewHotspotFace(mark: mark)
        for view in [material, face] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        // The disc never resizes (it only moves), so one rect in its own bounds stays right.
        addToolTip(bounds, owner: self, userData: nil)
    }

    required init?(coder: NSCoder) { nil }

    // A tooltip target only: a click does nothing.
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityChildren() -> [Any]? { [] }
}

/// The dot's light tint, its hairline ring and the number or glyph, in white.
@MainActor
private final class PreviewHotspotFace: NSView {
    private let mark: PreviewHotspotView.Mark

    init(mark: PreviewHotspotView.Mark) {
        self.mark = mark
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.22).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        NSColor(white: 0, alpha: 0.25).setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        let size = CGFloat(SubtitleTokens.SettingsIcon.Size.badge)
        switch mark {
        case .number(let number):
            let text = NSAttributedString(string: String(number), attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let extent = text.size()
            text.draw(at: NSPoint(x: bounds.midX - extent.width / 2, y: bounds.midY - extent.height / 2))
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            let extent = image.size
            image.draw(in: NSRect(x: bounds.midX - extent.width / 2, y: bounds.midY - extent.height / 2,
                                  width: extent.width, height: extent.height))
        }
    }
}

/// A white page in Light Mode, a black page in Dark Mode (the system appearance), drawn in
/// plain shapes under the preview window.
@MainActor
final class SubtitlePreviewBackdropView: NSView {
    var isDark = false { didSet { if isDark != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private struct Palette {
        let base, toolbar, separator, heading, lines, accent: UInt32
    }

    private static let light = Palette(base: 0xFFFFFF, toolbar: 0xF2F2F7, separator: 0xE5E5EA,
                                       heading: 0x3A3A3C, lines: 0xD1D1D6, accent: 0xCFE3FF)
    private static let dark = Palette(base: 0x000000, toolbar: 0x1C1C1E, separator: 0x2C2C2E,
                                      heading: 0x8E8E93, lines: 0x3A3A3C, accent: 0x1F3A5F)

    private static func color(_ hex: UInt32) -> NSColor {
        SubtitleStyle.nsColor(SubtitleTokens.RGBA(hex: hex))
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = isDark ? Self.dark : Self.light
        let width = bounds.width, height = bounds.height
        Self.color(palette.base).setFill(); bounds.fill()
        Self.color(palette.toolbar).setFill(); NSRect(x: 0, y: 0, width: width, height: 30).fill()
        Self.color(palette.separator).setFill(); NSRect(x: 0, y: 30, width: width, height: 1).fill()
        NSBezierPath(roundedRect: NSRect(x: width * 0.3, y: 8, width: width * 0.4, height: 14), xRadius: 7, yRadius: 7).fill()
        let left = width * 0.08, column = width * 0.56
        Self.color(palette.heading).setFill()
        NSBezierPath(roundedRect: NSRect(x: left, y: 50, width: column * 0.7, height: 14), xRadius: 3, yRadius: 3).fill()
        Self.color(palette.lines).setFill()
        var y: CGFloat = 80
        var index = 0
        let widths: [CGFloat] = [1, 0.94, 0.98, 0.7, 1, 0.9, 0.96, 0.6]
        while y < height - 10 {
            let lineWidth = column * widths[index % widths.count]
            NSBezierPath(roundedRect: NSRect(x: left, y: y, width: lineWidth, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            y += index % 4 == 3 ? 30 : 16
            index += 1
        }
        Self.color(palette.accent).setFill()
        NSBezierPath(roundedRect: NSRect(x: left + column + width * 0.06, y: 50, width: width * 0.24, height: min(160, height * 0.4)),
                     xRadius: 8, yRadius: 8).fill()
    }
}
