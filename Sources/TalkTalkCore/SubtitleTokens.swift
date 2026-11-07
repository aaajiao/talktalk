import Foundation

/// Shared visual tokens for the subtitle window, its titlebar and the settings preview
/// (docs/decisions/2026-11-06-subtitle-ui-redesign.md §2). Pure values only: AppKit colour,
/// font and shadow factories live in the app target and read everything from here.
public enum SubtitleTokens {
    /// sRGB components, 0…1.
    public struct RGBA: Sendable, Equatable {
        public var red: Double, green: Double, blue: Double, alpha: Double
        public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
        public init(hex: UInt32, alpha: Double = 1) {
            self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255,
                      Double(hex & 0xFF) / 255, alpha)
        }
        public static func white(_ alpha: Double) -> RGBA { RGBA(1, 1, 1, alpha) }
        public static func black(_ alpha: Double) -> RGBA { RGBA(0, 0, 0, alpha) }
        public func withAlpha(_ value: Double) -> RGBA { RGBA(red, green, blue, value) }
    }

    /// Colour roles. The subtitle panel is always darkAqua; `lightSurface` selects the
    /// light-settings variants where the table lists one. Translation blue never follows
    /// the user's accent colour.
    public enum Color: Sendable, CaseIterable {
        case voiceOriginal, voiceTranslate, speakerRemote
        case riskFill, riskStroke, warn
        case textPrimary, textSource, textSourceLive, textDraft, textMeta, textColumnHeader
        case videoSource, separator, pairHover, meRow
        /// Titlebar notification chip outline.
        case noticeStroke
        /// Titlebar chrome (§2 标题栏控件), each with an Increase Contrast value: the dim
        /// outline ("原声已关"), the dashed outline ("未发送"), the neutral capsule fill, the
        /// keycap border, secondary control text/icons (结束, ⋯, key action) at 70%, tertiary
        /// ones (chevron, scene source, information chip) at 60%, and the divider before 结束.
        case controlStroke, controlDashed, controlFill, keycapStroke, controlSecondary, controlTertiary, divider

        public func rgba(increaseContrast: Bool = false, lightSurface: Bool = false) -> RGBA {
            let ic = increaseContrast
            switch self {
            case .voiceOriginal: return RGBA(hex: 0x30D158)
            case .voiceTranslate: return RGBA(hex: lightSurface ? 0x0A64D6 : 0x409CFF)
            case .speakerRemote: return RGBA(hex: 0x40C8E0)
            case .riskFill: return RGBA(hex: 0xD70015)
            case .riskStroke: return RGBA(hex: 0xFF453A)
            case .warn: return RGBA(hex: lightSurface ? 0xC93400 : 0xFF9F0A)
            case .textPrimary: return .white(ic ? 1.0 : 0.92)
            case .textSource: return .white(ic ? 0.85 : 0.72)
            case .textSourceLive: return .white(ic ? 0.92 : 0.80)
            case .textDraft: return .white(ic ? 0.78 : 0.60)
            case .textMeta: return .white(0.60)
            case .textColumnHeader: return .white(0.45)
            case .videoSource: return ic ? .white(0.92) : RGBA(hex: 0xD1D1D6)
            case .separator: return .white(ic ? 0.35 : 0.08)
            case .pairHover: return .white(0.06)
            case .meRow: return RGBA(64 / 255, 156 / 255, 1, 0.08)
            case .noticeStroke: return .white(ic ? 0.6 : 0.28)
            case .controlStroke: return .white(ic ? 0.7 : 0.35)
            case .controlDashed: return .white(ic ? 0.8 : 0.5)
            case .controlFill: return .white(ic ? 0.22 : 0.12)
            case .keycapStroke: return .white(ic ? 0.7 : 0.3)
            case .controlSecondary: return .white(ic ? 0.9 : 0.7)
            case .controlTertiary: return .white(ic ? 0.9 : 0.6)
            case .divider: return .white(ic ? 0.5 : 0.2)
            }
        }
    }

    /// Separator thickness: 0.5 pt normally, 1 pt with Increase Contrast.
    public static func separatorWidth(increaseContrast: Bool) -> Double { increaseContrast ? 1 : 0.5 }
    /// Speaker track bar width.
    public static func trackWidth(increaseContrast: Bool) -> Double { increaseContrast ? 4 : 3 }

    // MARK: sizes (points)

    public enum Size {
        public static let titlebarHeight: Double = 32
        public static let videoHoverBarHeight: Double = 28
        public static let controlHeight: Double = 20
        public static let controlSpacing: Double = 6
        /// Gap on each side of the 1 pt divider before the end button.
        public static let endDividerGap: Double = 8
        public static let panelHorizontalPadding: Double = 12
        public static let panelBottomPadding: Double = 8
        public static let columnHeaderHeight: Double = 20
        public static let speakerTrackWidth: Double = 24
        public static let sourceColumnFraction: Double = 0.4
        public static let translationColumnFraction: Double = 0.6
        public static let columnGap: Double = 16
        public static let pairTopPadding: Double = 6
        public static let pairBottomPadding: Double = 8
        public static let statusBandIdleHeight: Double = 48
        public static let waveformBandHeight: Double = 24
        public static let jumpToLatestHeight: Double = 24

        // Titlebar components (§3).
        public static let capsuleMinWidth: Double = 64
        public static let capsuleMaxWidth: Double = 180
        public static let capsuleHorizontalPadding: Double = 8
        public static let capsuleVerticalPadding: Double = 3
        public static let capsuleIconSize: Double = 10
        public static let capsuleChevronSize: Double = 8
        public static let chipMaxWidth: Double = 180
        public static let keycapMinWidth: Double = 30
        public static let phoneButtonWidth: Double = 64
        public static let detailsPopoverWidth: Double = 320
        public static let detailsCapsuleHeight: Double = 24
        public static let cloudIconSize: Double = 16
        public static let cloudDotSize: Double = 6
        /// Icon-only titlebar controls (结束's narrow fallback, cloud, ⋯, an icon-only chip)
        /// share one symbol size and weight (medium).
        public static let iconOnlySymbol: Double = 13
        /// Below this window width only the keycap remains (no action text).
        public static let keyActionMinWindowWidth: Double = 560
    }

    /// The stand-in video picture behind the 字幕 page's caption thumbnails (settings visual
    /// system §3.12), inset in their white or black backdrop. A mid tone, so the white lines,
    /// the dark glass, the black plates and the black outline all read on it in Light and Dark
    /// Mode; on the bare backdrop black-on-black hid the outline and the plates.
    public static let captionThumbnailPicture = RGBA(hex: 0x4A6A8A)

    public enum Radius {
        public static let window: Double = 12
        public static let settingsCard: Double = 10
        public static let capsule: Double = 10
        public static let chip: Double = 9
        public static let videoGlass: Double = 10
        public static let solidRowBlock: Double = 6
        public static let keycap: Double = 5
    }

    // MARK: motion (seconds)

    public enum Motion: Sendable, CaseIterable {
        case statusBandResize, draftToFinal, videoPageCrossfade, videoTitlebarFadeIn, videoTitlebarHideDelay
        case chipFadeIn, noticeFadeOut, longSilenceDim, placeholderFadeOut

        public var seconds: Double {
            switch self {
            case .statusBandResize: 0.18
            case .draftToFinal: 0.15
            case .videoPageCrossfade: 0.12
            case .videoTitlebarFadeIn: 0.2
            case .videoTitlebarHideDelay: 1.5
            case .chipFadeIn: 0.15
            case .noticeFadeOut: 0.3
            case .longSilenceDim: 0.3
            case .placeholderFadeOut: 0.12
            }
        }

        /// Reduce Motion switches every transition instantly. The hide delay is not an
        /// animation: it still decides when the hover bar leaves.
        public func duration(reduceMotion: Bool) -> Double {
            reduceMotion && self != .videoTitlebarHideDelay ? 0 : seconds
        }
    }

    /// How long a notification chip stays before it fades.
    public static let noticeChipSeconds: Double = 4

    // MARK: legibility fallback

    public struct TextShadow: Sendable, Equatable {
        public var color: RGBA, blur: Double, offsetX: Double, offsetY: Double
    }

    public static let readingShadow = TextShadow(color: .black(0.55), blur: 3, offsetX: 0, offsetY: -0.5)

    /// Below 0.75 opacity body text gets `readingShadow`.
    public static func needsTextShadow(opacity: Double) -> Bool { opacity < 0.75 }

    /// Increase Contrast raises the scene opacity to at least 0.95. Reduce Transparency is
    /// handled by the window (opaque background), not by this value.
    public static func effectiveOpacity(_ opacity: Double, increaseContrast: Bool) -> Double {
        let value = opacity.isFinite ? min(1, max(0, opacity)) : 0.85
        return increaseContrast ? max(0.95, value) : value
    }

    // MARK: icons (one vocabulary for the titlebar, the scene page and the subtitle page)

    public enum SceneIcon {
        public static let meeting = "person.2.wave.2"
        public static let phone = "phone"
        public static let video = "play.rectangle"
    }

    public enum VoiceIcon {
        public static let original = "mic.fill"
        /// Not in every SF Symbols release; the app overlays exclamationmark.circle.fill on mic.fill.
        public static let originalRisk = "mic.badge.exclamationmark"
        public static let originalRiskFallbackBadge = "exclamationmark.circle.fill"
        /// Only for "原声已关" (restoring) and "音频不可用".
        public static let originalOff = "mic.slash"
        public static let translating = "waveform"
        public static let playingTranslation = "speaker.wave.2.fill"
        /// Only the confirmed "已送入 Phone" delivery tag.
        public static let sentToPhone = "phone.arrow.up.right"
        /// The titlebar's Phone button: open the Phone app (not a delivery fact).
        public static let openPhone = "arrow.up.forward.app"
        /// Nothing comes out: 未发送, 未接入 Phone, 本机就绪.
        public static let localOnly = "speaker.slash"
        /// Sound stays on this Mac: 本机试说, 仅本机, 本机播放, "Phone 未接收".
        public static let thisMac = "laptopcomputer"
        /// Reconnecting Phone or restarting audio: a process in progress, not a Reload action.
        public static let reconnecting = "arrow.triangle.2.circlepath"
        /// "已中止" (a Phone reader dropped mid-turn); stop.circle stays the user's end action.
        public static let aborted = "xmark.octagon"
        public static let listening = "ear"
        /// "字幕落后约 N 秒": captions are behind the audio.
        public static let captionLag = "clock.badge.exclamationmark"
        public static let locked = "lock.fill"
        public static let chevron = "chevron.down"
        /// The titlebar keycap's action glyphs (开始翻译 / 结束 this turn).
        public static let startTranslation = "translate"
        public static let stopTranslation = "stop.fill"
        /// Only the user's own end-session action.
        public static let end = "stop.circle"
        public static let cloud = "network"
        /// The video window's persistent status mark: warning triangle, risk octagon.
        public static let statusWarn = "exclamationmark.triangle.fill"
        public static let statusRisk = "exclamationmark.octagon.fill"
        /// The video hover bar's window options menu, as the menu bar's "更多".
        public static let more = "ellipsis.circle"
    }

    /// Meeting/phone timeline and microphone dock glyphs (§4). `mic.fill` stays 原声 only.
    public enum ConversationIcon {
        /// My rows' speaker mark (not `mic.fill`, which means 原声 on this surface).
        public static let me = "person.crop.circle.fill"
        public static let remote = "person.wave.2.fill"
        public static let phoneRemote = "phone.fill"
        /// "已送出": translated audio was played into TalkTalk Mic.
        public static let delivered = "checkmark.circle.fill"
        /// "N 条新字幕": jump back to the latest row.
        public static let jumpToLatest = "arrow.down"
        /// Long-source disclosure ("展开原文").
        public static let expand = "chevron.down.circle"
        /// The dock's "详情" (the app's info glyph). The silent-meeting placeholder uses the
        /// titlebar chip's `waveform.slash` instead: one glyph for "no sound from the other side".
        public static let details = "info.circle"
        /// The dock's "修复…" in the risk state.
        public static let fix = "wrench.and.screwdriver"
    }

    /// Settings window glyphs (docs/decisions/2026-11-06-settings-visual-system.md §4): one shape
    /// per meaning across the sidebar, cards, flow diagrams, rows and status. Pages and flows
    /// name these tokens, not literals. `remote` (the other party) is never the user's own
    /// synthesized voice.
    public enum SettingsIcon {
        /// The sidebar (§4 侧栏令牌). 使用场景 no longer shares the meeting card's glyph, and
        /// 模型 (recognition, translation and speech) no longer shares 翻译's.
        public enum Page {
            public static let general = "gearshape"
            public static let scenarios = "rectangle.3.group"
            public static let subtitles = SettingsIcon.subtitles
            public static let audio = SettingsIcon.audio
            public static let voice = SettingsIcon.myVoice
            public static let models = "square.stack.3d.up"
            public static let components = "shippingbox"
            public static let glossary = SettingsIcon.glossary
            public static let privacy = "hand.raised"
        }

        /// The icon ladder (§4), in points: one size per layer, 22 / 18 / 15 / 13 / 11 (+ 9).
        /// Symbols take these as `.font(.system(size:))` or `SymbolConfiguration(pointSize:)`,
        /// never a text style or a relative image scale.
        public enum Size {
            /// L1: scene and subpage cards, the PageHero tile, onboarding step titles.
            public static let card: Double = 22
            /// L2: flow nodes, app icons in nodes, StepTrack circles, DataBoundary panels.
            public static let node: Double = 18
            /// L3: Form row leading icons, section headers, lane gutter icons.
            public static let row: Double = 15
            /// L4: inline status glyphs, icon buttons, ⓘ, the ReturnPill and the menu bar menu.
            public static let inline: Double = 13
            /// L5: card and node badges, fact chip icons, satellites, flow arrows, the loop row.
            public static let badge: Double = 11
            /// Link chevrons, and the lock or warning inside a chip.
            public static let micro: Double = 9
            /// The ladder's one exception: an app icon in a NodeChip needs a little more than 11.
            public static let chipAppIcon: Double = 12
            /// The running dot on a scene card.
            public static let runningDot: Double = 8
            /// L3 icons sit in this fixed leading column; row text starts at `rowTextInset`
            /// (column + 8 pt spacing). Status rows and fact rows indent to the same inset.
            public static let rowColumn: Double = 22
            public static let rowTextInset: Double = 30
            /// Click area of icon-only buttons and ⓘ.
            public static let hitArea: Double = 22
            /// The window-coloured disc behind an 11 pt badge.
            public static let badgeDisc: Double = 15
            /// Fact chip height.
            public static let chipHeight: Double = 20
            /// Text sizes of the recording view (§7.7), not ladder steps: the 3-2-1 countdown and
            /// the script the user reads.
            public static let enrollmentCountdown: Double = 72
            public static let enrollmentScript: Double = 26
            /// Onboarding's header step indicator (§7.17), its own component and the one place
            /// these appear, not ladder steps: a 16 pt glyph in a 30 pt disc.
            public static let onboardingStep: Double = 16
            public static let onboardingStepDisc: Double = 30
        }

        /// The other party in flow diagrams (the timeline's remote marker is its .fill form).
        public static let remote = "person.wave.2"
        /// The user's own (synthesized) voice: the 我的声音 page, its flow nodes and sidebar row.
        public static let myVoice = "waveform.and.person.filled"
        /// The TalkTalk Mic virtual device; `mic` stays the physical microphone and `mic.fill`
        /// the 原声 capsule only.
        public static let talkTalkMic = "mic.circle"
        public static let physicalMic = "mic"
        /// Sidebar 音频.
        public static let audio = "mic.and.signal.meter"
        /// Speech recognition (as Apple's Speech Recognition privacy glyph).
        public static let recognition = "waveform"
        /// Translation, and recognition-with-translation nodes.
        public static let translation = "character.bubble"
        /// Source text (原文).
        public static let sourceText = "text.bubble"
        public static let subtitles = "captions.bubble"
        /// Synthesized translation and playback.
        public static let speech = "speaker.wave.2"
        /// The user (我); the phone's other party is `ConversationIcon.phoneRemote`.
        public static let me = ConversationIcon.me
        public static let listen = VoiceIcon.listening
        /// This Mac (本机); replaces desktopcomputer.
        public static let thisMac = VoiceIcon.thisMac
        /// The cloud and OpenAI; replaces cloud.
        public static let cloud = VoiceIcon.cloud
        /// Opens another app or System Settings.
        public static let openApp = "arrow.up.forward.app"
        /// Opens an explanation (ⓘ). Nothing else, the 关于 row and menu item included, uses it.
        public static let info = "info.circle"
        /// The privacy promise: nothing is uploaded.
        public static let privacyPromise = "lock.shield"
        /// Locked during a session.
        public static let locked = VoiceIcon.locked
        /// Automatic choice; replaces sparkles.
        public static let auto = "wand.and.stars"
        public static let engine = "cpu"
        /// Self-test, and the icon button that verifies.
        public static let verify = "checkmark.shield"
        public static let export = "square.and.arrow.up"
        /// A recording that is planned or a subtitle analysis that saves text (orange), and a
        /// diagnostic recording in progress (red).
        public static let recording = "record.circle"
        public static let recordingActive = "record.circle.fill"
        public static let slow = "tortoise"
        /// Performance and real-time capability; replaces gauge.
        public static let performance = "gauge.with.needle"
        public static let cost = "dollarsign.circle"
        public static let glossary = "character.book.closed"
        public static let headphones = "headphones"
        public static let speaker = "hifispeaker"
        /// 隐私与诊断 › 故障检查.
        public static let troubleshooting = "stethoscope"
        /// 字幕 › 用 VoiceOver 读出新字幕.
        public static let voiceOver = "voiceover"

        // 字幕 (§7.4): the size and background sliders with their end glyphs, the video style
        // rows, the window facts and the video preview's hover hint.
        public static let fontSize = "textformat.size"
        public static let fontSmaller = "textformat.size.smaller"
        public static let fontLarger = "textformat.size.larger"
        public static let background = "circle.lefthalf.filled"
        public static let backgroundClear = "circle.dotted"
        public static let backgroundSolid = "circle.fill"
        /// The system's Reduce Transparency fixes the background.
        public static let reduceTransparency = "accessibility"
        public static let captionArrangement = "arrow.up.arrow.down"
        public static let silenceDim = "moon.zzz"
        public static let subtitleWindow = "macwindow"
        public static let windowMovable = "arrow.up.and.down.and.arrow.left.and.right"
        public static let windowNoFocus = "keyboard"
        /// The window's own minimize button (the yellow traffic light), drawn single-colour.
        public static let windowMinimize = "minus.circle"
        public static let windowNotShared = "rectangle.on.rectangle.slash"
        /// The video window's hover bar shows only under the pointer.
        public static let hoverOnly = "cursorarrow"
        /// The phone preview's hotspot on the titlebar's Phone button: calls are dialled,
        /// answered and hung up in Phone (the numbers ①②③ stay the spec's three controls).
        public static let callsInPhone = SceneIcon.phone
        /// A feature this build lacks (ContentUnavailableView "此构建不可用").
        public static let unavailable = "xmark.circle"

        // 通用 (§7.5): one row each, the menu's glyph where the menu has the same item.
        public static let launchAtLogin = "power"
        public static let notifications = MenuIcon.notifications
        /// Asks macOS for notification permission ("允许…").
        public static let allowNotifications = "bell.badge"
        public static let announcement = MenuIcon.announcement
        /// 使用引导…, as in the menu.
        public static let onboarding = MenuIcon.onboarding

        // 音频 and 我的声音 (§7.6, §7.7).
        /// 原声音量: the calibrated level of the original voice.
        public static let inputVolume = "dial.medium"
        /// 录制 / 重录 the voice profile (the page's one primary action).
        public static let record = "mic.badge.plus"
        /// A length of time ("约 10–20 秒").
        public static let duration = "clock"

        // 模型 (§3.6, §7.8–§7.10).
        /// The OpenAI API key: its section and the saved key's row.
        public static let apiKey = "key"
        /// The field a new key is pasted into.
        public static let pasteKey = "doc.on.clipboard"
        /// 显示固定快照: pinned model snapshots in the model menu.
        public static let snapshots = "pin"
        /// 开始时提醒：文字发给 OpenAI.
        public static let cloudReminder = MenuIcon.notifications
        /// A model that is going away (the model menu's item glyph).
        public static let retiring = "clock.badge.exclamationmark"
        /// DataBoundary's OpenAI panel while no direction sends text there (未连接).
        public static let cloudOff = "network.slash"
        /// Nothing is synthesized (视频不生成), as the titlebar's nothing-sent glyph.
        public static let noSpeech = VoiceIcon.localOnly

        // 组件 (§7.11, §7.12): the engine's install lifecycle (下载 → 安装 → 校验 `verify` → 就绪
        // `engine`) and its maintenance, the driver's.
        public static let download = "arrow.down.circle"
        /// The package that gets installed, as the 组件 sidebar glyph.
        public static let install = Page.components
        public static let repair = "wrench.and.screwdriver"
        /// 重启引擎.
        public static let restartEngine = "power"
        /// 查看日志, and 字幕分析's 记录 node: a file to look into.
        public static let inspectFile = "doc.text.magnifyingglass"
        /// The audio service restarting after a driver install.
        public static let audioRestart = "arrow.triangle.2.circlepath"
        /// Check results: the driver's 详情 and 故障检查's 结果 node.
        public static let results = "list.bullet.rectangle"
        /// Apps using TalkTalk Mic (会议应用).
        public static let meetingApps = SceneIcon.meeting

        // 隐私与诊断 (§7.14–§7.16).
        /// 文字记录 (saved transcripts).
        public static let transcripts = "text.document"
        /// The ordinary event log (日志：不含文字和音频).
        public static let logs = "doc.text"
        /// 自动清理 (retention).
        public static let autoCleanup = "clock.arrow.circlepath"
        /// The diagnostics bundle (不进诊断包).
        public static let diagnosticsBundle = "shippingbox"
        /// 仅文字: subtitle analysis keeps text only.
        public static let textOnly = "text.quote"
        /// 仅本次 / 仅本场: one session only.
        public static let oneSession = "1.circle"
        /// 需全员同意（§201）.
        public static let consent = "checkmark.seal"
        /// 故障检查 › 技术详情 › 离线命令 (Terminal self-tests).
        public static let offlineCommands = "terminal"
        /// A self-test's raw values (数值).
        public static let checkValues = "number"

        // Navigation (§3.1, §3.13): the arrow between the model page's cards and the ReturnPill's
        // leading chevron.
        public static let flowArrow = "arrow.right"
        public static let back = "chevron.left"

        // Flow diagrams and the scene pages (§3.3–§3.5, §3.15, §7.1–§7.3).
        /// A node's link to another page or section: 9 pt semibold, always shown.
        public static let link = "chevron.right"
        /// The loop row between the two speaking lanes: back to the original voice.
        public static let loopBack = "arrow.uturn.backward"
        /// A meeting app not known yet (automatic choice before a session).
        public static let unknownApp = "app.dashed"
        /// A browser source also brings its other tabs.
        public static let browserTabs = "rectangle.on.rectangle"
        /// Video listens only: no microphone, no key to speak.
        public static let noMicrophone = "mic.slash"
        /// 首次连接: the iPhone, the same Apple account, the same network, and the call handoff
        /// between iPhone and Mac.
        public static let iPhone = "iphone"
        public static let sameAccount = "person.crop.circle"
        public static let sameNetwork = "wifi"
        public static let handoff = "arrow.left.arrow.right"
        /// The subtitle window is hidden for every scene (the bottom bar's tag).
        public static let subtitlesHidden = "eye.slash"
        /// The bottom bar's primary action: start or prepare, and end.
        public static let start = "play.fill"
        public static let stop = "stop.fill"
        /// Hand the typed number to Phone.
        public static let dial = VoiceIcon.sentToPhone
        /// Ending the session does not hang up (the user's own end glyph).
        public static let callContinues = VoiceIcon.end

        // Icon buttons (§3.10): one fixed glyph per action.
        public static let refresh = "arrow.clockwise"
        public static let reset = "arrow.counterclockwise"
        public static let add = "plus"
        public static let remove = "minus.circle"
        /// Close, or "got it".
        public static let close = "xmark"
        public static let copy = ActionIcon.copy
        /// Show in Finder.
        public static let finder = "folder"
        public static let delete = "trash"
        /// Cancel work in progress.
        public static let cancel = "xmark.circle"
        /// IconMenuButton's maintenance menu.
        public static let more = VoiceIcon.more

        /// Status (§3.7): passed / needs action / failed / not yet checked / waiting / recording.
        /// The risk state draws `VoiceIcon.originalRisk`. No status draws `info.circle`: that is ⓘ.
        public static let statusWarn = "exclamationmark.triangle.fill"
        public static let statusFailed = "xmark.circle.fill"
        public static let statusOK = "checkmark.circle.fill"
        public static let statusPending = "circle.dashed"
        public static let statusWaiting = "clock"
        public static let statusRecording = recordingActive
    }

    /// The menu bar status item and its menu. The status item keeps the captions bubble as its
    /// identity; problems differ by shape (question, triangle, exclamation bubble), not only by
    /// colour. Menu rows that open a settings page use that page's sidebar glyph.
    public enum MenuIcon {
        public static let standby = "captions.bubble"
        public static let listening = "captions.bubble.fill"
        public static let warming = "hourglass"
        /// Audio not yet confirmed (the meeting app's input is unchecked or not TalkTalk Mic yet).
        public static let audioUnconfirmed = "questionmark.bubble"
        /// Part of the session runs on a fallback, or the last one ended on an error.
        public static let degraded = "exclamationmark.triangle"
        /// Repairs outside the risk itself (default-input leftovers).
        public static let needsAttention = "exclamationmark.bubble"
        /// "会议尚未使用 TalkTalk Mic" while a session runs: needs action, not a risk.
        public static let micUnused = "exclamationmark.circle"
        public static let subtitles = "captions.bubble"
        public static let restoreWindow = "macwindow"
        public static let restoreInput = "arrow.uturn.backward.circle"
        public static let announcement = "megaphone"
        public static let notifications = "bell"
        public static let about = "info.circle"
        /// The onboarding guide, as Settings › 通用 "使用引导…".
        public static let onboarding = "arrow.clockwise.circle"
    }

    /// Onboarding (§7.17): the header's step marks, step 1's input-monitoring row and the done
    /// page (how to start from the menu bar).
    public enum OnboardingIcon {
        /// A step passed (not proof it was verified: secondary, never green) or skipped.
        public static let stepPassed = "checkmark"
        public static let stepSkipped = "minus"
        /// Step 1's 右⌥ row: the Input Monitoring permission.
        public static let inputMonitoring = "keyboard"
        /// The done page's title.
        public static let done = "flag.checkered"
        /// The status item's own glyph.
        public static let menuBar = MenuIcon.standby
        /// The menu's quick start (MenuQuickStart.symbol).
        public static let quickStart = "play.fill"
        /// The three scenario entries.
        public static let otherScenes = "rectangle.3.group"
    }

    /// Leading images of the details popover's command buttons.
    public enum ActionIcon {
        /// Buttons that open the Settings window, as the menu's "设置…".
        public static let settings = "gearshape"
        public static let copy = "doc.on.doc"
        /// "本场不再提示".
        public static let dismissReminder = "bell.slash"
    }
}

