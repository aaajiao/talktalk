// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// One line of the push-to-talk HUD (ARCHITECTURE.md §11 按键说话 HUD).
public struct HUDLine: Sendable, Equatable {
    public enum SettingsDestination: Sendable, Equatable { case audio, translation, permissions }
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

/// One stable status on the meeting surface; detailed activity is shown only on request.
public struct HUDStatusPresentation: Sendable, Equatable {
    public var summary: HUDLine
    public var details: [HUDLine]

    public init(summary: HUDLine, details: [HUDLine]) {
        self.summary = summary
        self.details = details
    }
}

/// Everything the HUD shows, as a pure function of what it was told and the time (seconds on a
/// monotonic clock). No AppKit; the panel (`PTTHUD`) only draws `lines(now:)`.
///
/// M1 uses `warnings` (LISTEN's hints when the subtitle panel is hidden, the OpenAI fallbacks).
/// Actual meeting audio state comes from the raw gate and SPEAK lifecycle, never inferred from
/// a meeting merely being active. The legacy passthrough event API remains for isolated uses.
public struct HUDModel: Sendable, Equatable {
    // MARK: inputs

    /// The §11 warnings, plus LISTEN's own two hints and the first-meeting passthrough tip.
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
        /// First meeting only (the caller keeps the "shown once" flag).
        case passthroughTip

        public var text: String {
            switch self {
            case .meetingNotUsingMic: String(localized: "会议没用 TalkTalk Mic")
            case .remoteHearsYourVoice: String(localized: "会议正在用实体麦，对方仍可能听到原声；按键翻译已停用")
            case let .floorPaused(n): String(localized: "对方在说话 · 已暂停 \(n) 段")
            case let .numberMaybeWrong(s): String(localized: "数字可能有误：\(s)")
            case let .skipped(n): String(localized: "已跳过 \(n) 段")
            case .segmentNotSent: String(localized: "这段未发送")
            case .sentenceMaybeIncomplete: String(localized: "该句可能不完整")
            case .unsupportedTextNotSent: String(localized: "这段文字暂不支持，未发送")
            case .speakerMode: String(localized: "正在外放，请戴耳机")
            case .audioRestarting: String(localized: "音频系统重启中")
            case .meetingSilent: String(localized: "会议当前没有声音")
            case .meetingSeemsOver: String(localized: "会议似乎已结束")
            case .tccUnconfirmed: String(localized: "没能确认系统录音权限")
            case let .defaultInputChanged(x): String(localized: "系统默认输入被改成了 \(x)")
            case let .switchedBackAfterInsert(x): String(localized: "\(x) 接入后系统换了默认输入，已切回 TalkTalk Mic")
            case let .switchBackFailed(x): String(localized: "没能切回 TalkTalk Mic，系统默认输入是 \(x)")
            case let .defaultInputRestored(x): String(localized: "默认输入已还原为 \(x)")
            case let .defaultInputRestoredElsewhere(x, o, missing):
                missing ? String(localized: "默认输入已还原为 \(x)（原来的 \(o) 不在了）")
                        : String(localized: "默认输入已还原为 \(x)（原来的 \(o) 是虚拟设备，不还原到它）")
            case let .defaultInputNotSwitched(issue): issue.text
            case .openAIUnreachable: String(localized: "OpenAI 暂时连不上，改用 Apple 翻译")
            case .openAIKeyInvalid: String(localized: "OpenAI key 无效或额度用完，已改用 Apple 翻译")
            case .modelRetired: String(localized: "所选模型已下线，已换回 gpt-6-luna")
            case .passthroughTip: String(localized: "会议默认传原声；点按右⌥开始翻译，再按结束，译音播完后恢复原声")
            }
        }

        public var style: HUDLine.Style {
            switch self {
            case .meetingNotUsingMic, .remoteHearsYourVoice: .red
            case .switchedBackAfterInsert, .defaultInputRestored, .defaultInputRestoredElsewhere, .passthroughTip,
                 .meetingSilent, .meetingSeemsOver: .normal
            default: .yellow
            }
        }

