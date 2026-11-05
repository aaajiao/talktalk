import Foundation
import TalkTalkAudio
import TalkTalkCore

// TalkTalk entry point (ARCHITECTURE.md §13).
//
//   TalkTalk                                           the menu bar app (single instance per flavor)
//   TalkTalk --smoke-ui [--out <file>]                 opens settings › 我的声音, reports, quits (no mic)
//   TalkTalk --list-audio-processes [--out <file>]     read-only Core Audio process objects (JSON)
//   TalkTalk --bench store-key --out <file>            dev build only (§7.7); run it through
//                                                      `open -W -n -a TalkTalk-Dev.app --args ...`
//   TalkTalk --version
//   TalkTalk --self-test [--engine] [--driver] [--voice] --out <file>   headless; one JSON line per part; exit 0/1/2 (§12.3, SelfTest.swift)
//   TalkTalk --sysinput-guard --lock-fd N            started by the app only (§8.6 layer 2)

let arguments = Array(CommandLine.arguments.dropFirst())

func argumentValue(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

/// Writes a bench result as JSON to --out (or stdout). Results never contain secrets or text.
func writeResult(_ object: [String: Any], to path: String?) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not encode result")
    }
    if let path {
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            fail("could not write \(path): \(error)")
        }
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

switch arguments.first {
case nil:
    AppDelegate.run()

case let first? where first.hasPrefix("-psn_"):   // old LaunchServices process serial number
    AppDelegate.run()

case "--smoke-ui":
    AppDelegate.run(smoke: true, smokeOut: argumentValue("--out"))

case "--version":
    #if TALKTALK_DEV
    let hooks = "dev hooks: store-key"
    #else
    let hooks = "dev hooks: none"
    #endif
    print("TalkTalk \(AppVersion.current.displayString) (engine API \(EnginePins.engineAPI), \(BuildFlavor.current.rawValue), \(hooks))")

case "--list-audio-processes":
    do {
        let list = try AudioProcessList.current()
        let resolver = MeetingSourceResolver()
        let rows: [[String: Any]] = list.map {
            let owner = resolver.ownerBundleID($0)
            return ["object_id": $0.objectID, "pid": $0.pid, "bundle_id": $0.bundleID ?? NSNull(),
                    "owner_bundle_id": owner ?? NSNull(),
                    "meeting_app": owner.flatMap(MeetingApp.named)?.name ?? NSNull(),
                    "running_input": $0.isRunningInput, "running_output": $0.isRunningOutput]
        }
        let candidates = resolver.candidates(list)
        let def = MeetingSourceResolver.defaultSource(candidates)
        writeResult(["processes": rows, "count": rows.count,
                     "meeting_candidates": candidates.map { ["app": $0.app.id, "object_ids": $0.objectIDs,
                                                             "running_input": $0.isRunningInput,
                                                             "running_output": $0.isRunningOutput] as [String: Any] },
                     "default_source": def?.app.id ?? NSNull(),
                     "responsibility_spi": MeetingSourceResolver.responsibilityAvailable],
                    to: argumentValue("--out"))
    } catch {
        fail("\(error)")
    }

case "--self-test":   // m1-engine: §12.3 (the engine part in M1)
    runSelfTest()

case "--bench":
    let sub = arguments.count > 1 ? arguments[1] : ""
    switch sub {
    case "store-key":
        #if TALKTALK_DEV
        BenchStoreKey.run(outPath: argumentValue("--out"))
        #else
        fail("--bench store-key exists only in the dev build (TalkTalk-Dev.app)")
        #endif
    case "enroll": runBenchEnroll()   // m0-voice: §9.2 "my voice" recording (dev build)
    case "record": runBenchRecord()   // m0-voice: T5/T17 test takes (dev build)
    case "cloud": runBenchCloud()     // m0-swift: T4 ⓪–⑨ (dev build)
    case "speech": runBenchSpeech()   // m0-swift: T10 SpeechAnalyzer (dev build)
    case "translation": runBenchTranslation()   // m0-swift: T11 Apple Translation (dev build)
    case "import-key": runBenchImportKey()   // m0-swift: copy the existing bench key into the dev item (dev build)
    case "tap": runBenchTap()         // m1-listen: T9 LISTEN half, during a real call (dev build)
    case "engine-restart": runBenchEngineRestart()   // m1-engine: kill -9 recovery, T13 / M1 (dev build)
    case "driver": runBenchDriver()   // m2 driver: install / uninstall / status / ttmm via DriverInstaller (dev build)
    case "feed": runBenchFeed()       // rt-core phase 2: FeedOutput on the real Feed, TalkTalk Mic arrival (dev build)
    case "speak-mic": runBenchSpeakMic() // P2: microphone/VAD timing, no audio files
    case "keytap": runBenchKeyTap()   // P1: listen-only key observation or in-memory shortcut replay
    case "monitor": runBenchMonitor() // rt-core phase 2: MonitorOutput on the default output, silent (dev build)
    default:
        fail("unknown --bench subcommand '\(sub)'; M0 implements: store-key (dev build)")
    }

case "--sysinput-guard":   // m2 sysinput: §8.6 layer 2; no NSApplication, no single-instance lock
    SysInputGuardMain.run(Array(arguments.dropFirst()))

default:
    fail("usage: TalkTalk | --smoke-ui [--out f] | --list-audio-processes [--out f] | --bench store-key --out f | --version")
}
