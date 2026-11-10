// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// One line of the push-to-talk HUD (ARCHITECTURE.md §11 按键说话 HUD).
public struct HUDLine: Sendable, Equatable {
    /// `permissions`: the system-audio grant; `inputMonitoring`: key listening (输入监控).
    public enum SettingsDestination: Sendable, Equatable { case audio, translation, permissions, inputMonitoring }
    public enum Style: String, Sendable, Equatable {
        case normal
        /// Gray: hints, live preview, refusal reasons.
        case secondary
        /// A committed segment (✓).
        case check
        /// Warning tone; rendered with the platform's systemOrange.
        case yellow
        case red
        /// Red background, white text: passthrough is open (§3.8).
        case redBanner
    }

    public var text: String
    public var style: Style
    /// 0…1 input level drawn next to the text (holding, passthrough open); nil: no meter.
    public var level: Float?
    /// Full explanation shown on demand; the short text still states the immediate consequence.
    public var detail: String?
    public var symbol: String?
    public var settingsDestination: SettingsDestination?

    public init(_ text: String, _ style: Style = .normal, level: Float? = nil,
                detail: String? = nil, symbol: String? = nil, settingsDestination: SettingsDestination? = nil) {
        self.text = text
        self.style = style
        self.level = level
        self.detail = detail
        self.symbol = symbol
        self.settingsDestination = settingsDestination
    }
}

/// Phone-only emphasis shared by the settings page and subtitle HUD. Input confirmation
/// proves that Phone reads TalkTalk Mic, never that the remote participant has heard it.
public struct PhoneSpeechPresentation: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case ready, original, translation, progress, unavailable }
    public var title: String
    public var action: String
    public var detail: String
    public var symbol: String
    public var tone: Tone
}

/// Everything the HUD shows, as a pure function of what it was told and the time (seconds on a
/// monotonic clock). No AppKit; the panel (`PTTHUD`) only draws `lines(now:)`.
///
/// M1 uses `warnings` (LISTEN's hints when the subtitle panel is hidden, the OpenAI fallbacks).
/// Actual meeting audio state comes from the raw gate and SPEAK lifecycle, never inferred from
/// a meeting merely being active. The legacy passthrough event API remains for isolated uses.
public struct HUDModel: Sendable, Equatable {
    // MARK: inputs

    /// The §11 warnings, plus LISTEN's own hints.
    public enum Warning: Sendable, Hashable {
        case meetingNotUsingMic
        /// The meeting app reads a physical mic (§8.6); the app also plays a cue in the headphones.
        case remoteHearsYourVoice
        case floorPaused(segments: Int)
        case numberMaybeWrong(String)
        case skipped(segments: Int)
        case segmentNotSent
        case sentenceMaybeIncomplete
        case unsupportedTextNotSent
        case speakerMode
        /// The meeting app's playback device is not known yet: treated as speakers for safety.
        case playbackUnknown
        case audioRestarting
        case meetingSilent
        case meetingSeemsOver
        case tccUnconfirmed
        case defaultInputChanged(to: String)
        case switchedBackAfterInsert(device: String)
        /// Switching back to TalkTalk Mic failed; the default input really is this device
        /// (SystemInputSwitcher.Notice.switchBackFailed, once per round).
        case switchBackFailed(current: String)
        case defaultInputRestored(to: String)
        /// Restored, but not to the original (§8.6 RestoreTarget.Notice), said once with the restore.
        case defaultInputRestoredElsewhere(to: String, original: String, originalMissing: Bool)
        /// Entering meeting mode did not switch the default input (SystemInputSwitcher.EntryResult).
        case defaultInputNotSwitched(SysInputDialogPlan.EntryIssue)
        case openAIUnreachable
        /// Once per meeting.
        case openAIKeyInvalid
        /// Once per meeting (TranslationSettings shows it once in all).
        case modelRetired

        public var text: String {
            switch self {
            case .meetingNotUsingMic: String(appLocalized: "会议没用 TalkTalk Mic")
            case .remoteHearsYourVoice: String(appLocalized: "会议正在用实体麦，对方仍可能听到原声；按键翻译已停用")
            case let .floorPaused(n): String(appLocalized: "对方在说话 · 已暂停 \(n) 段")
            case let .numberMaybeWrong(s): String(appLocalized: "数字可能有误：\(s)")
            case let .skipped(n): String(appLocalized: "已跳过 \(n) 段")
            case .segmentNotSent: String(appLocalized: "这段未发送")
            case .sentenceMaybeIncomplete: String(appLocalized: "该句可能不完整")
            case .unsupportedTextNotSent: String(appLocalized: "这段文字暂不支持，未发送")
            case .speakerMode: String(appLocalized: "正在外放，请戴耳机")
            case .playbackUnknown: String(appLocalized: "尚未读到会议应用的播放设备")
            case .audioRestarting: String(appLocalized: "音频系统重启中")
            case .meetingSilent: String(appLocalized: "会议当前没有声音")
            case .meetingSeemsOver: String(appLocalized: "会议似乎已结束")
            case .tccUnconfirmed: String(appLocalized: "没能确认系统录音权限")
            case let .defaultInputChanged(x): String(appLocalized: "系统默认输入被改成了 \(x)")
            case let .switchedBackAfterInsert(x): String(appLocalized: "\(x) 接入后系统换了默认输入，已切回 TalkTalk Mic")
            case let .switchBackFailed(x): String(appLocalized: "没能切回 TalkTalk Mic，系统默认输入是 \(x)")
            case let .defaultInputRestored(x): String(appLocalized: "默认输入已还原为 \(x)")
            case let .defaultInputRestoredElsewhere(x, o, missing):
                missing ? String(appLocalized: "默认输入已还原为 \(x)（原来的 \(o) 不在了）")
                        : String(appLocalized: "默认输入已还原为 \(x)（原来的 \(o) 是虚拟设备，不还原到它）")
            case let .defaultInputNotSwitched(issue): issue.text
            case .openAIUnreachable: String(appLocalized: "OpenAI 暂时连不上，改用 Apple 翻译")
            case .openAIKeyInvalid: String(appLocalized: "OpenAI key 无效或额度用完，已改用 Apple 翻译")
            case .modelRetired: String(appLocalized: "所选模型已下线，已换回 gpt-6-luna")
            }
        }