/// Meeting and phone reading sizes (§2 字体). `base` is the scene's base size B (default 22),
/// `width` the content width W in points.
public struct ConversationTypography: Sendable, Equatable {
    public enum Weight: Sendable, Equatable { case regular, medium, semibold }
    public struct Role: Sendable, Equatable {
        public var size: Double
        public var weight: Weight
        /// Line height as a multiple of the font size.
        public var lineHeight: Double
    }

    public static let defaultBase: Double = 22
    public static let referenceWidth: Double = 760

    public let remoteTranslation: Role
    public let source: Role
    public let myTranslation: Role

    public init(base: Double, width: Double) {
        let b = base.isFinite && base > 0 ? base : Self.defaultBase
        let f = Self.translationSize(base: b, width: width)
        remoteTranslation = Role(size: f, weight: .medium, lineHeight: 1.34)
        source = Role(size: max(12, 0.78 * f), weight: .regular, lineHeight: 1.30)
        myTranslation = Role(size: 0.86 * f, weight: .medium, lineHeight: 1.34)
    }

    /// F = B × clamp(√(W/760), 0.85, 1.30), then clamped to [14, B×1.3].
    public static func translationSize(base: Double, width: Double) -> Double {
        let w = width.isFinite && width > 0 ? width : referenceWidth
        let factor = min(1.30, max(0.85, (w / referenceWidth).squareRoot()))
        return min(base * 1.3, max(14, base * factor))
    }
}

