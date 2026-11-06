// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// The microphone status dock under the meeting/phone timeline (redesign §4, §5). It reads
/// the same `VoiceState` as the titlebar capsule; this only decides its words, colours and
/// curve. Capture is a local fact: the curve never says that anything reached the other side.
public struct MicDockPresentation: Sendable, Equatable {
    /// Colour of the icon, the state text and the curve.
    public enum Tone: Sendable, Equatable { case original, translate, neutral, warn, risk }

    public enum Wave: Sendable, Equatable {
        /// Measured RMS curve.
        case solid
        /// Key held down (switching): a thinner, fainter curve.
        case outlined
        /// Translated audio is draining: 1 pt dashed.
        case dashed
        /// Nothing is being sent: the curve stays flat while input is valid.
        case flat
        /// Risk or unavailable audio: no curve at all.
        case none
    }

    /// Background treatment of the whole dock.
    public enum Emphasis: Sendable, Equatable {
        case none
        /// risk 18% fill with a 3 pt red bar at the leading edge.
        case risk
        /// warn 15% fill.
        case unavailable
    }

    /// The button that replaces the keycap; both open the details popover.
    public enum Action: Sendable, Equatable {
        case fix, details
        public var title: String {
            switch self {
            case .fix: String(localized: "修复…")
            case .details: String(localized: "详情")
            }
        }
    }

    public var kind: VoiceState.Kind
    public var symbol: String
    /// 13 pt semibold in the tone colour; also the compact 28 pt dock's short label.
    public var label: String
    /// 12 pt, white 60%.
    public var consequence: String?
    public var tone: Tone
    public var wave: Wave
    public var emphasis: Emphasis
    public var action: Action?
    /// Idle states may add the "点按 右⌥ 开始翻译你的发言" hint while the timeline is empty.
    public var allowsStartHint: Bool

    public var accessibilityLabel: String {
        consequence.map { String(localized: "麦克风：\(label)，\($0)") } ?? String(localized: "麦克风：\(label)")
    }

    public static var startHint: String { String(localized: "点按 右⌥ 开始翻译你的发言") }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public static func make(_ voice: VoiceState, scene: SubtitleScene) -> MicDockPresentation {
        let phone = scene == .phone
        var label: String
        var consequence: String?
        var tone: Tone = .neutral
        var wave: Wave = .flat
        var emphasis: Emphasis = .none
        var action: Action?
        var hint = false
        switch voice.kind {
        case .original:
            label = String(localized: "原声"); tone = .original; wave = .solid; hint = true
            // Phone: a confirmed reader proves that Phone reads TalkTalk Mic, not that the other
            // person hears it (本机就绪 ≠ Phone 已接收 ≠ 对方听到).
            consequence = phone ? String(localized: "正在送入 Phone") : String(localized: "对方能听到你")
        case .translating:
            label = String(localized: "翻译中"); consequence = String(localized: "原声已关")
            tone = .translate; wave = .solid
        case .processing:
            // Draining without actual Feed playback is processing, never "播放".
            label = String(localized: "译音处理中"); consequence = String(localized: "原声已关")
            tone = .translate; wave = .dashed
        case .playingTranslation:
            label = phone ? String(localized: "译音已送入 Phone") : String(localized: "译音播放中")
            consequence = String(localized: "原声已关")
            tone = .translate; wave = .dashed
        case .switching:
            label = String(localized: "松开 右⌥ 确认"); tone = .translate; wave = .outlined
        case .restoring:
            label = String(localized: "正在恢复原声…"); wave = .flat; hint = true
        case .notSent:
            label = String(localized: "未发送"); consequence = String(localized: "对方听不到你"); hint = true
        case .phoneNotConnected:
            label = String(localized: "电话同传已就绪"); consequence = String(localized: "接通后对方才能听到你"); hint = true
        case .phoneLocalTrial:
            label = String(localized: "本机试说"); consequence = String(localized: "Phone 未接收"); wave = .solid
        case .phoneLocalOnly:
            label = String(localized: "译音只在本机播放"); consequence = String(localized: "Phone 没有读取 TalkTalk Mic")
            tone = .warn; wave = .dashed
        case .phoneReconnecting:
            label = String(localized: "当前发言已停止"); consequence = String(localized: "等待 Phone")
        case .remoteHearsOriginal:
            label = String(localized: "对方能听到原声"); consequence = String(localized: "会议没有使用 TalkTalk Mic")
            tone = .risk; wave = .none; emphasis = .risk; action = .fix
        case .unavailable:
            label = String(localized: "音频不可用"); consequence = String(localized: "未发送")
            tone = .warn; wave = .none; emphasis = .unavailable; action = .details
        case .listening:
            // Video has no dock; kept total for previews.
            label = voice.title; consequence = voice.consequence; wave = .none
        }
        return MicDockPresentation(kind: voice.kind, symbol: voice.symbol, label: label, consequence: consequence,
                                   tone: tone, wave: wave, emphasis: emphasis, action: action, allowsStartHint: hint)
    }
}

