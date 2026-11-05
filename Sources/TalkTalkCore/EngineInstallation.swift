import Foundation

/// Reads `engine/install.json` and the files it points at, and decides the install state
/// (ARCHITECTURE.md §7.3 states, §7.5 items 1 and 2). Never runs a process and never hashes:
/// it uses `stat` only, so it is cheap enough for every app launch. sha256 is checked only when
/// the user asks (`install-engine.sh --check`).
public struct EngineInstallation: Sendable {
    /// install.json as written last by `install-engine.sh` (`write_install_json`).
    public struct Record: Codable, Sendable, Equatable {
        public struct Role: Codable, Sendable, Equatable {
            public let id: String
            public let rev: String
        }
        public struct Model: Codable, Sendable, Equatable {
            public let id: String
            public let repo: String
            public let rev: String
            public let role: String
            public let dir: String
        }
        public let version: Int
        public let profile: String
        public let engineAPI: Int
        public let runtime: String
        public let flavour: String
        public let lockSHA256: String
        public let roles: [String: Role]
        public let models: [Model]
        public let mlxAudioCommit: String?
        public let installedAt: String?

        enum CodingKeys: String, CodingKey {
            case version, profile, runtime, flavour, roles, models
            case engineAPI = "engine_api"
            case lockSHA256 = "lock_sha256"
            case mlxAudioCommit = "mlx_audio_commit"
            case installedAt = "installed_at"
        }
    }

    /// §7.3 `EngineInstallState`.
    public enum State: Sendable, Equatable {
        case notInstalled
        case installed(profile: String, models: [String])
        /// A recommended revision is newer than the installed one, which is still in the compat list:
        /// runs as usual, settings show a badge.
        case outdated(profile: String, models: [String])
        /// The runtime (lock, engine API) or a model revision is not supported by this app:
        /// the runtime must be updated before the engine can start.
        case incompatible(reason: String)
        /// Model files are missing; `bytes` is what a repair would download (pinned sizes).
        case incomplete(missing: [String], bytes: Int64)
        /// `install.json.prev` exists: the last installer run did not finish.
        case unfinished
        case damaged(reason: String)

        /// The engine may be started only in these two states.
        public var canStartEngine: Bool {
            switch self {
            case .installed, .outdated: true
            default: false
            }
        }
    }

    public static let maxRecordBytes = 1 << 20
    public static let supportedRecordVersion = 1

    public let engineHome: URL
    public let lockCompat: [String]
    public let engineAPI: Int
    public let pins: [EnginePins.Model]

    public init(engineHome: URL, lockCompat: [String] = EnginePins.lockCompat,
                engineAPI: Int = EnginePins.engineAPI, pins: [EnginePins.Model] = EnginePins.models) {
        self.engineHome = engineHome
        self.lockCompat = lockCompat
        self.engineAPI = engineAPI
        self.pins = pins
    }

    public var recordURL: URL { engineHome.appendingPathComponent("install.json") }
    public var pythonURL: URL { engineHome.appendingPathComponent("venv/bin/python3") }
    public var modelsDir: URL { engineHome.appendingPathComponent("models") }
    public var warmupDir: URL { engineHome.appendingPathComponent("warmup") }

