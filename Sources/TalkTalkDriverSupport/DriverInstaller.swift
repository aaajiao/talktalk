// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkCore
import Darwin
import Foundation
import Observation
import TalkTalkEngineHost

/// Installs, uninstalls and reloads TalkTalkAudio.driver (ARCHITECTURE.md, "平台与模块"):
///
/// 1. pre-checks (`DriverPreflight`): no meeting, nothing reading TalkTalk Mic, no restore record;
/// 2. copy the bundled driver to `Caches/TalkTalk/installer-tmp/driver-<uuid>/` and check it
///    against `driver-manifest.json` (sha256 of every file);
/// 3. one administrator authorization: `install-driver.sh --json install <staged>` (it checks
///    the manifest again as root, installs atomically and restarts coreaudiod);
/// 4. wait for Feed and Test Mic by UID (every 0.5 s, at most 30 times), then write driver.json.
///
/// Everything it does is appended to `~/Library/Logs/TalkTalk/driver-install.log`.
@Observable @MainActor
public final class DriverInstaller {
    public enum Op: String, Sendable, Equatable {
        case install, uninstall, restartAudio
    }

    public enum Outcome: Sendable, Equatable {
        case installed(version: String)
        case uninstalled
        case restarted
        /// The files changed but the audio service did not reload them: log out or restart.
        case needsLogout
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case blocked(DriverPreflight)
        case staging
        case waitingForAuthorization(Op)
        case waitingForDevices(attempt: Int)
        case finished(Outcome)
        case failed(String)
        case cancelled

        public var isBusy: Bool {
            switch self {
            case .staging, .waitingForAuthorization, .waitingForDevices: true
            default: false
            }
        }
    }

    public private(set) var phase: Phase = .idle
    /// Progress lines from the script (msg events), for the settings row.
    public private(set) var messages: [String] = []

    @ObservationIgnored public let resources: DriverResources?
    @ObservationIgnored public let paths: DriverPaths
    @ObservationIgnored public let hal: any DriverHAL
    @ObservationIgnored let runner: any DriverScriptRunner
    @ObservationIgnored let preflightInputs: @MainActor () -> DriverPreflight.Inputs
    @ObservationIgnored let pollInterval: Duration
    @ObservationIgnored let pollAttempts: Int
    @ObservationIgnored let installedBundle: URL

    public static var installPrompt: String { String(appLocalized: "TalkTalk 要安装虚拟麦克风，并重启系统音频（声音会中断约 1 秒）。") }
    public static var uninstallPrompt: String { String(appLocalized: "TalkTalk 要卸载虚拟麦克风，并重启系统音频（声音会中断约 1 秒）。") }
    public static var restartPrompt: String { String(appLocalized: "TalkTalk 要重启系统音频，让虚拟麦克风生效（声音会中断约 1 秒）。") }

    public init(resources: DriverResources?, paths: DriverPaths = .standard(), hal: any DriverHAL = CoreAudioDriverHAL(),
                runner: any DriverScriptRunner = AdminScriptRunner(),
                pollInterval: Duration = .milliseconds(500), pollAttempts: Int = 30,
                installedBundle: URL = DriverIdentity.installedBundle,
                preflightInputs: @escaping @MainActor () -> DriverPreflight.Inputs) {
        self.resources = resources
        self.paths = paths
        self.hal = hal
        self.runner = runner
        self.pollInterval = pollInterval
        self.pollAttempts = pollAttempts
        self.installedBundle = installedBundle
        self.preflightInputs = preflightInputs
    }

    public var installation: DriverInstallation {
        DriverInstallation(paths: paths, bundledVersion: try? resources?.manifest().version, hal: hal,
                           installedBundle: installedBundle)
    }

    /// The pre-check alone, for the confirmation dialog (warnings) before `install()`.
    public func preflight() -> DriverPreflight { DriverPreflight.evaluate(preflightInputs()) }

    // MARK: operations

    @discardableResult
    public func install() async -> Phase {
        guard !phase.isBusy else { return .failed("another driver operation is running") }
        messages = []
        guard let resources else { return finish(.failed("this build carries no driver (Contents/Resources/driver)")) }
        let manifest: DriverManifest
        do { manifest = try resources.manifest() } catch { return finish(.failed("\(error)")) }
        let pre = preflight()
        guard pre.canProceed else { return finish(.blocked(pre)) }

        phase = .staging
        note("install \(manifest.version) from \(resources.directory.path)")
        let stageDir: URL
        do {
            stageDir = try stage(resources: resources, manifest: manifest)
        } catch {
            return finish(.failed("\(error)"))
        }
        defer { try? FileManager.default.removeItem(at: stageDir) }
        let staged = stageDir.appendingPathComponent(DriverIdentity.bundleName)
        let stagedManifest = stageDir.appendingPathComponent("driver-manifest.json")

        phase = .waitingForAuthorization(.install)
        let run = await runner.run(script: resources.installScript, op: .install(staged: staged, manifest: stagedManifest),
                                   prompt: Self.installPrompt)
        guard let out = handle(run) else { return phase }
        let sha = (try? DriverManifest.sha256(of: stagedManifest)) ?? ""
        switch DriverScriptOutcome(out) {
        case .ok:
            guard await waitForDevices(version: manifest.version) else {
                writeRecord(version: manifest.version, sha256: sha)
                return finish(.failed("the audio service restarted but TalkTalk Feed / Test Mic did not appear within \(pollAttempts / 2) s"))
            }
            writeRecord(version: manifest.version, sha256: sha)
            return finish(.finished(.installed(version: manifest.version)))
        case .changedNotRestarted:
            writeRecord(version: manifest.version, sha256: sha)
            return finish(.finished(.needsLogout))
        case .refused(let why), .usage(let why), .failed(let why):
            return finish(.failed(why))
        case .cancelled:
            return finish(.cancelled)
        }
    }

