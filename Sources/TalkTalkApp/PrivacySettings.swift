// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Foundation
import TalkTalkCore
import TalkTalkEngineHost
import UniformTypeIdentifiers

/// Model of Settings › 隐私与诊断 (ARCHITECTURE.md §11, §12): the transcript switch (§16
/// decision 7, default off), retention (§12.1: run at launch and hourly), the per-meeting
/// diagnostic recording (`DiagnosticRecorder`) and the diagnostics bundle export (§12.3).
///
/// One instance for the app (`shared`); creating it starts the retention scheduler, so the first
/// touch at launch (the meeting wiring or this page) also runs the launch sweep.
@MainActor
@Observable
final class PrivacySettings {
    private enum Key {
        static let saveTranscripts = "privacy.saveTranscripts"
    }

    static let shared = PrivacySettings()

    let home: URL
    let logs: URL
    let recorder: DiagnosticRecorder
    let subtitleAnalysis: SubtitleAnalysisRecorder
    let diagnosticsStatus: DiagnosticsStatus
    private let defaults: UserDefaults
    @ObservationIgnored private var retention: RetentionScheduler?

    /// §16 decision 7: transcripts are not stored unless this is on (30 days, `transcripts/`).
    var saveTranscripts: Bool {
        didSet { defaults.set(saveTranscripts, forKey: Key.saveTranscripts) }
    }

    private(set) var lastSweep: Date?
    private(set) var lastSweepRemoved = 0
    private(set) var exporting = false
    private(set) var exportMessage: String?
    var showRemoteRefused = false

    init(paths: EnginePaths = .standard(), defaults: UserDefaults = .standard, startRetention: Bool = true) {
        self.home = paths.home
        self.logs = paths.logs
        self.diagnosticsStatus = DiagnosticsStatus(logs: paths.logs)
        self.defaults = defaults
        self.recorder = DiagnosticRecorder(root: paths.home.appendingPathComponent("diagnostics", isDirectory: true))
        self.subtitleAnalysis = SubtitleAnalysisRecorder(root: paths.home.appendingPathComponent("diagnostics", isDirectory: true))
        self.saveTranscripts = defaults.bool(forKey: Key.saveTranscripts)
        if startRetention { self.startRetention() }
    }

    var diagnosticsDirectory: URL { recorder.root }
    var transcriptsDirectory: URL { home.appendingPathComponent("transcripts", isDirectory: true) }

    // MARK: - retention

    func startRetention() {
        guard retention == nil else { return }
        let r = RetentionScheduler(targets: RetentionScheduler.standardTargets(home: home, logs: logs),
                                   onSweep: { [weak self] removed in
                                       let n = removed.count
                                       Task { @MainActor in self?.sweepDone(n) }
                                   })
        retention = r
        r.start()
    }

    /// 立即清理: the same rules, now.
    func sweepNow() {
        if let r = retention { r.sweepNow() } else { startRetention() }
    }

    private func sweepDone(_ n: Int) {
        lastSweep = Date()
        lastSweepRemoved = n
    }

    // MARK: - diagnostic recording

    func startSubtitleAnalysis() {
        guard recorder.meetingRunning else { return }
        subtitleAnalysis.start()
    }

    func requestRemoteRecording() {
        guard recorder.meetingRunning else { showRemoteRefused = true; return }
        if let consent = recorder.confirmRemoteConsent() { recorder.startRemote(consent) }
    }

    func revealDiagnostics() {
        let dir = recorder.sessionDirectory ?? diagnosticsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: - export

    func exportBundle() {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出诊断包")
        panel.nameFieldStringValue = DiagnosticsBundleExporter.suggestedName()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        exporting = true
        exportMessage = nil
        let exporter = DiagnosticsBundleExporter(home: home, logs: logs)
        Task.detached(priority: .userInitiated) {
            let message: String
            do {
                let r = try exporter.export(to: dest)
                message = String(localized: "已导出 \(r.files) 个文件到 \(dest.lastPathComponent)；过滤掉 \(r.droppedLines) 行")
                    + (r.skippedTooLarge > 0 ? String(localized: "，跳过 \(r.skippedTooLarge) 个过大的文件") : "")
                    + String(localized: "。已检查：包里没有 key、请求头和文字内容。")
            } catch let e as DiagnosticsBundleExporter.Failure {
                message = e.description
            } catch {
                message = String(localized: "导出失败：\(error)")
            }
            await self.exportFinished(message)
        }
    }

    private func exportFinished(_ message: String) {
        exporting = false
        exportMessage = message
    }
}