/// Video caption sizes (§2): only the base size decides; width trims ±15% between 640 and
/// 1200 points. The narrow-window floors (§6) never raise the text above the chosen base.
public struct VideoCaptionTypography: Sendable, Equatable {
    public static let defaultBase: Double = 26
    public static let narrowWidth: Double = 640
    public static let wideWidth: Double = 1200

    public let translation: ConversationTypography.Role
    public let source: ConversationTypography.Role

    public init(base: Double, width: Double) {
        let b = base.isFinite && base > 0 ? base : Self.defaultBase
        translation = .init(size: Self.translationSize(base: b, width: width), weight: .semibold, lineHeight: 1.30)
        source = .init(size: max(14, 0.66 * b), weight: .regular, lineHeight: 1.30)
    }

    /// Linear from 0.85 B at 640 pt to 1.15 B at 1200 pt; flat outside; at least min(18, B).
    public static func translationSize(base: Double, width: Double) -> Double {
        let w = width.isFinite ? width : narrowWidth
        let t = min(1, max(0, (w - narrowWidth) / (wideWidth - narrowWidth)))
        return max(min(18, base), base * (0.85 + 0.30 * t))
    }
}

/// Fixed control text sizes (§2 字体), shared by the titlebar, popovers and the preview.
public enum ControlTypography {
    public static let capsule: Double = 11
    public static let chip: Double = 11
    public static let keyAction: Double = 11
    /// SF Mono, medium.
    public static let keycap: Double = 11
    public static let columnHeader: Double = 11
    public static let placeholder: Double = 13
    public static let fallbackBadge: Double = 10
    public static let titleScene: Double = 13
    /// The video hover bar's source name, shown after the scene icon instead of "视频字幕 · ".
    public static let titleVideoSource: Double = 12
    public static let endButton: Double = 11
    /// The microphone dock (§4): state label (semibold), consequence, separator dot and hint.
    public static let dockLabel: Double = 13
    public static let dockConsequence: Double = 12
    /// The details popover: sentences, and secondary explanations.
    public static let popoverBody: Double = 13
    public static let popoverSecondary: Double = 12
    /// The window's one-line hint (WindowHintView), medium.
    public static let windowHint: Double = 12
}