/// Speaking expansion of the dock (§4 发言态): from the translation latch until pending speech
/// work has ended plus 3 seconds. When it collapses, the turn becomes a timeline row.
public struct SpeakingDockPhase: Sendable, Equatable {
    public static let lingerSeconds: Double = 3
    public private(set) var isExpanded = false
    private var lingerUntil: Double?

    public init() {}

    /// The turn is live: latched translation, draining, pending speech work, or (without a raw
    /// gate) actual capture/playback. A key press only keeps an open turn; a new press waits
    /// for its latch.
    public static func isActive(audio: HUDModel.MeetingAudio?, pushToTalk: HUDModel.PushToTalk,
                                workPending: Bool, expanded: Bool) -> Bool {
        if workPending { return true }
        switch audio {
        case .translating?, .draining?: return true
        case .switching?: return expanded
        case nil:
            switch pushToTalk {
            case .holding, .playing: return true
            case .idle: return false
            }
        default: return false
        }
    }

    /// Returns whether the dock is expanded at `now`.
    @discardableResult
    public mutating func update(active: Bool, now: Double) -> Bool {
        if active {
            isExpanded = true
            lingerUntil = nil
        } else if isExpanded {
            if let until = lingerUntil {
                if now >= until { isExpanded = false; lingerUntil = nil }
            } else {
                lingerUntil = now + Self.lingerSeconds
            }
        }
        return isExpanded
    }

    /// When the linger ends by itself.
    public var nextChange: Double? { isExpanded ? lingerUntil : nil }

    public mutating func reset() { isExpanded = false; lingerUntil = nil }
}

/// The dock curve's input (§4): the existing RMS mapping, flat below −50 dB, removed after
/// 250 ms without valid input or as soon as capture stops. It never animates by itself.
public struct MicWaveSignal: Sendable, Equatable {
    public static let staleSeconds: Double = 0.25
    public static let flatBelowDecibels: Double = -50
    /// Peak amplitude in points.
    public static let maxAmplitude: Double = 10
    public static let lineWidth: Double = 1.5
    public static let dashedLineWidth: Double = 1
    /// Curve colour: the voice-state colour at 55%.
    public static let colorAlpha: Double = 0.55

    public enum State: Sendable, Equatable {
        case removed
        /// Valid input below −50 dB.
        case flat
        /// Normalized level, 0 < value ≤ 1.
        case level(Double)
    }

    public private(set) var state: State = .removed
    private var lastValidAt: Double?

    public init() {}

    /// A level of nil or a non-finite value is not valid input. Returns true if the drawn
    /// state changed.
    @discardableResult
    public mutating func feed(_ rms: Float?, now: Double) -> Bool {
        let old = state
        if let rms, rms.isFinite, rms >= 0 {
            lastValidAt = now
            let value = Self.normalized(rms)
            state = value > 0 ? .level(value) : .flat
        } else if let last = lastValidAt, now - last < Self.staleSeconds {
            // Keep the last measurement during the 250 ms grace; never invent a new one.
        } else {
            state = .removed
            lastValidAt = nil
        }
        return state != old
    }

    /// Removes a curve whose last valid input is older than 250 ms.
    @discardableResult
    public mutating func expire(now: Double) -> Bool {
        guard let last = lastValidAt, now - last >= Self.staleSeconds else { return false }
        return stop()
    }

    /// Capture closed, window hidden or minimized: removed at once.
    @discardableResult
    public mutating func stop() -> Bool {
        let changed = state != .removed
        state = .removed
        lastValidAt = nil
        return changed
    }

    public var expiresAt: Double? { lastValidAt.map { $0 + Self.staleSeconds } }

    /// 0…1 from RMS: (dB + 60) / 60 as before, 0 below −50 dB.
    public static func normalized(_ rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(Double(rms))
        guard decibels >= flatBelowDecibels else { return 0 }
        return min(1, max(0, (decibels + 60) / 60))
    }

    public var amplitude: Double {
        if case let .level(value) = state { return value * Self.maxAmplitude }
        return 0
    }
}
