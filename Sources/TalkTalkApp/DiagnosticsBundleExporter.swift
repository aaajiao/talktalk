import Foundation
import TalkTalkAudio
import TalkTalkCore

/// Settings › 隐私与诊断 › 导出诊断包 (ARCHITECTURE.md §12.3). The bundle is
/// `DiagnosticsBundle.assemble` (whitelist + line filter, Core) plus two generated files —
/// versions and audio device names — zipped with `/usr/bin/ditto`.
///
/// M1 完成标准 "日志和诊断包里扫描不到 key": the tree is scanned for key-shaped text before
/// zipping, and the zip (stored, not deflated, so its bytes are scannable) once more after; a hit
/// deletes everything and fails the export. The real key is never read (only its shape is known;
/// KeychainSecret is not used here at all). The staging tree lives in a 0700 temporary directory
/// and is removed in every case.
struct DiagnosticsBundleExporter {
    struct Result: Equatable {
        var destination: URL
        var files: Int
        var droppedLines: Int
        var skippedTooLarge: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case secretFound([String])
        case zipFailed(Int32)

        var description: String {
            switch self {
            case let .secretFound(paths): "诊断包里出现了像 key 的内容（\(paths.joined(separator: ", "))），已删除，没有导出。"
            case let .zipFailed(code): "打包失败（ditto 退出码 \(code)）。"
            }
        }
    }

    let home: URL
    let logs: URL
    var temporaryRoot: URL = FileManager.default.temporaryDirectory

    init(home: URL, logs: URL) {
        self.home = home
        self.logs = logs
    }

    /// Default name for the save panel: ASCII, no user or device names.
    static func suggestedName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "TalkTalk-diagnostics-\(f.string(from: now)).zip"
    }

    func export(to destination: URL) throws -> Result {
        let staging = temporaryRoot.appendingPathComponent("TalkTalk-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let bundleDir = staging.appendingPathComponent("TalkTalk-diagnostics", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileSystem.ensurePrivateDirectory(staging)

        let wl = DiagnosticsWhitelist(home: home, logs: logs)
        let manifest: DiagnosticsBundle.Manifest
        do {
            manifest = try DiagnosticsBundle.assemble(wl, extras: extras(), into: bundleDir)
        } catch let DiagnosticsBundle.Failure.secretFound(paths) {
            throw Failure.secretFound(paths)
        }

        let zip = staging.appendingPathComponent("bundle.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--zlibCompressionLevel", "0", "--keepParent",
                       bundleDir.path, zip.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.zipFailed(p.terminationStatus) }
        if let data = FileManager.default.contents(atPath: zip.path),
           DiagnosticsWhitelist.containsSecret(String(decoding: data, as: UTF8.self)) {
            throw Failure.secretFound(["bundle.zip"])
        }
        let zipData = try Data(contentsOf: zip)
        try FileSystem.writeAtomically(zipData, to: destination)
        return Result(destination: destination, files: manifest.files.count,
                      droppedLines: manifest.files.reduce(0) { $0 + $1.droppedLines },
                      skippedTooLarge: manifest.skippedTooLarge)
    }

    /// versions.json and devices.json. Device names are in the whitelist (§12.3); UIDs are not.
    func extras() -> [String: Data] {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let versions: [String: Any] = [
            "app": EnginePins.appVersion,
            "bundle_version": info["CFBundleVersion"] as? String ?? "",
            "flavor": BuildFlavor.current.rawValue,
            "engine_api": EnginePins.engineAPI,
            "lock_sha256": EnginePins.lockSHA256,
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ]
        let devices: [[String: Any]] = AudioDeviceCatalog.devices().map {
            ["name": $0.name, "transport": $0.transport, "inputs": $0.inputChannels, "outputs": $0.outputChannels,
             "rate": $0.nominalSampleRate, "alive": $0.isAlive]
        }
        func json(_ o: Any) -> Data {
            (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        }
        return ["versions.json": json(versions), "devices.json": json(devices)]
    }
}