        public var style: HUDLine.Style {
            switch self {
            case .meetingNotUsingMic, .remoteHearsYourVoice: .red
            case .switchedBackAfterInsert, .defaultInputRestored, .defaultInputRestoredElsewhere,
                 .meetingSilent, .meetingSeemsOver: .normal
            default: .yellow
            }
        }

        /// Compact status for the meeting surface. Device names and technical explanations
        /// stay in `text`; safety consequences are never hidden behind the details control.
        public var summary: String {
            switch self {
            case .remoteHearsYourVoice: String(appLocalized: "会议仍会发送原声 · 翻译已停用")
            case let .floorPaused(n): String(appLocalized: "对方在说话 · 已暂停 \(n) 段")
            case .numberMaybeWrong: String(appLocalized: "译文数字待核对")
            case .defaultInputChanged: String(appLocalized: "系统麦克风已改变")
            case .switchedBackAfterInsert: String(appLocalized: "已恢复 TalkTalk Mic")
            case .switchBackFailed: String(appLocalized: "未能切回 TalkTalk Mic")
            case .defaultInputRestored: String(appLocalized: "系统麦克风已还原")
            case .defaultInputRestoredElsewhere: String(appLocalized: "已还原到其他实体麦克风")
            case .defaultInputNotSwitched(let issue):
                switch issue {
                case .micMissing: String(appLocalized: "未找到 TalkTalk Mic")
                case .noPhysicalInput: String(appLocalized: "未找到实体麦克风")
                case .writeFailed: String(appLocalized: "系统麦克风切换失败")
                case .recordWriteFailed, .guardLaunchFailed: String(appLocalized: "麦克风还原准备失败")
                case .micNotSelectable: String(appLocalized: "TalkTalk Mic 暂不可选")
                }
            case .openAIUnreachable: String(appLocalized: "OpenAI 暂时不可用 · 已用 Apple")
            case .openAIKeyInvalid: String(appLocalized: "OpenAI key 或额度异常 · 已用 Apple")
            case .modelRetired: String(appLocalized: "翻译模型已更换")
            default: text
            }
        }

        public var symbol: String {
            switch self {
            // mic.slash means "original off"; these mean the remote side may hear raw audio.
            case .meetingNotUsingMic, .remoteHearsYourVoice: SubtitleTokens.VoiceIcon.originalRisk
            case .speakerMode, .playbackUnknown: "headphones"
            case .audioRestarting: SubtitleTokens.VoiceIcon.reconnecting
            // Absence states are slashed, never the active-capture waveform.
            case .meetingSilent: "waveform.slash"
            case .meetingSeemsOver: "person.2.slash"
            case .tccUnconfirmed: "hand.raised"
            case .defaultInputChanged, .switchBackFailed, .defaultInputNotSwitched: "mic.badge.xmark"
            case .switchedBackAfterInsert, .defaultInputRestored, .defaultInputRestoredElsewhere: "checkmark.circle"
            // network alone means "cloud translation is on"; a failed cloud is slashed.
            case .openAIUnreachable, .openAIKeyInvalid: "network.slash"
            case .modelRetired: SubtitleTokens.VoiceIcon.cloud
            case .floorPaused: "pause.circle"
            case .numberMaybeWrong, .sentenceMaybeIncomplete: "exclamationmark.triangle"
            case .skipped: "nosign"
            // The same glyph as the "未发送" tag on my row.
            case .segmentNotSent, .unsupportedTextNotSent: ConversationTextRules.unsentSymbol
            }
        }

        public var line: HUDLine {
            let destination: HUDLine.SettingsDestination? = switch self {
            case .meetingNotUsingMic, .remoteHearsYourVoice, .speakerMode, .playbackUnknown, .defaultInputChanged,
                 .switchBackFailed, .defaultInputNotSwitched: .audio
            case .openAIUnreachable, .openAIKeyInvalid, .modelRetired: .translation
            case .tccUnconfirmed: .permissions
            default: nil
            }
            return HUDLine(summary, style, detail: summary == text ? nil : text,
                           symbol: symbol, settingsDestination: destination)
        }

