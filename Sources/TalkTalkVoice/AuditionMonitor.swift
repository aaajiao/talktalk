// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

/// Where an audition is played (§9.2 step 7): the monitor output — headphones or the default
/// output — and **never** TalkTalk Mic / the Feed device. This protocol is the only playback seam
/// TalkTalkVoice has; nothing in this module references FeedOutput, ClauseQueue, PlayoutRing or
/// ringO (`scripts/check-audio-paths.sh` rule AP11 checks that statically).
///
/// The real implementation wraps rt-core's MonitorOutput (M2 phase 2). Until it lands the app uses
/// `UnavailableAuditionMonitor`, and the settings page says audition playback is not ready yet.
public protocol AuditionMonitor: Sendable {
    var isAvailable: Bool { get async }
    var unavailableReason: String? { get async }
    /// Plays 24 kHz mono samples to the end (or until `stop()`).
    func play(_ samples24k: [Float]) async throws
    func stop() async
}

public extension AuditionMonitor {
    var unavailableReason: String? { get async { await isAvailable ? nil : String(localized: "自听输出暂不可用") } }
}

public enum AuditionMonitorError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)
    /// Stopped before its end by something else: a cue, meeting mode, the output device going
    /// away or changing, a coreaudiod restart (the reason, in Chinese).
    case interrupted(String)

    public var description: String {
        switch self {
        case .unavailable(let why): String(localized: "自听输出不可用：\(why)")
        case .interrupted(let why): String(localized: "试听中断：\(why)")
        }
    }
}

/// Stand-in until MonitorOutput exists: never plays anything anywhere.
public struct UnavailableAuditionMonitor: AuditionMonitor {
    public init() {}
    public var isAvailable: Bool { get async { false } }
    public var unavailableReason: String? { get async { Self.reason } }
    public static var reason: String { String(localized: "自听输出还没有接上（M2 第 2 阶段）") }
    public func play(_ samples24k: [Float]) async throws { throw AuditionMonitorError.unavailable(Self.reason) }
    public func stop() async {}
}

/// Test double: records what would have been played.
public actor RecordingAuditionMonitor: AuditionMonitor {
    public private(set) var played: [[Float]] = []
    public private(set) var stops = 0

    public init() {}
    public var isAvailable: Bool { get async { true } }
    public func play(_ samples24k: [Float]) async throws { played.append(samples24k) }
    public func stop() async { stops += 1 }
}