    @discardableResult
    /// `ignoringRestoreRecord`: 完全卸载 has dealt with sysinput's restore record in its own first
    /// step; every other pre-check (a call going on, someone reading TalkTalk Mic, meeting mode)
    /// still blocks, so the Mic is never pulled out from under a call.
    public func uninstall(ignoringRestoreRecord: Bool = false) async -> Phase {
        guard !phase.isBusy else { return .failed("another driver operation is running") }
        messages = []
        guard let script = resources?.installScript else { return finish(.failed("this build carries no install-driver.sh")) }
        var pre = preflight()
        if ignoringRestoreRecord { pre.blockers.removeAll { $0 == .restoreRecordPresent } }
        guard pre.canProceed else { return finish(.blocked(pre)) }
        note("uninstall")
        phase = .waitingForAuthorization(.uninstall)
        let run = await runner.run(script: script, op: .uninstall, prompt: Self.uninstallPrompt)
        guard let out = handle(run) else { return phase }
        switch DriverScriptOutcome(out) {
        case .ok:
            installation.deleteRecord()
            _ = await waitForDevicesGone()
            return finish(.finished(.uninstalled))
        case .changedNotRestarted:
            installation.deleteRecord()
            return finish(.finished(.needsLogout))
        case .refused(let why), .usage(let why), .failed(let why):
            return finish(.failed(why))
        case .cancelled:
            return finish(.cancelled)
        }
    }

    @discardableResult
    public func restartAudio() async -> Phase {
        guard !phase.isBusy else { return .failed("another driver operation is running") }
        messages = []
        guard let script = resources?.installScript else { return finish(.failed("this build carries no install-driver.sh")) }
        let pre = preflight()
        guard pre.canProceed else { return finish(.blocked(pre)) }
        note("restart-audio")
        phase = .waitingForAuthorization(.restartAudio)
        let run = await runner.run(script: script, op: .restartAudio, prompt: Self.restartPrompt)
        guard let out = handle(run) else { return phase }
        switch DriverScriptOutcome(out) {
        case .ok:
            if case .present(let v) = installation.diskState() { _ = await waitForDevices(version: v) }
            return finish(.finished(.restarted))
        case .changedNotRestarted:
            return finish(.finished(.needsLogout))
        case .refused(let why), .usage(let why), .failed(let why):
            return finish(.failed(why))
        case .cancelled:
            return finish(.cancelled)
        }
    }

    public func reset() {
        if !phase.isBusy { phase = .idle }
    }

    // MARK: steps

    /// Copies the bundle and its manifest into a fresh 0700 directory and verifies the copy.
    func stage(resources: DriverResources, manifest: DriverManifest) throws -> URL {
        let fm = FileManager.default
        for dir in [paths.caches, paths.installerTmp] where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let stage = paths.installerTmp.appendingPathComponent("driver-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try fm.copyItem(at: resources.bundle, to: stage.appendingPathComponent(DriverIdentity.bundleName))
            try fm.copyItem(at: resources.manifestURL, to: stage.appendingPathComponent("driver-manifest.json"))
            let problems = manifest.verify(bundle: stage.appendingPathComponent(DriverIdentity.bundleName))
            guard problems.isEmpty else { throw DriverError.staging(problems.prefix(5).joined(separator: "; ")) }
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
        return stage
    }

    func waitForDevices(version: String) async -> Bool {
        for attempt in 1...max(1, pollAttempts) {
            phase = .waitingForDevices(attempt: attempt)
            if hal.device(uid: DriverIdentity.feedUID) != nil, hal.loadedVersion() == version,
               hal.device(uid: DriverIdentity.testMicUID) != nil {
                note("Feed and Test Mic present after \(attempt) poll(s)")
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        note("Feed / Test Mic not found after \(pollAttempts) polls")
        return false
    }

    func waitForDevicesGone() async -> Bool {
        for attempt in 1...max(1, pollAttempts) {
            phase = .waitingForDevices(attempt: attempt)
            if hal.device(uid: DriverIdentity.feedUID) == nil { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    /// Logs the run and turns a runner failure into the final phase (returns nil then).
    private func handle(_ run: Result<DriverScriptOutput, DriverRunError>) -> DriverScriptOutput? {
        switch run {
        case .failure(.cancelled):
            note("authorization cancelled")
            _ = finish(.cancelled)
            return nil
        case .failure(.failed(let m)):
            note("runner failed: \(m)")
            _ = finish(.failed(m))
            return nil
        case .success(let out):
            messages = out.messages
            for e in out.events {
                switch e {
                case .message(let m): note("  \(m)")
                case .value(let k, let v): note("  \(k)=\(v)")
                }
            }
            for l in out.otherLines { note("  | \(l)") }
            note("exit \(out.exitCode) result=\(out.result ?? "-")")
            return out
        }
    }

    private func writeRecord(version: String, sha256: String) {
        do {
            try installation.writeRecord(.init(version: version, sha256: sha256))
        } catch {
            note("cannot write driver.json: \(error)")
        }
    }

    private func finish(_ p: Phase) -> Phase {
        phase = p
        switch p {
        case .blocked(let pre): note("blocked: \(pre.blockers.map(\.text).joined(separator: " "))")
        case .failed(let m): note("failed: \(m)")
        case .finished(let o): note("finished: \(o)")
        case .cancelled: note("cancelled")
        default: break
        }
        return p
    }

    private func note(_ s: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.logs.path) {
            try? fm.createDirectory(at: paths.logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        ServerLog.rotateIfNeeded(paths.installLog)
        ServerLog.note(paths.installLog, s)
    }
}