        /// Silence names the selected scene: Phone's call audio or the video's app sound,
        /// without claiming that a call ended just because no sound arrived.
        public func chip(scene: SubtitleScene) -> HUDChip? {
            // The automatic end is near: every scene says so and how to keep listening (the
            // notification's words, for users who allow none).
            if scene == .phone, self == .meetingSeemsOver {
                return HUDChip(titlebarLabel("长时间无通话音频"), symbol: "waveform.slash", tone: .info,
                               detail: String(appLocalized: "Phone 已长时间没有通话音频，即将结束电话同传；要继续，请在菜单栏选择“继续收听”"))
            }
            if scene == .meeting, self == .meetingSeemsOver, var meeting = chip {
                meeting.detail = String(appLocalized: "会议应用长时间没有声音，会议同传即将自动结束；要继续，请在菜单栏选择“继续收听”")
                return meeting
            }
            // The microphone guard also covers Phone; the subject is Phone, not the meeting.
            if scene == .phone, self == .remoteHearsYourVoice, let chip {
                return HUDChip(titlebarLabel("Phone 在用实体麦"), symbol: chip.symbol, tone: chip.tone,
                               detail: String(appLocalized: "请在 Phone 的“音频 › 麦克风”选择“使用系统设置”或 TalkTalk Mic。"),
                               settingsDestination: chip.settingsDestination)
            }
            // Phone is the app whose playback is not read yet.
            if scene == .phone, self == .playbackUnknown, var phone = chip {
                phone.detail = String(appLocalized: "尚未读到 Phone 的播放设备")
                return phone
            }
            guard scene == .video else { return chip }
            switch self {
            case .meetingSilent:
                return HUDChip(titlebarLabel("暂无声音"), symbol: "waveform.slash", tone: .info,
                               detail: String(appLocalized: "所选应用当前没有声音"))
            case .meetingSeemsOver:
                return HUDChip(titlebarLabel("长时间没有声音"), symbol: "waveform.slash", tone: .info,
                               detail: String(appLocalized: "应用长时间没有声音，视频字幕即将自动结束；要继续，请在菜单栏选择“继续收听”"))
            default:
                return chip
            }
        }

        /// The titlebar chip (≤10 characters; notifications ≤8). nil: details only.
        public var chip: HUDChip? {
            let tone: HUDChip.Tone = switch self {
            case .meetingSilent, .meetingSeemsOver: .info
            default:
                switch style {
                case .red, .redBanner: .risk
                case .yellow: .warn
                case .normal, .secondary, .check: .notice
                }
            }
            let label: String
            switch self {
            case .remoteHearsYourVoice: label = titlebarLabel("会议在用实体麦")
            case .meetingNotUsingMic: label = titlebarLabel("会议未用 TalkTalk Mic")
            case .floorPaused: label = titlebarLabel("对方在说话 · 译音已暂停")
            case .numberMaybeWrong: label = titlebarLabel("译文数字待核对")
            case .skipped: label = titlebarLabel("部分内容已跳过")
            case .segmentNotSent: label = titlebarLabel("这段未发送")
            case .sentenceMaybeIncomplete: label = titlebarLabel("该句可能不完整")
            case .unsupportedTextNotSent: label = titlebarLabel("文字不支持 · 未发送")
            case .speakerMode: label = titlebarLabel("正在外放 · 请戴耳机")
            case .playbackUnknown: label = titlebarLabel("播放设备未确认")
            case .audioRestarting: label = titlebarLabel("音频系统重启中")
            case .meetingSilent: label = titlebarLabel("未听到对方")
            case .meetingSeemsOver: label = titlebarLabel("会议似乎已结束")
            case .tccUnconfirmed: label = titlebarLabel("录音权限未确认")
            case .defaultInputChanged: label = titlebarLabel("系统麦克风已改变")
            case .switchedBackAfterInsert: label = noticeLabel("已恢复 TalkTalk Mic")
            case .switchBackFailed: label = titlebarLabel("未能切回 TalkTalk Mic")
            case .defaultInputRestored: label = noticeLabel("系统麦克风已还原")
            case .defaultInputRestoredElsewhere: label = noticeLabel("已还原其他麦克风")
            case let .defaultInputNotSwitched(issue):
                label = switch issue {
                case .micMissing: titlebarLabel("未找到 TalkTalk Mic")
                case .noPhysicalInput: titlebarLabel("未找到实体麦克风")
                case .writeFailed: titlebarLabel("系统麦克风切换失败")
                case .recordWriteFailed, .guardLaunchFailed: titlebarLabel("麦克风还原准备失败")
                case .micNotSelectable: titlebarLabel("TalkTalk Mic 暂不可选")
                }
            case .openAIUnreachable: label = titlebarLabel("OpenAI 暂时不可用 · 已用 Apple")
            case .openAIKeyInvalid: label = titlebarLabel("OpenAI key 异常 · 已用 Apple")
            case .modelRetired: label = titlebarLabel("翻译模型已更换")
            }
            return HUDChip(label, symbol: symbol, tone: tone, detail: text,
                           settingsDestination: line.settingsDestination)
        }

        /// Fixed ordering independent of post time, queue count and associated device/text.
        fileprivate var compactPriority: Int {
            switch self {
            case .remoteHearsYourVoice: 0
            case .meetingNotUsingMic: 10
            case .switchBackFailed: 11
            case .defaultInputNotSwitched: 12
            case .segmentNotSent: 13
            case .unsupportedTextNotSent: 14
            case .skipped: 15
            case .sentenceMaybeIncomplete: 16
            case .numberMaybeWrong: 17
            case .audioRestarting: 21
            case .tccUnconfirmed: 22
            case .speakerMode, .playbackUnknown: 23
            case .defaultInputChanged: 24
            case .floorPaused: 25
            case .openAIKeyInvalid: 26
            case .openAIUnreachable: 27
            case .modelRetired: 28
            case .meetingSilent, .meetingSeemsOver, .switchedBackAfterInsert,
                 .defaultInputRestored, .defaultInputRestoredElsewhere: 90
            }
        }

        /// Conditions stay until cleared; notices fade after `noticeSeconds`.
        public var isCondition: Bool {
            switch self {
            case .meetingNotUsingMic, .remoteHearsYourVoice, .floorPaused, .speakerMode, .playbackUnknown, .audioRestarting,
                 .meetingSilent, .meetingSeemsOver, .tccUnconfirmed:
                true
            default:
                false
            }
        }

        public var oncePerMeeting: Bool { self == .openAIKeyInvalid || self == .modelRetired }

