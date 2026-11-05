// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Foundation
import TalkTalkCore
import TalkTalkSession

/// One explicit runtime analysis, never a persisted preference. This is separate from EventLog,
/// whose default no-text policy and diagnostics export whitelist remain unchanged.
@MainActor @Observable
final class SubtitleAnalysisRecorder {
    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var fileURL: URL?
    private(set) var status = String(localized: "未开启")
    private(set) var recordCount = 0
    @ObservationIgnored private let writer: SubtitleAnalysisTrace
    @ObservationIgnored private let queue = DispatchQueue(label: "talktalk.subtitle-analysis", qos: .utility)
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var enabledAt: HostTime = 0
    @ObservationIgnored private var reservedBytes = 0

    init(root: URL) { writer = SubtitleAnalysisTrace(root: root) }

    func start() {
        guard !isRecording, !isStarting else { return }
        runID = UUID(); let token = runID
        enabledAt = HostClock.now(); let start = enabledAt
        isStarting = true; fileURL = nil; recordCount = 0; reservedBytes = 0
        status = String(localized: "正在创建分析文件…")
        queue.async { [weak self, writer] in
            do {
                let url = try writer.start(at: start)
                Task { @MainActor [weak self] in
                    guard let self, self.runID == token, self.isStarting else { return }
                    self.fileURL = url; self.isStarting = false; self.isRecording = true
                    self.status = String(localized: "正在记录本次字幕分析")
                    self.write(["event": "trace_started", "schema": 1,
                                "wall_time": ISO8601DateFormatter().string(from: Date()),
                                "text_included": true, "audio_included": false,
                                "max_bytes": SubtitleAnalysisTrace.maxBytes,
                                "max_records": SubtitleAnalysisTrace.maxRecords,
                                "display_clock": "appkit_update_not_compositor"], at: start)
                }
            } catch {
                Task { @MainActor [weak self] in self?.failed(token: token) }
            }
        }
    }

    func stop(reason: String = "user") {
        guard isRecording || isStarting else { return }
        if isRecording { write(["event": "trace_stopped", "reason": reason], at: HostClock.now()) }
        // A full file may have stopped itself while appending the terminal row; keep that
        // explicit limit status instead of replacing it with the ordinary stop message.
        guard isRecording || isStarting else { return }
        isRecording = false; isStarting = false
        // Invalidate delayed create/write failure callbacks, including when the session ends
        // while its trace file is being opened. Already accepted rows drain before close.
        runID = UUID()
        status = reason == "session_ended" ? String(localized: "本次会话已结束，分析已停止") : String(localized: "分析已停止")
        queue.async { [writer] in writer.stop() }
    }

    func record(_ event: ListenAnalysisEvent, configuration: UInt64, asrStatus: String? = nil) {
        guard isRecording, event.at >= enabledAt else { return }
        let name: String
        switch event.stage {
        case .asrUpdate: name = "asr_update"
        case .sentenceFinal: name = "sentence_final"
        case .mtCompleted: name = "mt_completed"
        }
        var fields: [String: Any] = ["event": name, "configuration": configuration,
                                     "sentence": event.sentence, "delivered_at": HostClock.now()]
        if let source = event.source { fields["source"] = source; fields["source_characters"] = source.count }
        if let translation = event.translation { fields["translation"] = translation }
        if let engine = event.engine { fields[event.stage == .mtCompleted ? "engine" : "configured_engine"] = engine }
        if let asrStatus { fields["actual_asr_status"] = asrStatus }
        if let numberWarning = event.numberWarning { fields["number_warning"] = numberWarning }
        if let audioFrom = event.audioFrom { fields["audio_from"] = audioFrom }
        if let audioThrough = event.audioThrough { fields["audio_through"] = audioThrough }
        write(fields, at: event.at)
    }

    /// Panel observations are captured after board mutation / AppKit label assignment. `visible`
    /// means the panel is ordered onscreen, not proof that no other window occludes it.
    func recordPanel(_ event: String, configuration: UInt64, at: HostTime,
                     line: SubtitleBoard.Line? = nil, kind: String? = nil,
                     visible: Bool, pendingFinals: [UInt64], pendingDraft: UInt64?) {
        guard isRecording else { return }
        var fields: [String: Any] = ["event": event, "configuration": configuration,
                                     "visible": visible, "pending_final_ids": pendingFinals,
                                     "pending_final_count": pendingFinals.count]
        if let pendingDraft { fields["pending_draft_id"] = pendingDraft }
        if let kind { fields["kind"] = kind }
        if let line {
            fields["sentence"] = line.sentence; fields["source"] = line.source
            fields["translation"] = line.text; fields["approx"] = line.approx
            fields["number_warning"] = line.numberWarning
        }
        write(fields, at: at)
    }

    func copyPath() {
        guard let fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
    }

    func revealFile() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func write(_ fields: [String: Any], at time: HostTime) {
        guard isRecording, time >= enabledAt else { return }
        var fields = fields; fields["t"] = time
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        // Reserve before dispatch so even pending disk work stays bounded. The writer enforces
        // the same limit independently and rejects pre-enable events again.
        guard recordCount < SubtitleAnalysisTrace.maxRecords,
              data.count < SubtitleAnalysisTrace.maxBytes - reservedBytes else {
            limitReached(); return
        }
        reservedBytes += data.count + 1; recordCount += 1
        let token = runID
        queue.async { [weak self, writer] in
            do {
                if try writer.append(data, at: time) == .limitReached {
                    Task { @MainActor [weak self] in
                        guard self?.runID == token else { return }; self?.limitReached()
                    }
                }
            } catch {
                Task { @MainActor [weak self] in self?.failed(token: token) }
            }
        }
        if recordCount == SubtitleAnalysisTrace.maxRecords || reservedBytes == SubtitleAnalysisTrace.maxBytes {
            limitReached()
        }
    }

    private func limitReached() {
        isRecording = false; isStarting = false; runID = UUID()
        status = String(localized: "已达到 8 MiB 或 10,000 行上限，分析自动停止")
        queue.async { [writer] in writer.stop() }
    }

    private func failed(token: UUID) {
        guard runID == token else { return }
        isRecording = false; isStarting = false; runID = UUID()
        status = String(localized: "无法写入分析文件，分析已停止")
        queue.async { [writer] in writer.stop() }
    }
}