    /// Reads install.json (≤1 MB). nil when it does not exist.
    public func readRecord() throws -> Record? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: recordURL.path) else { return nil }
        let size = (try fm.attributesOfItem(atPath: recordURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxRecordBytes else { throw InstallationError.recordTooLarge(size) }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
    }

    /// §7.5 items 1 and 2. Returns the state and, when the engine may start, the record.
    public func check() -> (state: State, record: Record?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: engineHome.appendingPathComponent("install.json.prev").path) {
            return (.unfinished, nil)
        }
        let record: Record
        do {
            guard let r = try readRecord() else { return (.notInstalled, nil) }
            record = r
        } catch {
            return (.damaged(reason: "install.json unreadable: \(error)"), nil)
        }
        guard record.version == Self.supportedRecordVersion else {
            return (.incompatible(reason: "install.json version \(record.version), app reads \(Self.supportedRecordVersion)"), record)
        }
        guard lockCompat.contains(record.lockSHA256) else {
            return (.incompatible(reason: "runtime lock \(record.lockSHA256.prefix(12)) not supported by this app"), record)
        }
        guard record.engineAPI == engineAPI else {
            return (.incompatible(reason: "engine API \(record.engineAPI), app speaks \(engineAPI)"), record)
        }
        // Completion stamps and the interpreter.
        for stamp in ["python/.talktalk-python", "venv/.talktalk-venv"]
        where !fm.fileExists(atPath: engineHome.appendingPathComponent(stamp).path) {
            return (.damaged(reason: "missing \(stamp)"), record)
        }
        guard fm.isExecutableFile(atPath: pythonURL.path) else {
            return (.damaged(reason: "venv/bin/python3 is not executable"), record)
        }
        // Each role: recommended revision (installed) or still in the compat list (outdated).
        var outdated: [String] = []
        var missing: [String] = []
        var missingBytes: Int64 = 0
        for (role, r) in record.roles.sorted(by: { $0.key < $1.key }) {
            guard let pin = pins.first(where: { $0.key == r.id }) else {
                return (.incompatible(reason: "\(role) model \(r.id) is unknown to this app"), record)
            }
            guard pin.role == role else {
                return (.damaged(reason: "\(r.id) recorded as \(role), pinned as \(pin.role)"), record)
            }
            let isCurrent = r.rev == pin.revision
            if !isCurrent {
                guard pin.compatRevisions.contains(r.rev) else {
                    return (.incompatible(reason: "\(r.id) revision \(r.rev.prefix(12)) not supported by this app"), record)
                }
                outdated.append(r.id)
            }
            guard let model = record.models.first(where: { $0.id == r.id && $0.rev == r.rev }) else {
                return (.damaged(reason: "install.json lists \(role) \(r.id) without its model entry"), record)
            }
            switch checkModelDirectory(model, pin: isCurrent ? pin : nil) {
            case .ok: break
            case .missing(let bytes):
                missing.append(r.id)
                missingBytes += bytes
            case .damaged(let why):
                return (.damaged(reason: why), record)
            }
        }
        if !missing.isEmpty { return (.incomplete(missing: missing, bytes: missingBytes), record) }
        let ids = record.roles.values.map(\.id).sorted()
        if !outdated.isEmpty { return (.outdated(profile: record.profile, models: outdated.sorted()), record) }
        return (.installed(profile: record.profile, models: ids), record)
    }

    enum ModelCheck: Equatable {
        case ok
        case missing(bytes: Int64)
        case damaged(String)
    }

    /// Directory present, `.talktalk-verified` whose first line is the revision, and (for the
    /// recommended revision) every pinned file with its pinned size.
    func checkModelDirectory(_ model: Record.Model, pin: EnginePins.Model?) -> ModelCheck {
        let fm = FileManager.default
        let dir = modelsDir.appendingPathComponent(model.dir)
        let pinnedBytes = pin?.bytes ?? 0
        guard fm.fileExists(atPath: dir.path) else { return .missing(bytes: pinnedBytes) }
        let stamp = dir.appendingPathComponent(".talktalk-verified")
        guard let text = try? String(contentsOf: stamp, encoding: .utf8) else { return .missing(bytes: pinnedBytes) }
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard firstLine == model.rev else {
            return .damaged("\(model.dir): .talktalk-verified names \(firstLine.prefix(12)), install.json \(model.rev.prefix(12))")
        }
        guard let pin else { return .ok }
        var lost: Int64 = 0
        for f in pin.files {
            let path = dir.appendingPathComponent(f.path).path
            guard let attrs = try? fm.attributesOfItem(atPath: path) else {
                lost += f.bytes
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            if size != f.bytes {
                return .damaged("\(model.dir)/\(f.path): \(size) bytes, pinned \(f.bytes)")
            }
        }
        return lost > 0 ? .missing(bytes: lost) : .ok
    }

    /// READY must match install.json (§7.6), not EnginePins: returns the mismatches, empty when it matches.
    public static func readyMismatches(record: Record, engine: String, api: Int, runtime: String,
                                       models: [String: (id: String, rev: String)], roles: [String]) -> [String] {
        var out: [String] = []
        if engine != "talktalk-engine" { out.append("engine: READY \(engine), expected talktalk-engine") }
        if api != record.engineAPI { out.append("api: READY \(api), install.json \(record.engineAPI)") }
        if runtime != record.runtime { out.append("runtime: READY \(runtime), install.json \(record.runtime)") }
        for role in roles {
            guard let want = record.roles[role] else {
                out.append("\(role): not in install.json")
                continue
            }
            guard let got = models[role] else {
                out.append("\(role): missing from READY, install.json \(want.id)@\(want.rev.prefix(12))")
                continue
            }
            if got.id != want.id || got.rev != want.rev {
                out.append("\(role): READY \(got.id)@\(got.rev.prefix(12)), install.json \(want.id)@\(want.rev.prefix(12))")
            }
        }
        return out
    }
}

public enum InstallationError: Error, Equatable {
    case recordTooLarge(Int)
}