        /// SystemInputSwitcher's notices (§8.6). They outlive meetingStarted / meetingEnded: the
        /// restore and the entry result arrive around those calls, in either order.
        public var isSysInput: Bool {
            switch self {
            case .defaultInputChanged, .switchedBackAfterInsert, .defaultInputRestored, .defaultInputRestoredElsewhere,
                 .defaultInputNotSwitched, .switchBackFailed:
                true
            default:
                false
            }
        }

        /// Identity for set/clear: a condition with a count replaces the older count.
        var slot: String {
            switch self {
            case .floorPaused: "floorPaused"
            case .numberMaybeWrong: "numberMaybeWrong"
            case .skipped: "skipped"
            case .defaultInputChanged: "defaultInputChanged"
            case .switchedBackAfterInsert: "switchedBackAfterInsert"
            case .switchBackFailed: "switchBackFailed"
            case .defaultInputRestored, .defaultInputRestoredElsewhere: "defaultInputRestored"
            case .defaultInputNotSwitched: "defaultInputNotSwitched"
            default: String(describing: self)
            }
        }
    }

    public enum Voice: Sendable, Equatable {
        case mine, fallbackModel, system
        public var text: String {
            switch self {
            case .mine: String(appLocalized: "我的声音")
            case .fallbackModel: String(appLocalized: "备用模型")
            case .system: String(appLocalized: "系统声音")
            }
        }
    }

    public enum MTSource: Sendable, Equatable { case openAI, apple }

    /// Set only by the real raw-audio gate / translate-and-drain lifecycle. `nil` means the
    /// caller is not using default-original meeting audio (for example the isolated demo).
    public enum MeetingAudio: Sendable, Equatable {
        /// The session has just started and the gate is not open yet (feed attaching, key
        /// monitor arming). Nothing is sent; it is normal progress, not a fault, so it reads as
        /// "未发送" rather than "音频不可用". The owner escalates to `.unavailable` if it lasts.
        case preparing
        /// Phone is prepared but is not currently reading audio. This does not assert whether
        /// the call is connected, muted, on hold or finished; the owner verifies readiness.
        case phoneReady
        case original
        /// The physical key is down; its clean release confirms the recording-mode change.
        case switching
        case translating
        case draining
        /// Translation is finished and healthy routing is awaiting the next confirmed gate open.
        case restoringOriginal
        /// Phone's microphone reader changed mid-call: current speech was cancelled and the
        /// cleanup barrier holds local speech until the reset completes.
        case phoneReconnecting
        /// The raw gate is closed, including a translation press that was refused.
        case unavailable(reason: String)

        public var text: String {
            switch self {
            case .preparing: String(appLocalized: "正在准备音频")
            case .phoneReady: String(appLocalized: "电话同传已就绪 · 点按右⌥即可开始翻译")
            case .original: String(appLocalized: "原声发送中 · 点按右⌥开始翻译")
            case .switching: String(appLocalized: "正在切换发言方式")
            case .translating: String(appLocalized: "翻译收音中 · 再点按右⌥完成发言（原声已关闭）")
            case .draining: String(appLocalized: "译音处理中 · 播完后恢复原声")
            case .restoringOriginal: String(appLocalized: "正在恢复原声")
            case .phoneReconnecting: String(appLocalized: "正在重新连接 Phone · 当前发言已停止")
            case let .unavailable(reason): String(appLocalized: "TalkTalk 音频暂不可用：\(reason)")
            }
        }

        /// The action or consequence shown alongside the mode when no warning takes priority.
        public var operationHint: String? {
            switch self {
            case .phoneReady: String(appLocalized: "点按右⌥开始翻译，可在拨号前试说")
            case .original: String(appLocalized: "点按右⌥开始翻译")
            case .switching: String(appLocalized: "松开右⌥确认")
            case .translating: String(appLocalized: "再点按右⌥完成发言 · 原声已关闭")
            case .draining: String(appLocalized: "播完后恢复原声")
            case .restoringOriginal: String(appLocalized: "请稍候")
            case .phoneReconnecting: String(appLocalized: "等待 Phone")
            case .preparing, .unavailable: nil
            }
        }

