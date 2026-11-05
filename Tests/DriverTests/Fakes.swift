import CoreAudio
import Foundation
import Synchronization
@testable import TalkTalkDriverSupport

/// In-memory HAL for state, installer and preflight tests.
final class FakeDriverHAL: DriverHAL, Sendable {
    struct State {
        var devices: [String: DriverDeviceInfo] = [:]
        var diagnostics: DriverDiagnostics?
        var defaultInput: String?
        var meetingMode: Bool?
        /// Devices that appear after this many `device(uid:)` polls of the Feed (installer wait).
        var appearAfterPolls: Int?
        var pendingDevices: [String: DriverDeviceInfo] = [:]
        var feedPolls = 0
    }
    let state = Mutex(State())

    static func feed(version: String = "9.9.9") -> DriverDeviceInfo {
        DriverDeviceInfo(uid: DriverIdentity.feedUID, objectID: 10, outputChannels: 2, isHidden: true,
                         firmwareVersion: version)
    }
    static func testMic(version: String = "9.9.9") -> DriverDeviceInfo {
        DriverDeviceInfo(uid: DriverIdentity.testMicUID, objectID: 11, inputChannels: 1, isHidden: true,
                         firmwareVersion: version)
    }
    static func mic(version: String = "9.9.9", running: Bool = false) -> DriverDeviceInfo {
        DriverDeviceInfo(uid: DriverIdentity.micUID, objectID: 12, inputChannels: 1, inDeviceList: true,
                         isRunningSomewhere: running, canBeDefault: true, firmwareVersion: version)
    }

    init(loaded version: String? = nil) {
        if let version {
            state.withLock {
                $0.devices = [DriverIdentity.feedUID: Self.feed(version: version),
                              DriverIdentity.testMicUID: Self.testMic(version: version),
                              DriverIdentity.micUID: Self.mic(version: version)]
            }
        }
    }

    func set(_ d: DriverDeviceInfo?, uid: String) { state.withLock { $0.devices[uid] = d } }

    func device(uid: String) -> DriverDeviceInfo? {
        state.withLock { s in
            if uid == DriverIdentity.feedUID {
                s.feedPolls += 1
                if let n = s.appearAfterPolls, s.feedPolls >= n {
                    for (k, v) in s.pendingDevices { s.devices[k] = v }
                    s.pendingDevices = [:]
                    s.appearAfterPolls = nil
                }
            }
            return s.devices[uid]
        }
    }
    func diagnostics() -> DriverDiagnostics? { state.withLock { $0.diagnostics } }
    func defaultInputUID() -> String? { state.withLock { $0.defaultInput } }
    func meetingMode() -> Bool? { state.withLock { $0.meetingMode } }
    func setMeetingMode(_ on: Bool) -> OSStatus { state.withLock { $0.meetingMode = on }; return noErr }
}

/// A temp directory per test, removed at deinit.
final class TempDir {
    let url: URL
    init(_ tag: String = "tt-driver") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func sub(_ p: String) -> URL { url.appendingPathComponent(p) }
}

enum FakeDriver {
    /// A minimal driver-shaped bundle: Info.plist with our identifier, a Mach-O executable (a copy
    /// of /usr/bin/true), a license file; optionally ad-hoc signed (install-driver.sh runs
    /// `codesign --verify --strict`), plus a manifest next to it.
    @discardableResult
    static func make(in dir: URL, version: String = "9.9.9", identifier: String = DriverIdentity.bundleIdentifier,
                     sign: Bool = true) throws -> (bundle: URL, manifest: URL) {
        let fm = FileManager.default
        let bundle = dir.appendingPathComponent(DriverIdentity.bundleName)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": DriverIdentity.executableName,
            "CFBundleShortVersionString": version, "CFBundleVersion": version, "CFBundlePackageType": "BNDL",
            "CFBundleName": "TalkTalkAudio",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let exe = bundle.appendingPathComponent("Contents/MacOS/\(DriverIdentity.executableName)")
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: exe)
        try Data("MIT (test)\n".utf8).write(to: bundle.appendingPathComponent("Contents/Resources/libASPL-LICENSE.txt"))
        if sign {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "--sign", "-", "--identifier", identifier, "--timestamp=none", bundle.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw DriverError.staging("codesign failed in the test fixture") }
        }
        let manifest = dir.appendingPathComponent("driver-manifest.json")
        try writeManifest(for: bundle, version: version, identifier: identifier, to: manifest)
        return (bundle, manifest)
    }

    static func writeManifest(for bundle: URL, version: String, identifier: String, to url: URL) throws {
        var files: [DriverManifest.File] = []
        let base = bundle.standardizedFileURL.path + "/"
        let e = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = String(f.standardizedFileURL.path.dropFirst(base.count))
            let size = (try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value ?? 0
            files.append(.init(path: rel, bytes: size, sha256: try DriverManifest.sha256(of: f)))
        }
        files.sort { $0.path < $1.path }
        let m = DriverManifest(bundleName: DriverIdentity.bundleName, bundleIdentifier: identifier, version: version,
                               micMode: "remove", micInUse: "io", sign: "adhoc", libASPL: "3.1.2@test", files: files)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: url)
    }
}

extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
