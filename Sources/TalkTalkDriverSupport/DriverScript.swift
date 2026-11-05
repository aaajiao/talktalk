import AppKit
import Foundation

/// One run of `install-driver.sh` (docs/decisions/m0-t8-driver.md "install-driver.sh 的命令行约定").
public enum DriverScriptOp: Sendable, Equatable {
    case install(staged: URL, manifest: URL)
    case uninstall
    case restartAudio
    case status

    /// `--json` must come first.
    public var arguments: [String] {
        switch self {
        case .install(let staged, let manifest): ["--json", "install", staged.path, "--manifest", manifest.path]
        case .uninstall: ["--json", "uninstall"]
        case .restartAudio: ["--json", "restart-audio"]
        case .status: ["--json", "status"]
        }
    }

    public var needsRoot: Bool { self != .status }

    public var name: String {
        switch self {
        case .install: "install"
        case .uninstall: "uninstall"
        case .restartAudio: "restart-audio"
        case .status: "status"
        }
    }
}

/// One stdout line of `install-driver.sh --json`.
public enum DriverScriptEvent: Sendable, Equatable {
    case message(String)
    case value(key: String, value: String)

    public static func parse(_ line: String) -> DriverScriptEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else { return nil }
        switch kind {
        case "msg": return .message(obj["msg"] as? String ?? "")
        case "kv":
            guard let k = obj["key"] as? String else { return nil }
            return .value(key: k, value: obj["value"] as? String ?? "")
        default: return nil
        }
    }
}

/// The whole result of a run: events in order, the plain lines that were not events (stderr
/// is merged into stdout, see `AdminScriptRunner`), and the script's exit code.
public struct DriverScriptOutput: Sendable, Equatable {
    public var events: [DriverScriptEvent]
    public var otherLines: [String]
    public var exitCode: Int32

    public init(events: [DriverScriptEvent] = [], otherLines: [String] = [], exitCode: Int32) {
        self.events = events
        self.otherLines = otherLines
        self.exitCode = exitCode
    }

    /// The marker line the wrapper appends: `tt-exit=<code>`.
    static let exitMarker = "tt-exit="

    /// Parses merged stdout+stderr of the wrapper (`… 2>&1; echo tt-exit=$?`). Without the
    /// marker (the wrapper itself failed) the exit code is `fallbackExit`.
    public static func parse(_ text: String, fallbackExit: Int32) -> DriverScriptOutput {
        var out = DriverScriptOutput(exitCode: fallbackExit)
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.hasPrefix(exitMarker), let code = Int32(line.dropFirst(exitMarker.count)) {
                out.exitCode = code
            } else if let e = DriverScriptEvent.parse(line) {
                out.events.append(e)
            } else {
                out.otherLines.append(line)
            }
        }
        return out
    }

    public var values: [String: String] {
        var d: [String: String] = [:]
        for case .value(let k, let v) in events { d[k] = v }
        return d
    }

    /// The last `result` (ok, error, on-disk-not-loaded, removed-still-loaded, restart-failed).
    public var result: String? {
        events.reversed().lazy.compactMap { if case .value("result", let v) = $0 { v } else { nil } }.first
    }

    public var error: String? {
        events.reversed().lazy.compactMap { if case .value("error", let v) = $0 { v } else { nil } }.first
    }

    public var messages: [String] { events.compactMap { if case .message(let m) = $0 { m } else { nil } } }
}

/// How the script ended, by the contract's exit codes.
public enum DriverScriptOutcome: Sendable, Equatable {
    case ok
    /// Exit 1: refused or verification failed; nothing changed (or the old version stayed).
    case refused(String)
    /// Exit 2: a usage error (a bug on our side).
    case usage(String)
    /// Exit 3: files changed but coreaudiod did not restart: log out or restart the Mac.
    case changedNotRestarted
    case cancelled
    case failed(String)

    public init(_ out: DriverScriptOutput) {
        switch out.exitCode {
        case 0: self = .ok
        case 1: self = .refused(out.error ?? out.otherLines.last ?? "install-driver.sh refused")
        case 2: self = .usage(out.otherLines.last ?? "usage error")
        case 3: self = .changedNotRestarted
        default: self = .failed(out.error ?? "install-driver.sh exited \(out.exitCode)")
        }
    }
}