        public func phonePresentation(inputConfirmed: Bool) -> PhoneSpeechPresentation {
            switch self {
            case .preparing:
                return .init(title: String(appLocalized: "正在准备音频"), action: String(appLocalized: "请稍候"),
                             detail: String(appLocalized: "正在准备音频；现在什么都没有发出去。"),
                             symbol: SubtitleTokens.VoiceIcon.localOnly, tone: .progress)
            case .phoneReady:
                return .init(title: String(appLocalized: "本机同传已就绪"),
                             action: String(appLocalized: "点按右⌥开始翻译"),
                             detail: inputConfirmed
                                ? String(appLocalized: "Phone 已接入，正在准备发送原声。")
                                : String(appLocalized: "未确认 Phone 接入；可以先在本机试说。"),
                             symbol: SubtitleTokens.VoiceIcon.localOnly, tone: .ready)
            case .original:
                guard inputConfirmed else {
                    return .init(title: String(appLocalized: "等待 Phone 接入"),
                                 action: String(appLocalized: "点按右⌥可本机试说"),
                                 detail: String(appLocalized: "尚未确认通话输入，不能确认原声已送入 Phone。"),
                                 symbol: SubtitleTokens.VoiceIcon.localOnly, tone: .ready)
                }
                return .init(title: String(appLocalized: "原声发送中"),
                             action: String(appLocalized: "点按右⌥开始翻译"),
                             detail: String(appLocalized: "Phone 已接入；你的原声正在送入 Phone。"),
                             symbol: SubtitleTokens.VoiceIcon.original, tone: .original)
            case .switching:
                return .init(title: String(appLocalized: "切换发言方式"),
                             action: String(appLocalized: "松开右⌥确认切换"),
                             detail: String(appLocalized: "原声已关闭，正在确认这次点按。"),
                             symbol: "arrow.left.arrow.right", tone: .progress)
            case .translating:
                return .init(title: String(appLocalized: "翻译收音中"),
                             action: String(appLocalized: "再点按右⌥完成发言"),
                             detail: inputConfirmed
                                ? String(appLocalized: "Phone 已接入；原声已关闭，正在收音并翻译。")
                                : String(appLocalized: "本机翻译收音中，原声已关闭；未确认 Phone 接入。"),
                             symbol: SubtitleTokens.VoiceIcon.translating, tone: .translation)
            case .draining:
                return .init(title: String(appLocalized: "译音处理中"),
                             action: String(appLocalized: "点按右⌥继续翻译"),
                             detail: inputConfirmed
                                ? String(appLocalized: "原声保持关闭；剩余译音播完后恢复原声。")
                                : String(appLocalized: "正在处理剩余本机译音；未确认 Phone 接入。"),
                             // Not told whether audio plays: never claim playback.
                             symbol: SubtitleTokens.VoiceIcon.translating, tone: .progress)
            case .restoringOriginal:
                return .init(title: String(appLocalized: "正在恢复原声"),
                             action: String(appLocalized: "点按右⌥开始翻译"),
                             detail: String(appLocalized: "正在准备恢复原声，确认后开始发送。"),
                             symbol: SubtitleTokens.VoiceIcon.originalOff, tone: .progress)
            case .phoneReconnecting:
                return .init(title: String(appLocalized: "正在重新连接 Phone"),
                             action: String(appLocalized: "请稍候"),
                             detail: String(appLocalized: "Phone 的麦克风读取发生变化，当前发言已停止；完成清理后才能继续说话。"),
                             symbol: SubtitleTokens.VoiceIcon.reconnecting, tone: .progress)
            case let .unavailable(reason):
                return .init(title: String(appLocalized: "音频暂不可用"),
                             action: String(appLocalized: "请先检查音频状态"), detail: reason,
                             symbol: "exclamationmark.triangle", tone: .unavailable)
            }
        }
    }

    public enum PushToTalk: Sendable, Equatable {
        /// Nothing held; the meeting audio state supplies the default-original status separately.
        case idle
        case holding(level: Float, preview: String, committed: [String], queued: Int)
        case playing(lang: Lang, voice: Voice, source: MTSource, queued: Int)
    }

    /// What the passthrough gate reported (§3.8), already reduced to what the HUD needs. Texts
    /// come from the gate's own `hudText` (PassthroughCloseReason / PassthroughRefusal).
    public enum PassthroughEvent: Sendable, Equatable {
        /// Right ⌘ went down. Shows nothing: under 400 ms nothing is ever shown.
        case pressed
        /// An armed press ended before opening (shortcut, release): nothing is shown.
        case cancelled
        case waitingForClause
        case opened
        case level(Float)
        case countdown(secondsLeft: Int)
        /// `reason`: nil for a normal release.
        case closed(reason: String?)
        /// `reason`: nil means no reaction at all (outside meeting mode, setting off).
        case refused(reason: String?)
    }

    enum Passthrough: Sendable, Equatable {
        case none
        case waiting
        case open(level: Float, secondsLeft: Int?)
        case closed(reason: String?, until: Double)
        case refused(reason: String, until: Double)
    }

    // MARK: timing (§11, §3.8)

    public static let closedSeconds = 1.0
    public static let refusedSeconds = 1.5
    public static let noticeSeconds = 4.0
    public static let countdownFrom = 5
    public static let transcriptRetentionSeconds = 60.0

    // MARK: state

    public var meetingActive = false
    public var meetingAudio: MeetingAudio?
    public var pushToTalk: PushToTalk = .idle
    /// Push to talk is wired. Until then no idle shortcut instruction is shown.
    public var pushToTalkAvailable = false
    /// Only original audio is unavailable (e.g. speakers): the key still starts translation.
    public var translationKeyAvailable = false
    public private(set) var transcript: SpeakTranscript?
    public var speechWorkPending = false
    private var latestTranscriptPress: UInt64?
    private var transcriptUntil: Double?
    private(set) var passthrough: Passthrough = .none
    private var conditions: [String: Warning] = [:]
    private var conditionOrder: [String] = []
    private var notices: [(warning: Warning, until: Double)] = []
    private var shownThisMeeting: Set<String> = []

    // Titlebar facts (§3). The voice capsule reads these directly; they never compete
    // with problems for the issue slot.
    public var scene: SubtitleScene = .meeting
    /// Phone reads TalkTalk Mic (verified). Never proof that the remote side heard anything.
    public var phoneInputConfirmed = false
    /// Translated audio is actually being played into the feed.
    public var outputPlaying = false
    /// Cloud translation is on and its privacy note has not been dismissed this session.
    public var cloudPrivacyPending = false

    /// Problems reported outside the §11 table (subtitle engine, Phone operation, video captions
    /// more than 5 s behind).
    public enum ExternalIssue: String, Sendable, Hashable, CaseIterable { case subtitles, scene, videoLag }
    private var externalIssues: [ExternalIssue: HUDChip] = [:]
    /// A one-off message (SysInputDialogPlan, a failed speech start) shown for `noticeSeconds`.
    private var message: (chip: HUDChip, until: Double)?

    public init() {}