        /// Compact status for the meeting surface. Device names and technical explanations
        /// stay in `text`; safety consequences are never hidden behind the details control.
        public var summary: String {
            switch self {
            case .remoteHearsYourVoice: String(localized: "会议仍会发送原声 · 翻译已停用")
            case let .floorPaused(n): String(localized: "对方在说话 · 已暂停 \(n) 段")
            case .numberMaybeWrong: String(localized: "译文数字待核对")
            case .defaultInputChanged: String(localized: "系统麦克风已变化")
            case .switchedBackAfterInsert: String(localized: "已恢复 TalkTalk Mic")
            case .switchBackFailed: String(localized: "切换麦克风失败")
            case .defaultInputRestored: String(localized: "系统麦克风已还原")
            case .defaultInputRestoredElsewhere: String(localized: "已还原到其他实体麦克风")
            case .defaultInputNotSwitched(let issue):
                switch issue {
                case .micMissing: String(localized: "未找到 TalkTalk Mic")
                case .noPhysicalInput: String(localized: "未找到实体麦克风")
                case .writeFailed: String(localized: "系统麦克风切换失败")
                case .recordWriteFailed, .guardLaunchFailed: String(localized: "麦克风还原准备失败")
                case .micNotSelectable: String(localized: "TalkTalk Mic 暂不可选")
                }
            case .openAIUnreachable: String(localized: "OpenAI 暂时不可用 · 已用 Apple")
            case .openAIKeyInvalid: String(localized: "OpenAI key 或额度异常 · 已用 Apple")
            case .modelRetired: String(localized: "翻译模型已更换")
            case .passthroughTip: String(localized: "点按右⌥开始或结束翻译")
            default: text
            }
        }

        public var symbol: String {
            switch self {
            case .meetingNotUsingMic, .remoteHearsYourVoice: "mic.slash"
            case .speakerMode: "headphones"
            case .audioRestarting: "arrow.clockwise"
            case .meetingSilent, .meetingSeemsOver: "waveform"
            case .tccUnconfirmed: "lock.shield"
            case .defaultInputChanged, .switchBackFailed, .defaultInputNotSwitched: "mic.badge.xmark"
            case .switchedBackAfterInsert, .defaultInputRestored, .defaultInputRestoredElsewhere: "checkmark.circle"
            case .openAIUnreachable, .openAIKeyInvalid, .modelRetired: "network"
            case .floorPaused: "pause.circle"
            case .numberMaybeWrong, .sentenceMaybeIncomplete: "exclamationmark.triangle"
            case .skipped, .segmentNotSent, .unsupportedTextNotSent: "nosign"
            case .passthroughTip: "keyboard"
            }
        }

        public var line: HUDLine {
            let destination: HUDLine.SettingsDestination? = switch self {
            case .meetingNotUsingMic, .remoteHearsYourVoice, .speakerMode, .defaultInputChanged,
                 .switchBackFailed, .defaultInputNotSwitched: .audio
            case .openAIUnreachable, .openAIKeyInvalid, .modelRetired: .translation
            case .tccUnconfirmed: .permissions
            default: nil
            }
            return HUDLine(summary, style, detail: summary == text ? nil : text,
                           symbol: symbol, settingsDestination: destination)
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
            case .speakerMode: 23
            case .defaultInputChanged: 24
            case .floorPaused: 25
            case .openAIKeyInvalid: 26
            case .openAIUnreachable: 27
            case .modelRetired: 28
            case .meetingSilent, .meetingSeemsOver, .switchedBackAfterInsert,
                 .defaultInputRestored, .defaultInputRestoredElsewhere, .passthroughTip: 90
            }
        }

