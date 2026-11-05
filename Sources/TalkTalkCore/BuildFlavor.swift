import Foundation

/// Which app build is running, by bundle id (§2.2): TalkTalk.app or TalkTalk-Dev.app.
/// Anything else (a bare binary from `swift build`) is `.bare`: it has no bundle id, so TCC and
/// the driver's Feed gate treat it as a different program.
public enum BuildFlavor: String, Sendable {
    case release = "com.aaajiao.talktalk"
    case dev = "com.aaajiao.talktalk.dev"
    case bare = "bare"

    public static var current: BuildFlavor {
        BuildFlavor(rawValue: Bundle.main.bundleIdentifier ?? "") ?? .bare
    }
}