    public static func == (a: HUDModel, b: HUDModel) -> Bool {
        a.meetingActive == b.meetingActive && a.pushToTalk == b.pushToTalk && a.pushToTalkAvailable == b.pushToTalkAvailable
            && a.translationKeyAvailable == b.translationKeyAvailable
            && a.meetingAudio == b.meetingAudio
            && a.transcript == b.transcript && a.transcriptUntil == b.transcriptUntil
            && a.speechWorkPending == b.speechWorkPending
            && a.latestTranscriptPress == b.latestTranscriptPress
            && a.passthrough == b.passthrough
            && a.conditions == b.conditions && a.conditionOrder == b.conditionOrder
            && a.notices.map(\.warning) == b.notices.map(\.warning) && a.notices.map(\.until) == b.notices.map(\.until)
            && a.shownThisMeeting == b.shownThisMeeting
            && a.scene == b.scene && a.phoneInputConfirmed == b.phoneInputConfirmed
            && a.outputPlaying == b.outputPlaying && a.cloudPrivacyPending == b.cloudPrivacyPending
            && a.externalIssues == b.externalIssues
            && a.message?.chip == b.message?.chip && a.message?.until == b.message?.until
    }

    // MARK: updates

    public mutating func meetingStarted() {
        meetingActive = true
        shownThisMeeting = []
        notices.removeAll { !$0.warning.isSysInput }
        pushToTalk = .idle
        meetingAudio = nil; translationKeyAvailable = false
        transcript = nil; latestTranscriptPress = nil; transcriptUntil = nil; speechWorkPending = false
    }

    /// A SPEAK replacement invalidates its callbacks before async shutdown. Clear its live
    /// presentation explicitly without ending LISTEN or discarding route/privacy warnings.
    /// A draft disappears here; this transition never promotes it to a finished transcript.
    public mutating func speakingEnded() {
        pushToTalk = .idle; pushToTalkAvailable = false
        meetingAudio = nil; translationKeyAvailable = false; outputPlaying = false; speechWorkPending = false
        transcript = nil; latestTranscriptPress = nil; transcriptUntil = nil
        passthrough = .none
        for warning in [Warning.floorPaused(segments: 0), .numberMaybeWrong(""), .skipped(segments: 0),
                        .segmentNotSent, .sentenceMaybeIncomplete, .unsupportedTextNotSent] {
            clear(warning)
        }
    }

    public mutating func meetingEnded() {
        meetingActive = false
        outputPlaying = false
        cloudPrivacyPending = false
        externalIssues = [:]
        // A one-off message belongs to the ended session; the menu bar keeps any failure.
        message = nil
        conditions = [:]
        conditionOrder = []
        notices.removeAll { !$0.warning.isSysInput }
        pushToTalk = .idle
        meetingAudio = nil; translationKeyAvailable = false
        transcript = nil; latestTranscriptPress = nil; transcriptUntil = nil; speechWorkPending = false
        passthrough = .none
    }

    /// Shows a warning. Conditions stay until `clear`; notices for `noticeSeconds`. A once-per-
    /// meeting notice is dropped the second time.
    public mutating func post(_ w: Warning, now: Double) {
        if w.isCondition {
            if conditions[w.slot] == nil { conditionOrder.append(w.slot) }
            conditions[w.slot] = w
            return
        }
        if w.oncePerMeeting {
            guard !shownThisMeeting.contains(w.slot) else { return }
            shownThisMeeting.insert(w.slot)
        }
        notices.removeAll { $0.warning.slot == w.slot }
        notices.append((w, now + Self.noticeSeconds))
    }

    public mutating func clear(_ w: Warning) {
        conditions[w.slot] = nil
        conditionOrder.removeAll { $0 == w.slot }
        notices.removeAll { $0.warning.slot == w.slot }
    }

    public mutating func receiveTranscript(_ value: SpeakTranscript, now: Double) {
        // A new press's empty snapshot clears reading history even if the audio-mode update
        // arrives later. Raw-original mode still rejects actual recognition drafts.
        if meetingAudio == .original, !value.isFinal,
           !value.source.isEmpty || !value.target.isEmpty || !value.unsubmittedSource.isEmpty { return }
        if let latestTranscriptPress {
            guard value.press >= latestTranscriptPress else { return }
            // A late snapshot cannot resurrect an expired press or replace final text with a
            // volatile callback. A new press has its own ID and immediately replaces the old.
            if value.press == latestTranscriptPress {
                guard let transcript, !transcript.isFinal || value.isFinal else { return }
            }
        }
        if value.press != latestTranscriptPress { transcriptUntil = nil }
        latestTranscriptPress = value.press; transcript = value
        refreshTranscriptLifetime(now: now)
    }

    public mutating func refreshTranscriptLifetime(now: Double) {
        guard transcript?.isFinal == true else { transcriptUntil = nil; return }
        if speechWorkPending { transcriptUntil = nil }
        else if transcriptUntil == nil { transcriptUntil = now + Self.transcriptRetentionSeconds }
    }

    public mutating func expireTranscript(at now: Double, reading: Bool = false) {
        guard let until = transcriptUntil, now >= until else { return }
        if reading { transcriptUntil = now + 2 }
        else { transcript = nil; transcriptUntil = nil }
    }

    public func visibleTranscript(at now: Double) -> SpeakTranscript? {
        guard let transcript, transcriptUntil.map({ now < $0 }) ?? true,
              !transcript.source.isEmpty || !transcript.target.isEmpty || !transcript.unsubmittedSource.isEmpty else { return nil }
        return transcript
    }