        /// Conditions stay until cleared; notices fade after `noticeSeconds`.
        public var isCondition: Bool {
            switch self {
            case .meetingNotUsingMic, .remoteHearsYourVoice, .floorPaused, .speakerMode, .audioRestarting,
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
            case .mine: String(localized: "我的声音")
            case .fallbackModel: String(localized: "备用模型")
            case .system: String(localized: "系统声音")
            }
        }
    }

    public enum MTSource: Sendable, Equatable { case openAI, apple }

    /// Set only by the real raw-audio gate / translate-and-drain lifecycle. `nil` means the
    /// caller is not using default-original meeting audio (for example the isolated demo).
    public enum MeetingAudio: Sendable, Equatable {
        case original
        /// The physical key is down; its clean release confirms the recording-mode change.
        case switching
        case translating
        case draining
        /// Translation is finished and healthy routing is awaiting the next confirmed gate open.
        case restoringOriginal
        /// The raw gate is closed, including a translation press that was refused.
        case unavailable(reason: String)

        public var text: String {
            switch self {
            case .original: String(localized: "原声发送中 · 点按右⌥开始翻译")
            case .switching: String(localized: "正在切换发言方式")
            case .translating: String(localized: "翻译收音中 · 再按右⌥结束（原声已关闭）")
            case .draining: String(localized: "译音处理中 · 播完后恢复原声")
            case .restoringOriginal: String(localized: "正在恢复原声")
            case let .unavailable(reason): String(localized: "TalkTalk 音频暂不可用：\(reason)")
            }
        }

        /// Always visible beside a warning: a problem summary must not hide the audio mode.
        public var modeBadge: HUDLine {
            switch self {
            case .original: HUDLine(String(localized: "原声发送中"), .check, symbol: "mic.fill")
            case .switching: HUDLine(String(localized: "切换中"), .secondary, symbol: "arrow.left.arrow.right")
            case .translating: HUDLine(String(localized: "翻译收音中"), symbol: "waveform")
            case .draining: HUDLine(String(localized: "译音处理中"), .secondary, symbol: "speaker.wave.2.fill")
            case .restoringOriginal: HUDLine(String(localized: "恢复原声"), .secondary, symbol: "arrow.clockwise")
            case .unavailable: HUDLine(String(localized: "待检查"), .yellow, symbol: "exclamationmark.triangle")
            }
        }

        /// The action or consequence shown alongside the mode when no warning takes priority.
        public var operationHint: String? {
            switch self {
            case .original: String(localized: "点按右⌥开始翻译")
            case .switching: String(localized: "松开右⌥确认")
            case .translating: String(localized: "再按右⌥结束 · 原声已关闭")
            case .draining: String(localized: "播完后恢复原声")
            case .restoringOriginal: String(localized: "请稍候")
            case .unavailable: nil
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
    public private(set) var transcript: SpeakTranscript?
    public var speechWorkPending = false
    private var latestTranscriptPress: UInt64?
    private var transcriptUntil: Double?
    private(set) var passthrough: Passthrough = .none
    private var conditions: [String: Warning] = [:]
    private var conditionOrder: [String] = []
    private var notices: [(warning: Warning, until: Double)] = []
    private var shownThisMeeting: Set<String> = []

    public init() {}

    public static func == (a: HUDModel, b: HUDModel) -> Bool {
        a.meetingActive == b.meetingActive && a.pushToTalk == b.pushToTalk && a.pushToTalkAvailable == b.pushToTalkAvailable
            && a.meetingAudio == b.meetingAudio
            && a.transcript == b.transcript && a.transcriptUntil == b.transcriptUntil
            && a.speechWorkPending == b.speechWorkPending
            && a.latestTranscriptPress == b.latestTranscriptPress
            && a.passthrough == b.passthrough
            && a.conditions == b.conditions && a.conditionOrder == b.conditionOrder
            && a.notices.map(\.warning) == b.notices.map(\.warning) && a.notices.map(\.until) == b.notices.map(\.until)
            && a.shownThisMeeting == b.shownThisMeeting
    }

    // MARK: updates

    public mutating func meetingStarted() {
        meetingActive = true
        shownThisMeeting = []
        notices.removeAll { !$0.warning.isSysInput }
        pushToTalk = .idle
        meetingAudio = nil
        transcript = nil; latestTranscriptPress = nil; transcriptUntil = nil; speechWorkPending = false
    }

    public mutating func meetingEnded() {
        meetingActive = false
        conditions = [:]
        conditionOrder = []
        notices.removeAll { !$0.warning.isSysInput }
        pushToTalk = .idle
        meetingAudio = nil
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
            case .original, .switching, .translating, .draining, .restoringOriginal: .normal
            case .unavailable: .yellow
            }
            if case .unavailable = audio {
                out.append(HUDLine(String(localized: "音频暂不可用"), style,
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

    /// Presentation only: no delay, latching or rotation. The actual gate owns normal progress;
    /// every warning and supplemental line remains available in the deduplicated details.
    public func compactStatus(now: Double, extraLines: [HUDLine] = []) -> HUDStatusPresentation? {
        var details: [HUDLine] = []
        func addDetail(_ line: HUDLine) {
            // Ignore meter differences and decorative symbols when merging the same explanation.
            guard !details.contains(where: {
                $0.text == line.text && $0.style == line.style && $0.detail == line.detail
                    && $0.settingsDestination == line.settingsDestination
            }) else { return }
            details.append(line)
        }
        (lines(now: now) + extraLines).forEach(addDetail)

        var selected: (priority: Int, line: HUDLine)?
        func consider(_ line: HUDLine, priority: Int) {
            if selected == nil || priority < selected!.priority { selected = (priority, line) }
        }
        let warnings = Array(conditions.values) + notices.filter { $0.until > now }.map(\.warning)
        for warning in warnings.sorted(by: {
            $0.compactPriority == $1.compactPriority ? $0.slot < $1.slot : $0.compactPriority < $1.compactPriority
        }) {
            var line = warning.line
            switch warning {
            case .floorPaused: line.text = String(localized: "对方在说话 · 译音已暂停")
            case .skipped: line.text = String(localized: "部分内容已跳过")
            default: break
            }
            consider(line, priority: warning.compactPriority)
        }
        for line in extraLines {
            let priority: Int = switch line.style {
            case .red, .redBanner: 10
            case .yellow: 30
            case .normal, .secondary, .check: 90
            }
            consider(line, priority: priority)
        }

        if let audio = meetingAudio, meetingActive {
            let line: HUDLine
            if case .unavailable = audio {
                line = HUDLine(String(localized: "音频暂不可用"), .yellow, detail: audio.text,
                               symbol: "exclamationmark.triangle")
                consider(line, priority: 20)
            } else {
                line = HUDLine(audio.text, symbol: audio.modeBadge.symbol)
                consider(line, priority: 80)
            }
            // Legacy `lines` suppresses generic unavailable beside the physical-mic warning.
            // Keep its full reason in details even when that more urgent warning wins here.
            addDetail(line)
        } else {
            if var legacy = passthroughLine(now: now) {
                if case .open = passthrough {
                    legacy.text = String(localized: "原声 · 对方正在听你说")
                }
                consider(legacy, priority: 70)
            }
            switch pushToTalk {
            case .holding, .playing:
                consider(HUDLine(String(localized: "按键翻译中"), symbol: "waveform"), priority: 80)
                pushToTalkLines().forEach(addDetail)
            case .idle:
                if meetingActive {
                    let line = HUDLine(String(localized: "正在收听"), symbol: "waveform")
                    consider(line, priority: 80)
                    addDetail(line)
                }
            }
        }
        guard var summary = selected?.line else { return nil }
        summary.level = nil
        summary.detail = nil
        return HUDStatusPresentation(summary: summary, details: details)
    }

    /// The HUD has something to draw (it is shown even while the subtitle panel is hidden).
    public func isVisible(now: Double) -> Bool { !lines(now: now).isEmpty || visibleTranscript(at: now) != nil }

    /// The next time `lines` changes by itself (a notice or a passthrough line expiring).
    public func nextExpiry(after now: Double) -> Double? {
        var ts = notices.map(\.until).filter { $0 > now }
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
            return HUDLine(String(localized: "原声 · 等这句说完"), .red)
        case let .open(level, secondsLeft):
            if let s = secondsLeft {
                return HUDLine(String(localized: "原声 · 对方正在听你说 · 还剩 \(s) s"), .redBanner, level: level)
            }
            return HUDLine(String(localized: "原声 · 对方正在听你说"), .redBanner, level: level)
        case let .closed(reason, until):
            guard now < until else { return nil }
            if let reason { return HUDLine(String(localized: "原声已关闭：\(reason)")) }
            return HUDLine(String(localized: "原声已关闭"))
        case let .refused(reason, until):
            guard now < until else { return nil }
            return HUDLine(reason, .secondary)
        }
    }

    func pushToTalkLines() -> [HUDLine] {
        switch pushToTalk {
        case .idle:
            return meetingAudio == nil ? [HUDLine(String(localized: "点按右⌥开始翻译"), .secondary)] : []
        case let .holding(level, preview, committed, queued):
            var out = [HUDLine(String(localized: "正在识别中文"), .normal, level: level)]
            if transcript == nil {
                out += committed.map { HUDLine("✓ " + $0, .check) }
                if !preview.isEmpty { out.append(HUDLine(preview, .secondary)) }
            }
            if queued > 0 { out.append(HUDLine(String(localized: "待播 \(queued) 段"), .secondary)) }
            return out
        case let .playing(lang, voice, source, queued):
            let code = lang.rawValue.uppercased()
            var out = [HUDLine(String(localized: "正在播放译音（\(code)）")), HUDLine(voice.text, .secondary)]
            switch source {
            case .openAI: out.append(HUDLine("OpenAI", .secondary))
            case .apple: out.append(HUDLine(String(localized: "Apple 本地翻译"), .secondary))
            }
            if queued > 0 { out.append(HUDLine(String(localized: "待播 \(queued) 段"), .secondary)) }
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
