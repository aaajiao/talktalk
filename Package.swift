// swift-tools-version:6.2
// talktalk (ARCHITECTURE.md §2.2, §13). Sparkle is pinned; no SwiftPM resources.
// M0 contains only what the benchmarks need: the --bench entry points, KeychainSecret,
// the audio process listing used by M0-T0, and the generated engine pins.
import PackageDescription

let package = Package(
    name: "TalkTalk",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "TalkTalk", targets: ["TalkTalkApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Test-only filesystem scopes; never linked into the application.
        .target(name: "TalkTalkTestSupport", path: "Tests/TalkTalkTestSupport"),
        .testTarget(name: "TalkTalkTestSupportTests", dependencies: ["TalkTalkTestSupport"]),
        .target(name: "TalkTalkCore"),
        .target(name: "TalkTalkCloud", dependencies: ["TalkTalkCore"]),
        .target(name: "TalkTalkAudio", dependencies: ["TalkTalkCore", "CAudioCore"]),
        .executableTarget(
            name: "TalkTalkApp",
            dependencies: ["TalkTalkCore", "TalkTalkCloud", "TalkTalkAudio", "TalkTalkVoice", "TalkTalkApple", "TalkTalkCloudUI", "TalkTalkSession",
                           "TalkTalkEngineHost", "TalkTalkDriverSupport", "TalkTalkSettingsUI",
                           .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
            // The dev-only entry points (--bench store-key) compile only with -DTALKTALK_DEV,
            // which scripts/build-app.sh passes for TalkTalk-Dev.app and never for TalkTalk.app.
        ),
        .testTarget(name: "TalkTalkCoreTests", dependencies: ["TalkTalkCore", "TalkTalkTestSupport"]),
        // Settings visual system (docs/decisions/2026-11-06-settings-visual-system.md §3.0): the
        // status vocabulary, icon buttons, fact chips, section headers and row style, the card
        // navigation and ReturnPill, and the subtitle window's own capsule, keycap and style
        // factories, shared by the app, the cloud settings, the driver page and enrollment. Core
        // only: no session state.
        .target(name: "TalkTalkSettingsUI", dependencies: ["TalkTalkCore"]),
        .testTarget(name: "TalkTalkSettingsUITests", dependencies: ["TalkTalkSettingsUI"]),
        .testTarget(name: "TalkTalkCloudTests", dependencies: ["TalkTalkCloud"]),
        // m0-voice: real-time C core (§2.2: [[clang::nonblocking]] checked by -Wfunction-effects) and
        // the "my voice" enrollment (§9, §13).
        .target(
            name: "CAudioCore",
            cSettings: [.unsafeFlags(["-Wfunction-effects", "-Werror=function-effects"])],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // voice-m2: the engine half of enrollment (build/load/audition/read-back) talks to the engine host.
        .target(name: "TalkTalkVoice", dependencies: ["TalkTalkCore", "TalkTalkAudio", "TalkTalkEngineHost", "TalkTalkSettingsUI"]),
        .testTarget(name: "TalkTalkAudioTests", dependencies: ["TalkTalkAudio", "CAudioCore"]),
        .testTarget(name: "TalkTalkVoiceTests", dependencies: ["TalkTalkVoice", "TalkTalkAudio", "TalkTalkCore", "TalkTalkEngineHost", "TalkTalkTestSupport"]),
        // m0-swift: Apple SpeechAnalyzer / Translation wrappers and the T10/T11 benches (§13).
        .target(name: "TalkTalkApple", dependencies: ["TalkTalkCore"]),
        .testTarget(name: "TalkTalkAppleTests", dependencies: ["TalkTalkApple", "TalkTalkCore"]),
        // m0-swift: Settings › 翻译 (§11), a reusable SwiftUI view the M1 settings window embeds.
        .target(name: "TalkTalkCloudUI", dependencies: ["TalkTalkCore", "TalkTalkCloud", "TalkTalkSettingsUI"]),
        .testTarget(name: "TalkTalkCloudUITests", dependencies: ["TalkTalkCloudUI", "TalkTalkCloud", "TalkTalkCore",
                                                                "TalkTalkSettingsUI"]),
        // m1-listen: MeetingSession (auto-end, sleep suspend) and ListenPipeline (§13).
        .target(name: "TalkTalkSession", dependencies: ["TalkTalkCore", "TalkTalkAudio", "TalkTalkApple"]),
        .testTarget(name: "TalkTalkSessionTests", dependencies: ["TalkTalkSession", "TalkTalkCore", "TalkTalkAudio"]),
        // m1-engine: the engine host (§7.3–§7.6, §13): EngineProcess, PosixSpawnLauncher,
        // ServerHandshake, EngineClient, EnginePaths, EngineInstaller, ServerLog.
        .target(name: "TalkTalkEngineHost", dependencies: ["TalkTalkCore"]),
        .testTarget(name: "EngineHostTests", dependencies: ["TalkTalkEngineHost", "TalkTalkCore", "TalkTalkTestSupport"],
                    exclude: ["Fixtures"]),
        .testTarget(name: "InstallerTests", dependencies: ["TalkTalkEngineHost", "TalkTalkTestSupport"]),
        // m2 sysinput: default-input switch, record, lock and guard (§8.6). Fake-HAL tests always run;
        // the on-device ones (they change the real default input) only with TALKTALK_TEST_AUDIO=1.
        .testTarget(name: "SysInputTests", dependencies: ["TalkTalkAudio", "TalkTalkCore", "TalkTalkTestSupport"]),
        // m2 driver: DriverInstallation, DriverInstaller, the driver self-test and FullUninstaller
        // (§8.4, §13), plus the settings › 组件 driver section. CDriverSelfTest holds the self-test
        // IOProcs (real-time C, checked like CAudioCore). DriverTests: the on-device cases run only
        // with TALKTALK_TEST_DRIVER=1.
        .target(
            name: "CDriverSelfTest",
            cSettings: [.unsafeFlags(["-Wfunction-effects", "-Werror=function-effects"])],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .target(name: "TalkTalkDriverSupport",
                dependencies: ["TalkTalkCore", "TalkTalkAudio", "TalkTalkEngineHost", "TalkTalkCloud", "CDriverSelfTest",
                               "TalkTalkSettingsUI"]),
        .testTarget(name: "DriverTests", dependencies: ["TalkTalkDriverSupport", "TalkTalkAudio", "TalkTalkCore", "TalkTalkEngineHost",
                                                     "TalkTalkSettingsUI", "CDriverSelfTest"]),
    ],
    swiftLanguageModes: [.v6]
)