    public mutating func passthrough(_ e: PassthroughEvent, now: Double) {
        switch e {
        case .pressed:
            // Under 400 ms nothing is shown; a press does not even clear a fading "原声已关闭"
            // line, so a quick tap looks like nothing happened.
            break
        case .cancelled:
            // A release while waiting for the clause ends the wait; otherwise nothing was shown.
            if passthrough == .waiting { passthrough = .none }
        case .waitingForClause:
            passthrough = .waiting
        case .opened:
            passthrough = .open(level: 0, secondsLeft: nil)
        case let .level(l):
            if case let .open(_, s) = passthrough { passthrough = .open(level: l, secondsLeft: s) }
        case let .countdown(s):
            if case let .open(l, _) = passthrough {
                passthrough = .open(level: l, secondsLeft: s <= Self.countdownFrom ? max(0, s) : nil)
            }
        case let .closed(reason):
            passthrough = .closed(reason: reason, until: now + Self.closedSeconds)
        case let .refused(reason):
            if let reason {
                passthrough = .refused(reason: reason, until: now + Self.refusedSeconds)
            } else if passthrough == .waiting {
                passthrough = .none      // e.g. the setting was turned off during the wait
            }
        }
    }

    // MARK: output

    /// Top to bottom: passthrough, red warnings, push-to-talk, other warnings, notices.
    public func lines(now: Double) -> [HUDLine] {
        var out: [HUDLine] = []
        if let audio = meetingAudio, meetingActive {
            let style: HUDLine.Style = switch audio {
            case .preparing, .phoneReady, .original, .switching, .translating, .draining, .restoringOriginal,
                 .phoneReconnecting: .normal
            case .unavailable: .yellow
            }
            if case .unavailable = audio {
                out.append(HUDLine(String(appLocalized: "音频暂不可用"), style,
                                   detail: audio.text, symbol: "exclamationmark.triangle"))
            } else { out.append(HUDLine(audio.text, style)) }
        } else if let p = passthroughLine(now: now) { out.append(p) }
        let conds = conditionOrder.compactMap { conditions[$0] }
        // A physical-mic warning is more precise than the generic unavailable status and
        // must remain first: the meeting app may still send raw audio outside our gate.
        if conds.contains(.remoteHearsYourVoice), case .unavailable = meetingAudio { out.removeAll() }
        out += conds.filter { $0.style == .red }.map(\.line)
        if meetingActive, pushToTalkAvailable { out += pushToTalkLines() }
        out += conds.filter { $0.style != .red }.map(\.line)
        out += notices.filter { $0.until > now }.map { $0.warning.line }
        return out
    }

    public mutating func setExternalIssue(_ key: ExternalIssue, _ chip: HUDChip?) {
        externalIssues[key] = chip
    }

    /// The complete sentence goes to the chip's detail; the label stays short (§3).
    public mutating func show(_ chip: HUDChip, now: Double) {
        message = (chip, now + Self.noticeSeconds)
    }

    /// Raw-audio risk facts that rewrite the voice capsule.
    public var voiceRisk: VoiceState.Risk? {
        if conditions[Warning.remoteHearsYourVoice.slot] != nil { return .remoteHearsYourVoice }
        if conditions[Warning.meetingNotUsingMic.slot] != nil { return .meetingNotUsingMic }
        return nil
    }

    /// The voice capsule: the current speaking mode, independent of the issue slot. nil
    /// outside a session.
    public var voiceState: VoiceState? {
        guard meetingActive else { return nil }
        return VoiceState.resolve(audio: meetingAudio, scene: scene, phoneInputConfirmed: phoneInputConfirmed,
                                  playing: outputPlaying, pushToTalk: pushToTalk,
                                  risk: scene == .video ? nil : voiceRisk)
    }

    /// The keycap and its action, using SpeechStatusPresentation.keyAction.
    public var titlebarKey: TitlebarKey? {
        guard meetingActive, scene != .video, let voice = voiceState else { return nil }
        var audio = meetingAudio
        if audio == nil {
            switch pushToTalk {
            case .holding: audio = .translating
            case .playing: audio = .draining
            case .idle: guard pushToTalkAvailable else { return nil }; audio = .original
            }
        }
        // Original audio alone is unavailable: the key keeps .original's start action.
        if case .unavailable = audio, translationKeyAvailable { audio = .original }
        let presentation = SpeechStatusPresentation(audio: audio,
            phoneInputConfirmed: scene == .phone ? phoneInputConfirmed : nil, playing: outputPlaying)
        return TitlebarKey.make(presentation, voice: voice)
    }

    /// Every active chip, most important first. Empty outside a session: the window has left in
    /// one step, and a late notice (系统麦克风已还原) must not bring a status strip back. The
    /// stored sys-input notices still show once the next session is active, within their 4 s.
    public func issueChips(now: Double) -> [HUDChip] {
        guard meetingActive else { return [] }
        var ranked: [(priority: Int, slot: String, chip: HUDChip)] = []
        func rank(_ chip: HUDChip) -> Int {
            switch chip.tone {
            case .risk: 10
            case .warn: 30
            case .notice: 75
            case .info: 85
            }
        }
        let warnings = Array(conditions.values) + notices.filter { $0.until > now }.map(\.warning)
        for warning in warnings {
            guard let chip = warning.chip(scene: scene) else { continue }
            ranked.append((chip.isProblem ? warning.compactPriority : rank(chip), warning.slot, chip))
        }
        if voiceState?.kind == .phoneLocalOnly {
            ranked.append((10, "phoneNotReceiving", .phoneNotReceiving))
        }
        for (key, chip) in externalIssues { ranked.append((rank(chip), "external." + key.rawValue, chip)) }
        if let message, message.until > now { ranked.append((rank(message.chip), "message", message.chip)) }
        var seen = Set<String>()
        return ranked.sorted { $0.priority == $1.priority ? $0.slot < $1.slot : $0.priority < $1.priority }
            .map(\.chip).filter { seen.insert($0.label + "\u{1F}" + $0.detail).inserted }
    }

