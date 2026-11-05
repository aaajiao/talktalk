// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import TalkTalkCore
import TalkTalkSession

/// A non-activating subtitle panel on every Space, excluded from screen sharing. Its visible
/// native title bar can always be dragged; wrapped text grows with the chosen font and scrolls only when
/// it would exceed the screen. The board still advances at its existing 9-character/s cadence.
@MainActor
final class SubtitlePanel {
    static let idleFadeSeconds: TimeInterval = 8

    private let panel: NSPanel
    private let content = SubtitleContentView()
    private let body = SubtitleContentView()
    private let scroll = NSScrollView()
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let finalLabels = [NSTextField(wrappingLabelWithString: ""), NSTextField(wrappingLabelWithString: "")]
    private let finalSourceLabels = [NSTextField(wrappingLabelWithString: ""), NSTextField(wrappingLabelWithString: "")]
    private let draftLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var board = SubtitleBoard(maxCharactersPerSecond: 9)
    private var fontSize: CGFloat = 22
    private var lastUpdate = Date.distantPast
    private var liveSource = ""
    private var timer: Timer?
    private var moveObserver: NSObjectProtocol?
    var analysisRecorder: SubtitleAnalysisRecorder?
    private var analysisConfiguration: UInt64 = 0
    private var presentedFinals: [SubtitleBoard.Line] = []
    private var presentedDraft: SubtitleBoard.Line?
    private var labelsInOrder: [NSTextField] {
        [finalSourceLabels[0], finalLabels[0], finalSourceLabels[1], finalLabels[1], sourceLabel, draftLabel]
    }
    /// The HUD reads the same screen-space anchor, including after a user drag or font change.
    var frame: NSRect { panel.frame }
    var onFrameChange: ((NSRect) -> Void)?

