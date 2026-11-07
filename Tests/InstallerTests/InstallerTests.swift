import Darwin
import Foundation
import Synchronization
import Testing
import TalkTalkTestSupport
@testable import TalkTalkEngineHost

/// §7.3 / §13 InstallerTests, Swift side: the exact environment, event parsing, the run / fail /
/// cancel paths against small fake scripts, and one run of the real install-engine.sh (`--check`
/// on an empty engine home: no network, no models). The installer's own resume / lock /
/// foreign-file behaviour is covered end to end by scripts/tests/test-installer.sh.
@MainActor
@Suite(.serialized, .temporaryFiles)
struct InstallerTests {
    let dir: URL
    let paths: EnginePaths

    init() throws {
        dir = try TestTemporaryDirectory.make(prefix: "tt-installer")
        let src = dir.appendingPathComponent("engine-src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        paths = EnginePaths(home: dir.appendingPathComponent("home"), logs: dir.appendingPathComponent("logs"),
                            caches: dir.appendingPathComponent("caches"), engineSource: src, installerScript: nil)
    }

    func script(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func installer(_ script: URL, grace: Duration = .seconds(2),
                   stop: @escaping @Sendable () async -> Void = {}) -> EngineInstaller {
        EngineInstaller(script: script, paths: paths, homeDirectory: "/Users/test", lang: "de_DE.UTF-8",
                        termGrace: grace, stopEngine: stop)
    }

    func log() -> String { (try? String(contentsOf: paths.installLog, encoding: .utf8)) ?? "" }

    // MARK: environment and arguments

    @Test func environmentIsExactlyTheSpecList() {
        let env = EngineInstaller.environment(paths: paths, engineHome: paths.engineHome(), home: "/Users/test",
                                              lang: "en_US.UTF-8")
        #expect(env == [
            "HOME": "/Users/test",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TMPDIR": dir.appendingPathComponent("caches/installer-tmp").path,
            "TALKTALK_ENGINE_HOME": dir.appendingPathComponent("home/engine").path,
            "TALKTALK_BUILD_CACHE": dir.appendingPathComponent("caches/engine-build").path,
            "TALKTALK_ENGINE_SRC_DIR": dir.appendingPathComponent("engine-src").path,
        ])
        #expect(!env.keys.contains { $0.hasPrefix("READREAD") || $0 == "OPENAI_API_KEY" || $0 == "TALKTALK_HOME" })
    }

    @Test func launchSpecArguments() throws {
        let s = try script("x.sh", "exit 0\n")
        let i = installer(s)
        #expect(i.launchSpec(for: .install(profile: nil)).arguments == [s.path, "--json-progress"])
        #expect(i.launchSpec(for: .install(profile: "compact24")).arguments == [s.path, "--profile", "compact24", "--json-progress"])
        #expect(i.launchSpec(for: .check).arguments == [s.path, "--check", "--json-progress"])
        #expect(i.launchSpec(for: .addModel("k")).arguments == [s.path, "--add-model", "k", "--json-progress"])
        #expect(i.launchSpec(for: .removeModel("k")).arguments == [s.path, "--remove-model", "k", "--json-progress"])
        #expect(i.launchSpec(for: .removeActiveModel("k")).arguments == [s.path, "--remove-model", "k", "--allow-active-model", "--json-progress"])
        #expect(i.launchSpec(for: .uninstall).arguments == [s.path, "--uninstall", "--json-progress"])
        let spec = i.launchSpec(for: .check)
        #expect(spec.executable == "/bin/bash")
        #expect(spec.logPath == paths.installLog.path)
    }

    // MARK: events

    @Test func parsesTheInstallerEventLines() {
        // Lines exactly as tt_event prints them.
        #expect(InstallerEvent.parse(#"{"event":"step","step":"venv","done":1,"count":3}"#)
                == .step(name: "venv", model: nil, done: 1, count: 3))
        #expect(InstallerEvent.parse(#"{"event":"step","step":"model","model":"tts-x","done":0,"count":4}"#)
                == .step(name: "model", model: "tts-x", done: 0, count: 4))
        #expect(InstallerEvent.parse(#"{"event":"step","step":"check","model":"asr-y"}"#)
                == .step(name: "check", model: "asr-y", done: nil, count: nil))
        #expect(InstallerEvent.parse(#"{"event":"download","file":"python","have":0,"total":4294967296}"#)
                == .download(file: "python", have: 0, total: 4_294_967_296, verified: false))
        #expect(InstallerEvent.parse(#"{"event":"download","file":"python","have":12,"total":12,"verified":1}"#)
                == .download(file: "python", have: 12, total: 12, verified: true))
        #expect(InstallerEvent.parse(#"{"event":"done","profile":"max"}"#) == .done(profile: "max", ok: nil))
        #expect(InstallerEvent.parse(#"{"event":"done","profile":"max","smoke":"skipped"}"#) == .done(profile: "max", ok: nil))
        #expect(InstallerEvent.parse(#"{"event":"done","ok":0}"#) == .done(profile: nil, ok: false))
        #expect(InstallerEvent.parse(#"{"event":"error","message":"say \"hi\"\tfailed"}"#) == .error("say \"hi\"\tfailed"))
        #expect(InstallerEvent.parse(#"{"event":"later"}"#) == .unknown("later"))
        #expect(InstallerEvent.parse("python: ok") == nil)
        #expect(InstallerEvent.parse(#"{"no":"event"}"#) == nil)
    }

    @Test func progressFollowsEvents() {
        var p = InstallerProgress()
        p.apply(.step(name: "model", model: "m", done: 1, count: 4))
        p.apply(.download(file: "a", have: 0, total: 10, verified: false))
        p.apply(.download(file: "a", have: 10, total: 10, verified: true))
        p.apply(.download(file: "b", have: 5, total: 20, verified: false))
        #expect(p.step == "model" && p.model == "m" && p.stepDone == 1 && p.stepCount == 4)
        #expect(p.file == "b" && p.fileHave == 5 && p.fileTotal == 20 && p.verifiedBytes == 10)
    }

    // MARK: runs

    @Test func activeModelRemovalStopsEngineBeforeLaunching() async throws {
        let launched = dir.appendingPathComponent("removal-launched")
        let s = try script("remove.sh", """
            : > '\(launched.path)'
            [ "$1" = '--remove-model' ] && [ "$2" = 'fixture-model' ] && [ "$3" = '--allow-active-model' ] || exit 1
            echo '{"event":"done","removed":1}'
            """)
        let order = Mutex<[String]>([])
        let i = installer(s) {
            order.withLock { $0.append(FileManager.default.fileExists(atPath: launched.path) ? "stop-after" : "stop-before") }
        }
        #expect(await i.run(.removeActiveModel("fixture-model")) == .finished)
        #expect(order.withLock { $0 } == ["stop-before"])
    }

    @Test func successfulRunEnvironmentLogAndEngineStop() async throws {
        let envOut = dir.appendingPathComponent("env.txt")
        let s = try script("ok.sh", """
            /usr/bin/env > '\(envOut.path)'
            echo '{"event":"step","step":"python","done":0,"count":1}'
            echo 'python: installed' >&2
            echo '{"event":"done","profile":"max"}'
            """)
        let order = Mutex<[String]>([])
        let marker = envOut.path
        let i = installer(s) {
            order.withLock { $0.append(FileManager.default.fileExists(atPath: marker) ? "stop-after" : "stop-before") }
        }
        let result = await i.run(.install(profile: nil))
        #expect(result == .finished)
        #expect(i.state == .finished)
        #expect(order.withLock { $0 } == ["stop-before"])

        // The child sees exactly the §7.3 list; bash itself adds only PWD, SHLVL and `_`.
        var seen: [String: String] = [:]
        for line in try String(contentsOf: envOut, encoding: .utf8).split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            seen[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        for k in ["PWD", "SHLVL", "_", "OLDPWD"] { seen[k] = nil }
        #expect(seen == EngineInstaller.environment(paths: paths, engineHome: paths.engineHome(),
                                                    home: "/Users/test", lang: "de_DE.UTF-8"))

        let text = log()
        #expect(text.contains("install-engine.sh --json-progress"))
        #expect(text.contains("python: installed"))
        #expect(!text.contains("\"event\""))   // events go to stdout only
        let mode = try FileManager.default.attributesOfItem(atPath: paths.installLog.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        for d in [paths.installerTmp, paths.buildCache] {
            #expect(FileManager.default.fileExists(atPath: d.path))
        }
    }

    @Test func errorEventBecomesFailure() async throws {
        let s = try script("fail.sh", """
            echo '{"event":"step","step":"venv","done":1,"count":3}'
            echo '{"event":"error","message":"pip failed on requirements-build.lock"}'
            exit 1
            """)
        let i = installer(s)
        #expect(await i.run(.install(profile: "max")) == .failed("pip failed on requirements-build.lock"))
    }

    @Test func exitWithoutEventIsReported() async throws {
        let s = try script("die.sh", "kill -KILL $$\n")
        let i = installer(s)
        #expect(await i.run(.uninstall) == .failed("install-engine.sh: signal 9"))
    }

    @Test func checkProblemsAreAFailure() async throws {
        let s = try script("check.sh", """
            echo '{"event":"step","step":"check","model":"m"}'
            echo '{"event":"done","ok":0}'
            exit 1
            """)
        let i = installer(s)
        #expect(await i.run(.check) == .failed("check found problems"))
    }

    @Test func secondRunWhileRunningIsRefused() async throws {
        let s = try script("slow.sh", "/bin/sleep 0.5\n")
        let i = installer(s)
        async let first = i.run(.check)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await i.run(.check) == .failed("another installer run is in progress"))
        #expect(await first == .finished)
    }

    @Test func cancelTerminatesTheProcessGroup() async throws {
        let childOut = dir.appendingPathComponent("child.pid")
        let s = try script("long.sh", """
            trap 'echo "{\\"event\\":\\"error\\",\\"message\\":\\"interrupted\\"}"; exit 130' TERM
            /bin/sleep 60 &
            echo $! > '\(childOut.path)'
            echo '{"event":"step","step":"model","done":0,"count":2}'
            wait
            """)
        let i = installer(s)
        async let result = i.run(.install(profile: nil))
        try await waitFor { FileManager.default.fileExists(atPath: childOut.path) }
        try await waitFor { if case .running(_, let p) = i.state { p.step == "model" } else { false } }
        let started = ContinuousClock.now
        i.cancel()
        #expect(await result == .cancelled)
        #expect(ContinuousClock.now - started < .seconds(1.5))   // SIGTERM did it, not the SIGKILL timer
        let child = pid_t(try String(contentsOf: childOut, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try await waitFor { kill(child, 0) != 0 }
    }

    @Test func cancelEscalatesToSigkill() async throws {
        let ready = dir.appendingPathComponent("ready")
        // An ignored SIGTERM is inherited by the children too.
        let s = try script("stubborn.sh", """
            trap '' TERM
            : > '\(ready.path)'
            while :; do /bin/sleep 0.1; done
            """)
        let i = installer(s, grace: .milliseconds(300))
        async let result = i.run(.install(profile: nil))
        try await waitFor { FileManager.default.fileExists(atPath: ready.path) }
        let started = ContinuousClock.now
        i.cancel()
        #expect(await result == .cancelled)
        let took = ContinuousClock.now - started
        #expect(took >= .milliseconds(250) && took < .seconds(3))
    }

    @Test func cancelBeforeLaunchStartsNothing() async throws {
        let ran = dir.appendingPathComponent("ran")
        let s = try script("never.sh", ": > '\(ran.path)'\n")
        let gate = AsyncStream<Void>.makeStream()
        let i = installer(s) { for await _ in gate.stream { break } }
        async let result = i.run(.install(profile: nil))
        try await Task.sleep(for: .milliseconds(100))
        i.cancel()
        gate.continuation.yield()
        #expect(await result == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: ran.path))
    }

    /// The real install-engine.sh with the app's environment: `--check` on an empty engine home
    /// reports problems (no network, nothing written outside the temp directory).
    @Test func realScriptCheckOnEmptyHome() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let real = repo.appendingPathComponent("scripts/install-engine.sh")
        let realPaths = EnginePaths(home: paths.home, logs: paths.logs, caches: paths.caches,
                                    engineSource: repo.appendingPathComponent("engine"), installerScript: real)
        let i = EngineInstaller(script: real, paths: realPaths, homeDirectory: dir.path)
        #expect(await i.run(.check) == .failed("check found problems"))
        let text = log()
        #expect(text.contains("install.json missing"))
        #expect(!FileManager.default.fileExists(atPath: realPaths.engineHome().appendingPathComponent("install.json").path))
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() {
            if ContinuousClock.now > end { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