    /// The titlebar slot beside the capsule: problem > notification > cloud privacy (§3). nil
    /// outside a session. `silenceInTimeline`: the empty meeting timeline already says
    /// "暂未听到对方声音", so the gray silence chip yields to the next chip (details keep it).
    public func issueSlot(now: Double, silenceInTimeline: Bool = false) -> IssueSlot? {
        guard meetingActive else { return nil }
        let silence = Warning.meetingSilent.chip(scene: scene)
        if let chip = issueChips(now: now).first(where: { !silenceInTimeline || $0 != silence }) {
            return .chip(chip)
        }
        return cloudPrivacyPending ? .cloudPrivacy : nil
    }

    /// The details popover's chip rows: every chip except those whose fact the popover's top
    /// row (the capsule's consequence) already states, so one fact is said once. "Phone 未接收"
    /// is only added in phoneLocalOnly, whose consequence says it; "会议未用 TalkTalk Mic"
    /// repeats the meetingNotUsingMic risk consequence. Settings destinations still come from
    /// `issueChips`.
    public func detailChips(now: Double) -> [HUDChip] {
        let notUsingMic = voiceRisk == .meetingNotUsingMic ? Warning.meetingNotUsingMic.chip(scene: scene) : nil
        return issueChips(now: now).filter { $0 != .phoneNotReceiving && $0 != notUsingMic }
    }

    /// Supplemental lines for the details popover: playback queue, voice and translation
    /// source. Meter levels are stripped.
    public func activityDetails(now: Double) -> [HUDLine] {
        var out: [HUDLine] = []
        if meetingActive {
            // Speech text never goes into the popover; only queue/voice/source facts.
            switch pushToTalk {
            case let .holding(_, _, _, queued) where queued > 0:
                out.append(HUDLine(String(appLocalized: "待播 \(queued) 段"), .secondary))
            case .playing: out += pushToTalkLines()
            case .holding, .idle: break
            }
        }
        return out.map { var l = $0; l.level = nil; return l }
    }

    /// The HUD has something to draw (it is shown even while the subtitle panel is hidden).
    public func isVisible(now: Double) -> Bool { !lines(now: now).isEmpty || visibleTranscript(at: now) != nil }

    /// The next time `lines` changes by itself (a notice or a passthrough line expiring).
    public func nextExpiry(after now: Double) -> Double? {
        var ts = notices.map(\.until).filter { $0 > now }
        if let until = message?.until, until > now { ts.append(until) }
        if let until = transcriptUntil, until > now { ts.append(until) }
        switch passthrough {
        case let .closed(_, u) where u > now: ts.append(u)
        case let .refused(_, u) where u > now: ts.append(u)
        default: break
        }
        return ts.min()
    }

    func passthroughLine(now: Double) -> HUDLine? {
        switch passthrough {
        case .none:
            return nil
        case .waiting:
            return HUDLine(String(appLocalized: "原声 · 等这句说完"), .red)
        case let .open(level, secondsLeft):
            if let s = secondsLeft {
                return HUDLine(String(appLocalized: "原声 · 对方正在听你说 · 还剩 \(s) s"), .redBanner, level: level)
            }
            return HUDLine(String(appLocalized: "原声 · 对方正在听你说"), .redBanner, level: level)
        case let .closed(reason, until):
            guard now < until else { return nil }
            if let reason { return HUDLine(String(appLocalized: "原声已关闭：\(reason)")) }
            return HUDLine(String(appLocalized: "原声已关闭"))
        case let .refused(reason, until):
            guard now < until else { return nil }
            return HUDLine(reason, .secondary)
        }
    }

    func pushToTalkLines() -> [HUDLine] {
        switch pushToTalk {
        case .idle:
            return meetingAudio == nil ? [HUDLine(String(appLocalized: "点按右⌥开始翻译"), .secondary)] : []
        case let .holding(level, preview, committed, queued):
            var out = [HUDLine(String(appLocalized: "正在识别中文"), .normal, level: level)]
            if transcript == nil {
                out += committed.map { HUDLine("✓ " + $0, .check) }
                if !preview.isEmpty { out.append(HUDLine(preview, .secondary)) }
            }
            if queued > 0 { out.append(HUDLine(String(appLocalized: "待播 \(queued) 段"), .secondary)) }
            return out
        case let .playing(lang, voice, source, queued):
            var out = [HUDLine(String(appLocalized: "正在播放译音（\(lang.title)）")), HUDLine(voice.text, .secondary)]
            switch source {
            case .openAI: out.append(HUDLine("OpenAI", .secondary))
            case .apple: out.append(HUDLine(String(appLocalized: "Apple 翻译"), .secondary))
            }
            if queued > 0 { out.append(HUDLine(String(appLocalized: "待播 \(queued) 段"), .secondary)) }
            return out
        }
    }
}

/// At most one HUD redraw per `minInterval` (§11: ≤2 per second). A request inside the interval
/// is deferred to its end; requests already deferred are merged.
public struct RefreshLimiter: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case now
        case at(Double)
        /// A deferred redraw is already scheduled; it will pick this change up.
        case merged
    }

    public let minInterval: Double
    private var lastRender: Double?
    private var scheduled: Double?

    public init(minInterval: Double = 0.5) { self.minInterval = minInterval }

    public mutating func request(now: Double) -> Decision {
        if scheduled != nil { return .merged }
        guard let last = lastRender, now - last < minInterval else { return .now }
        let t = last + minInterval
        scheduled = t
        return .at(t)
    }

    public mutating func didRender(now: Double) {
        lastRender = now
        scheduled = nil
    }
}
