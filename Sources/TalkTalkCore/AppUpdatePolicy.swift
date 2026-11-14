/// Work that must finish before an app update may interrupt this process. Checking and
/// restarting both use a fresh snapshot; merely becoming idle never authorizes a restart.
public struct AppUpdateActivity: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case session, voice, maintenance, diagnostics, onboarding, exporting, calibration
    }

    public var session: Bool
    public var voice: Bool
    public var maintenance: Bool
    public var diagnostics: Bool
    public var onboarding: Bool
    public var exporting: Bool
    public var calibration: Bool

    public init(session: Bool = false, voice: Bool = false, maintenance: Bool = false,
                diagnostics: Bool = false, onboarding: Bool = false, exporting: Bool = false,
                calibration: Bool = false) {
        self.session = session
        self.voice = voice
        self.maintenance = maintenance
        self.diagnostics = diagnostics
        self.onboarding = onboarding
        self.exporting = exporting
        self.calibration = calibration
    }

    public var blockingReason: Reason? {
        if session { return .session }
        if voice { return .voice }
        if maintenance { return .maintenance }
        if diagnostics { return .diagnostics }
        if onboarding { return .onboarding }
        if exporting { return .exporting }
        if calibration { return .calibration }
        return nil
    }
}

public enum AppUpdatePolicy {
    /// The production bundle is the only update target. Smoke explicitly opts out even when
    /// it runs inside a release bundle; a bare binary or development app never starts Sparkle.
    public static func isEnabled(requested: Bool, bundleIdentifier: String?, isApplicationBundle: Bool) -> Bool {
        requested && isApplicationBundle && bundleIdentifier == BuildFlavor.release.rawValue
    }
}

/// A deferred installation needs a fresh user action. This state contains no clock, observer
/// or callback that could restart the application when unrelated work merely finishes.
public struct AppUpdateRelaunchState: Sendable, Equatable {
    public private(set) var pending = false
    public private(set) var relaunching = false

    public init() {}

    public func canResume(activity: AppUpdateActivity) -> Bool {
        pending && !relaunching && activity.blockingReason == nil
    }

    /// Returns true when Sparkle must hold its installation continuation.
    public mutating func shouldPostpone(activity: AppUpdateActivity) -> Bool {
        if pending { return true }
        if activity.blockingReason != nil {
            pending = true
            return true
        }
        relaunching = true
        return false
    }

    /// True authorizes one invocation of the continuation, exclusively after a user click.
    public mutating func requestResume(activity: AppUpdateActivity) -> Bool {
        guard canResume(activity: activity) else { return false }
        pending = false
        relaunching = true
        return true
    }

    /// Sparkle can resume an installation left by a previous process without repeating the
    /// postponement callback. Its final relaunch notification still arms the app's quit guard.
    public mutating func willRelaunch() {
        pending = false
        relaunching = true
    }

    public mutating func reset() {
        pending = false
        relaunching = false
    }
}