/// Runs the script, as root where needed. Tests use a runner that runs it directly with
/// `TT_HAL_DIR` + `TT_INSTALL_ALLOW_NONROOT=1` and `--no-restart`.
public protocol DriverScriptRunner: Sendable {
    @MainActor func run(script: URL, op: DriverScriptOp, prompt: String) async -> Result<DriverScriptOutput, DriverRunError>
}

public enum DriverRunError: Error, Equatable, CustomStringConvertible {
    case cancelled
    case failed(String)

    public var description: String {
        switch self {
        case .cancelled: "cancelled"
        case .failed(let m): m
        }
    }
}

/// §8.4 step 3: one administrator authorization through `NSAppleScript`
/// (`do shell script … with administrator privileges`), so the system dialog names TalkTalk.
///
/// The wrapper runs `/bin/bash <script> <args> 2>&1; echo tt-exit=$?`: `do shell script` drops
/// stdout when the command exits non-zero, so the shell always exits 0 and the script's own exit
/// code arrives as the marker line. `without altering line endings` keeps `\n`.
///
/// NSAppleScript is used on the main thread only (AppKit's rule), and `executeAndReturnError`
/// blocks it while the password dialog is up and the script runs (copy + coreaudiod restart,
/// typically a few seconds, at most ~30 s while install-driver.sh waits for the driver host).
/// The caller yields once first so the UI shows "等待授权" before the block.
public struct AdminScriptRunner: DriverScriptRunner {
    public init() {}

    /// The shell command line; every path is single-quoted.
    public static func shellCommand(script: URL, op: DriverScriptOp) -> String {
        let args = ([script.path] + op.arguments).map(shellQuote).joined(separator: " ")
        return "/bin/bash \(args) 2>&1; echo \(DriverScriptOutput.exitMarker)$?"
    }

    public static func appleScriptSource(shellCommand: String, prompt: String, admin: Bool) -> String {
        var s = "do shell script \"\(appleScriptEscape(shellCommand))\""
        if admin { s += " with administrator privileges with prompt \"\(appleScriptEscape(prompt))\"" }
        s += " without altering line endings"
        return s
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @MainActor
    public func run(script: URL, op: DriverScriptOp, prompt: String) async -> Result<DriverScriptOutput, DriverRunError> {
        // Let SwiftUI draw the "waiting for authorization" state before the main thread blocks.
        try? await Task.sleep(for: .milliseconds(80))
        let source = Self.appleScriptSource(shellCommand: Self.shellCommand(script: script, op: op),
                                            prompt: prompt, admin: op.needsRoot)
        guard let apple = NSAppleScript(source: source) else { return .failure(.failed("NSAppleScript init failed")) }
        var info: NSDictionary?
        let desc = apple.executeAndReturnError(&info)
        if let info {
            let code = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if code == -128 { return .failure(.cancelled) }   // userCanceledErr
            let msg = info[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
            return .failure(.failed(msg))
        }
        return .success(DriverScriptOutput.parse(desc.stringValue ?? "", fallbackExit: -1))
    }
}

/// Runs the script as the current user (the `status` op, and tests against a temp HAL dir).
public struct DirectScriptRunner: DriverScriptRunner {
    public var environment: [String: String]
    public var extraArguments: [String]

    public init(environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], extraArguments: [String] = []) {
        self.environment = environment
        self.extraArguments = extraArguments
    }

    @MainActor
    public func run(script: URL, op: DriverScriptOp, prompt: String) async -> Result<DriverScriptOutput, DriverRunError> {
        let env = environment
        let args = [script.path] + op.arguments + extraArguments
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = args
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return .failure(.failed("cannot run install-driver.sh: \(error)")) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var out = DriverScriptOutput.parse(String(decoding: data, as: UTF8.self), fallbackExit: p.terminationStatus)
            out.exitCode = p.terminationStatus
            return .success(out)
        }.value
    }
}