    init() {
        panel = SubtitleWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                               styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.title = String(localized: "字幕")
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titleVisibility = .visible
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = body
        content.addSubview(scroll)
        for label in labelsInOrder {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isSelectable = false
            label.cell?.isScrollable = false
            body.addSubview(label)
        }
        for label in finalSourceLabels + [sourceLabel] { label.textColor = NSColor(white: 0.65, alpha: 1) }
        for label in finalLabels { label.textColor = .white }
        draftLabel.textColor = NSColor(white: 0.68, alpha: 1)
        panel.contentView = content
        setFontSize(22)
        placeInitially()
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func setFontSize(_ size: Double) {
        fontSize = CGFloat(size.isFinite ? min(36, max(16, size)) : 22)
        for label in finalSourceLabels + [sourceLabel] { label.font = .systemFont(ofSize: max(12, fontSize * 0.65)) }
        for label in finalLabels { label.font = .systemFont(ofSize: fontSize, weight: .medium) }
        draftLabel.font = .systemFont(ofSize: max(14, fontSize * 0.88))
        render()
    }

    func apply(_ update: SubtitleUpdate) {
        let now = HostClock.now()
        let previousPending = board.pendingFinalSentenceIDs
        let previousSource = liveSource
        if case .source(let text) = update { liveSource = text }
        let changed = board.apply(update, at: now)
        switch update {
        case let .final(sentence, text, source, approx, numberWarning):
            observe("subtitle_queued", at: now,
                    line: .init(sentence: sentence, text: text, source: source, approx: approx, numberWarning: numberWarning), kind: "final")
        case let .draft(sentence, text):
            observe("subtitle_queued", at: now,
                    line: .init(sentence: sentence, text: text, approx: false, numberWarning: false), kind: "draft")
        case let .dropped(sentence):
            observe("subtitle_dropped", at: now,
                    line: .init(sentence: sentence, text: "", approx: false, numberWarning: false))
        case .source: break
        }
        for sentence in previousPending where !board.pendingFinalSentenceIDs.contains(sentence)
            && !board.finals.contains(where: { $0.sentence == sentence }) {
            observe("subtitle_discarded", at: now,
                    line: .init(sentence: sentence, text: "", approx: false, numberWarning: false), kind: "pacing_overflow")
        }
        lastUpdate = Date()
        if changed || previousSource != liveSource { render() }
    }
    func setHint(_ hint: String?) { board.setHint(hint); lastUpdate = Date(); render() }
    func clear() {
        liveSource = ""; board.clear(); render()
        observe("subtitle_cleared", at: HostClock.now())
    }

    func setAnalysisConfiguration(_ id: UInt64) {
        guard analysisConfiguration != id else { return }
        analysisConfiguration = id
        presentedFinals = []; presentedDraft = nil
        observe("configuration_reset", at: HostClock.now())
    }

    private func render() {
        let lines = Array(board.finals.suffix(finalLabels.count))
        for index in finalLabels.indices {
            let line = index < lines.count ? lines[index] : nil
            finalSourceLabels[index].stringValue = line?.source ?? ""
            finalLabels[index].stringValue = line?.display ?? ""
        }
        let currentSource = liveSource.isEmpty ? "" : String(localized: "识别中：\(liveSource)")
        sourceLabel.stringValue = board.hint ?? (board.isEmpty ? String(localized: "等待应用声音…") : currentSource)
        draftLabel.stringValue = board.draft.map { String(localized: "草稿：\($0.text)") } ?? ""
        layout()
        body.alphaValue = 1
        recordPresentation()
    }

    private func recordPresentation() {
        guard panel.isVisible else { return }
        let now = HostClock.now()
        // Log actual label changes after board pacing, including revisions, not timer ticks or
        // font/layout refreshes. This is AppKit submission time, not a display hardware timestamp.
        for line in board.finals where !presentedFinals.contains(line) {
            observe("subtitle_displayed", at: now, line: line, kind: "final")
        }
        for line in presentedFinals where !board.finals.contains(where: { $0.sentence == line.sentence }) {
            observe("subtitle_removed", at: now, line: line, kind: "final")
        }
        if let draft = board.draft, draft != presentedDraft {
            observe("subtitle_displayed", at: now, line: draft, kind: "draft")
        } else if board.draft == nil, let draft = presentedDraft {
            observe("subtitle_removed", at: now, line: draft, kind: "draft")
        }
        presentedFinals = board.finals; presentedDraft = board.draft
    }

    private func observe(_ event: String, at time: HostTime, line: SubtitleBoard.Line? = nil, kind: String? = nil) {
        analysisRecorder?.recordPanel(event, configuration: analysisConfiguration, at: time,
                                      line: line, kind: kind, visible: panel.isVisible,
                                      pendingFinals: board.pendingFinalSentenceIDs,
                                      pendingDraft: board.pendingDraftSentenceID)
    }

    private func layout() {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(min(max(640, fontSize * 34.5), 960), max(280, visible.width - 40))
        let textWidth = width - 44
        var y: CGFloat = 0
        for label in labelsInOrder {
            label.isHidden = label.stringValue.isEmpty
            guard !label.isHidden, let font = label.font else { continue }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            let bounds = (label.stringValue as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
            let height = ceil(max(font.ascender - font.descender + font.leading, bounds.height)) + 4
            label.preferredMaxLayoutWidth = textWidth
            label.frame = NSRect(x: 0, y: y, width: textWidth, height: height)
            y += height + (finalLabels.contains(where: { $0 === label }) ? 14 : 5)
        }
        let bodyHeight = max(24, y)
        let viewportHeight = min(bodyHeight, max(100, visible.height * 0.7 - 60))
        let size = NSSize(width: width, height: viewportHeight + 24)
        let old = panel.frame
        panel.setContentSize(size)
        content.frame = NSRect(origin: .zero, size: size)
        scroll.frame = NSRect(x: 16, y: 12, width: width - 32, height: viewportHeight)
        body.frame = NSRect(x: 0, y: 0, width: width - 32, height: bodyHeight)
        scroll.hasVerticalScroller = bodyHeight > viewportHeight
        // Keep the panel's bottom/centre anchored as the text changes, and on this screen.
        let x = min(max(visible.minX + 12, old.midX - width / 2), visible.maxX - width - 12)
        let bottom = min(max(visible.minY + 12, old.minY), visible.maxY - panel.frame.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: bottom))
        onFrameChange?(panel.frame)
    }

    func setVisible(_ on: Bool) {
        if on {
            body.alphaValue = 1; lastUpdate = Date()
            panel.orderFrontRegardless()
            observe("panel_shown", at: HostClock.now())
            recordPresentation()
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        } else {
            panel.orderOut(nil); timer?.invalidate(); timer = nil
            observe("panel_hidden", at: HostClock.now())
            presentedFinals = []; presentedDraft = nil
        }
    }
    var isVisible: Bool { panel.isVisible }

    private func poll() {
        if board.advance() { lastUpdate = Date(); render() }
        let hovering = panel.frame.contains(NSEvent.mouseLocation)
        // Keep the title bar visible while idle; the text becomes quieter instead of making an
        // invisible window that users cannot find or move.
        body.alphaValue = hovering || Date().timeIntervalSince(lastUpdate) <= Self.idleFadeSeconds ? 1 : 0.55
    }

    private func key(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "ui.subtitleOrigin.\(number?.stringValue ?? "main")"
    }
    private func placeInitially() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if let saved = UserDefaults.standard.string(forKey: key(for: screen)) {
            let point = NSPointFromString(saved)
            if screen.visibleFrame.insetBy(dx: -40, dy: -40).contains(point) { panel.setFrameOrigin(point); return }
        }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 80))
    }
    private func savePosition() {
        onFrameChange?(panel.frame)
        guard let screen = panel.screen else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: key(for: screen))
    }

    var sharingTypeIsNone: Bool { panel.sharingType == .none }
    var collectionBehavior: NSWindow.CollectionBehavior { panel.collectionBehavior }
    var clickThrough: Bool { panel.ignoresMouseEvents }
    var shownLines: [String] { labelsInOrder.map(\.stringValue) }
}

private final class SubtitleWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class SubtitleContentView: NSView { override var isFlipped: Bool { true } }
