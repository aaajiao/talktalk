// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Foundation
import Observation
import TalkTalkCore
import TalkTalkEngineHost

/// Bounded, on-demand log reading and explicitly requested self-tests. Opening this model never
/// starts an engine, captures audio or sends a network request.
@MainActor
@Observable
final class DiagnosticsStatus {
    struct Latency: Identifiable, Sendable {
        enum Kind: String, Sendable { case speak, listen }
        var id: String
        var kind: Kind
        var segment: Int
        var milliseconds: Double
        var jobKey: String?
        var releaseToAudioMs: Double?
        var computeRTF: Double?
        var underrunsTotal: Int?
    }
    struct Snapshot: Sendable {
        var rows: [Latency] = []
        var filesRead = 0
        var bytesRead = 0
        var truncated = false
    }
    private let sessions: URL
    private(set) var snapshot = Snapshot()
    private(set) var refreshing = false
    private(set) var refreshedAt: Date?
    private(set) var runningPart: String?
    private(set) var report: SelfTestReport?
    private(set) var notice: String?
    @ObservationIgnored var canRunAudioSelfTest: @MainActor () -> Bool = { true }
    @ObservationIgnored var beforeAudioSelfTest: (@MainActor () async -> Void)?

    init(logs: URL) { sessions = logs.appendingPathComponent("sessions", isDirectory: true) }
    var isAudioSelfTestRunning: Bool { runningPart == "--engine" }
    var audioSelfTestAvailable: Bool { runningPart == nil && beforeAudioSelfTest != nil && canRunAudioSelfTest() }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let directory = sessions
        Task {
            let value = await Task.detached(priority: .utility) { Self.read(directory) }.value
            snapshot = value; refreshedAt = Date(); refreshing = false
        }
    }

    func runEngine() {
        guard audioSelfTestAvailable, let beforeAudioSelfTest else { return }
        run("--engine", before: beforeAudioSelfTest)
    }
    func runCloud() { run("--cloud") }

    private func run(_ part: String, before: (@MainActor () async -> Void)? = nil) {
        guard runningPart == nil, let runner = selfTestRunners[part] else { return }
        runningPart = part; report = nil; notice = nil
        Task {
            if let before { await before() }
            report = await runner()
            runningPart = nil
            refresh()
        }
    }

    func copyCommand(_ part: String) {
        guard ["--driver", "--voice", "--loop", "--passthrough"].contains(part) else { return }
        let bundle = Bundle.main.bundleURL
        let app = bundle.pathExtension == "app" ? bundle.path
            : (BuildFlavor.current == .release ? "TalkTalk.app" : "TalkTalk-Dev.app")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("talktalk-self-test-\(part.dropFirst(2)).jsonl").path
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "open -W -n -a \(quote(app)) --args --self-test \(part) --out \(quote(output))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        notice = String(localized: "命令已复制。先退出 TalkTalk，再在终端执行；结果写入命令指定的文件。")
    }

    func percentile(_ kind: Latency.Kind, _ fraction: Double) -> Double? {
        percentile(snapshot.rows.filter { $0.kind == kind }.map(\.milliseconds), fraction)
    }
    func releasePercentile(_ fraction: Double) -> Double? { percentile(snapshot.rows.compactMap(\.releaseToAudioMs), fraction) }
    func rtfPercentile(_ fraction: Double) -> Double? { percentile(snapshot.rows.compactMap(\.computeRTF), fraction) }
    var latestUnderrunsTotal: Int? { snapshot.rows.last(where: { $0.kind == .speak })?.underrunsTotal }
    private func percentile(_ samples: [Double], _ fraction: Double) -> Double? {
        let values = samples.sorted()
        guard !values.isEmpty else { return nil }
        let position = min(1, max(0, fraction)) * Double(values.count - 1)
        let lower = Int(position), upper = min(values.count - 1, Int(ceil(position)))
        return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
    }

    /// Only the newest three session files, at most the last 512 KiB of each. No recursive
    /// scanning, no text fields, no engine logs or transcript/recording directories.
    nonisolated private static func read(_ directory: URL) -> Snapshot {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let files = urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 == $1.1 ? $0.0.lastPathComponent > $1.0.lastPathComponent : $0.1 > $1.1 }
        var result = Snapshot()
        var rtfByJob: [String: Double] = [:]
        for (file, _) in files.prefix(3).reversed() {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            let limit: UInt64 = 512 * 1024
            let start = size > limit ? size - limit : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(limit)) else { continue }
            result.filesRead += 1; result.bytesRead += data.count
            result.truncated = result.truncated || start > 0
            var lines = data.split(separator: 10, omittingEmptySubsequences: true)
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            for (index, line) in lines.enumerated() {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let name = event["ev"] as? String else { continue }
                func number(_ field: String) -> Double? {
                    guard let value = event[field] as? NSNumber, value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
                    return value.doubleValue
                }
                let jobKey = (event["job"] as? NSNumber).map { "\(file.lastPathComponent):job:\($0.stringValue)" }
                if name == "speak.tts_complete" {
                    if let jobKey, let rtf = number("compute_rtf") { rtfByJob[jobKey] = rtf }
                    continue
                }
                let kind: Latency.Kind, field: String, segmentField: String
                switch name {
                case "speak.first_audio": kind = .speak; field = "commit_to_audio_ms"; segmentField = "clause"
                case "mt.final": kind = .listen; field = "trigger_to_text_ms"; segmentField = "sentence"
                default: continue
                }
                guard let duration = number(field) else { continue }
                let underruns = (event["underruns_total"] as? NSNumber)?.intValue
                result.rows.append(.init(id: "\(file.lastPathComponent):\(index)", kind: kind,
                    segment: (event[segmentField] as? NSNumber)?.intValue ?? 0, milliseconds: duration,
                    jobKey: kind == .speak ? jobKey : nil,
                    releaseToAudioMs: kind == .speak ? number("release_to_audio_ms") : nil,
                    computeRTF: nil, underrunsTotal: kind == .speak ? underruns.flatMap { $0 >= 0 ? $0 : nil } : nil))
                if result.rows.count > 20 { result.rows.removeFirst() }
            }
        }
        for index in result.rows.indices {
            if let key = result.rows[index].jobKey { result.rows[index].computeRTF = rtfByJob[key] }
        }
        return result
    }
}
