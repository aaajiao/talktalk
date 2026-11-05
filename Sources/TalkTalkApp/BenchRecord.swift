#if TALKTALK_DEV
import AppKit
import AVFoundation
import Observation
import SwiftUI
import TalkTalkAudio
import TalkTalkCore
import TalkTalkVoice

/// `--bench record --set t5|t17`: prompts each sentence of a corpus table, records it with the
/// same MicCapture as enrollment, and stores it by id under
/// `~/Library/Application Support/TalkTalk-bench/recordings/<set>/`. Never writes `voice/`.
/// The microphone stays open for the session (bench only); audio between takes is dropped.
@MainActor
@Observable
final class BenchRecordController {
    enum Phase: Equatable {
        case needsStart
        case measuringNoise
        case ready
        case recording
        case reviewed(status: CheckStatus, message: String, saved: Bool)
        case finished
        case failed(String)
    }

    let corpus: BenchCorpusSet
    let store: BenchRecordingStore
    private(set) var phase: Phase = .needsStart
    private(set) var index = 0
    private(set) var levelDb = Levels.floorDb
    private(set) var recordingSeconds = 0.0
    private(set) var recordedIDs: Set<String>
    private(set) var assemblyNote: String?
    var deviceRows: [EnrollmentController.DeviceRow] = []
    var selectedUID: String?

    private var capture: MicCapture?
    private var device: InputDeviceInfo?
    private var noise: [Float] = []
    private var take: [Float] = []
    private var noiseFloorDb = -60.0
    private var detector: AutoStopDetector?
    private var player: AVAudioPlayer?
    private var counter = 0

    init(corpus: BenchCorpusSet, store: BenchRecordingStore = .product) {
        self.corpus = corpus
        self.store = store
        self.recordedIDs = Set(corpus.recordedItems.map(\.id).filter { store.hasTake(set: corpus.set, id: $0) })
        refreshDevices()
        index = corpus.items.firstIndex { $0.needsRecording && !recordedIDs.contains($0.id) } ?? 0
    }

    var item: BenchCorpusSet.Item { corpus.items[index] }
    var progressText: String { "\(recordedIDs.count) / \(corpus.recordedItems.count) 条已录" }
    var allRecorded: Bool { recordedIDs.count == corpus.recordedItems.count }

    func refreshDevices() {
        let infos = InputDeviceCatalog.inputDevices()
        deviceRows = infos.map { .init(info: $0, verdict: RecordingDevicePolicy.evaluate($0)) }
        if selectedUID == nil { selectedUID = RecordingDevicePolicy.preferred(infos)?.uid }
    }

    // MARK: actions

    func startSession() {
        guard phase == .needsStart || isFailed else { return }
        Task {
            guard await MicrophoneAuthorization.request() == .authorized else {
                phase = .failed("没有麦克风权限：请在“系统设置 › 隐私与安全性 › 麦克风”里允许 TalkTalk Dev")
                return
            }
            refreshDevices()
            guard let row = deviceRows.first(where: { $0.id == selectedUID }), row.verdict.isAccepted else {
                phase = .failed("请选一个内建或 USB 麦克风")
                return
            }
            noise = []
            phase = .measuringNoise
            open(row.info)
        }
    }

    func record() {
        guard item.needsRecording else { next(); return }
        switch phase {
        case .ready, .reviewed: break
        default: return
        }
        take = []
        recordingSeconds = 0
        detector = corpus.autoStop
            ? AutoStopDetector(sampleRate: device?.nominalSampleRate ?? 48_000, noiseFloorDb: noiseFloorDb,
                               trailingSilenceSeconds: corpus.silenceStopSeconds ?? 1.0,
                               maxSeconds: corpus.maxSeconds ?? 10)
            : nil
        phase = .recording
    }

    func stop() {
        guard phase == .recording, let device else { return }
        let check = BenchTakeCheck.evaluate(id: item.id, take: take, sampleRate: device.nominalSampleRate,
                                            noiseFloorDb: noiseFloorDb, trim: corpus.autoStop, micUID: device.uid)
        var saved = false
        var message = check.message
        if check.status != .reject {
            do {
                try store.save(check, set: corpus.set)
                recordedIDs.insert(item.id)
                saved = true
            } catch {
                message = "保存失败：\(error)"
            }
        }
        phase = .reviewed(status: check.status, message: message, saved: saved)
        if allRecorded && corpus.set == "t17" { assembleT17() }
    }

    func play() {
        guard let data = try? Data(contentsOf: store.takeURL(set: corpus.set, id: item.id)) else { return }
        player = try? AVAudioPlayer(data: data)
        player?.play()
    }

    func next() {
        guard index + 1 < corpus.items.count else {
            phase = allRecorded ? .finished : .ready
            return
        }
        index += 1
        phase = .ready
    }

    func previous() {
        guard index > 0 else { return }
        index -= 1
        phase = .ready
    }

    func jumpToNextMissing() {
        if let i = corpus.items.firstIndex(where: { $0.needsRecording && !recordedIDs.contains($0.id) }) {
            index = i
            phase = .ready
        }
    }

    func shutdown() {
        capture?.stop()
        capture = nil
    }

    func assembleT17() {
        var takes: [String: WAVFile.Decoded] = [:]
        for item in corpus.recordedItems {
            if let t = store.load(set: corpus.set, id: item.id) { takes[item.id] = t }
        }
        do {
            let a = try T17Assembly.assemble(set: corpus, takes: takes)
            try store.writeAssembly(a, set: corpus.set)
            assemblyNote = String(format: "已生成 zh.wav（%.0f 秒）和 zh.events.json", Double(a.samples.count) / Double(a.sampleRate))
        } catch {
            assemblyNote = "生成 zh.wav 失败：\(error)"
        }
    }

    var summary: [String: Any] {
        ["op": "record", "set": corpus.set, "recorded": recordedIDs.count, "total": corpus.recordedItems.count,
         "dir": "~/Library/Application Support/TalkTalk-bench/recordings/\(corpus.set)",
         "noise_floor_dbfs": noiseFloorDb, "assembly": assemblyNote ?? ""]
    }

    // MARK: capture

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func open(_ info: InputDeviceInfo) {
        do {
            let c = try MicCapture(device: info)
            try c.start(
                onChunk: { [weak self] chunk in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(chunk.samples) } }
                },
                onInterruption: { [weak self] _ in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.capture = nil
                            self?.phase = .failed("麦克风断开或采样率变了；这一条作废，请点“开始”重新连接")
                        }
                    }
                })
            capture = c
            device = info
        } catch {
            phase = .failed("打不开麦克风：\(error)")
        }
    }

    private func consume(_ samples: [Float]) {
        counter += 1
        if counter % 3 == 0 { levelDb = Levels.dbfs(Levels.rms(samples)) }
        guard let rate = device?.nominalSampleRate else { return }
        switch phase {
        case .measuringNoise:
            noise.append(contentsOf: samples)
            if Double(noise.count) >= rate * 1.0 {
                let skip = Int(rate * 0.1)
                noiseFloorDb = Levels.dbfs(Levels.rms(noise[skip...]))
                phase = .ready
            }
        case .recording:
            take.append(contentsOf: samples)
            recordingSeconds = Double(take.count) / rate
            if var d = detector {
                let decision = d.feed(samples)
                detector = d
                if decision != .keepGoing { stop() }
            } else if recordingSeconds >= (corpus.maxSeconds ?? 60) {
                stop()
            }
        default:
            break
        }
    }
}

struct BenchRecordView: View {
    @Bindable var controller: BenchRecordController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("测试录音：\(controller.corpus.set)").font(.title2.bold())
                Spacer()
                Text(controller.progressText).monospacedDigit().foregroundStyle(.secondary)
            }
            if let how = controller.corpus.how {
                Text(how).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let note = controller.assemblyNote { Text(note).font(.callout) }
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .needsStart:
            VStack(alignment: .leading, spacing: 10) {
                Picker("麦克风", selection: $controller.selectedUID) {
                    ForEach(controller.deviceRows) { row in
                        Text(row.verdict.isAccepted ? row.info.name : "\(row.info.name)（\(row.verdict.reason ?? "")）")
                            .tag(Optional(row.id)).selectionDisabled(!row.verdict.isAccepted)
                    }
                }.frame(maxWidth: 420)
                Text("点“开始”后先静音 1 秒测环境噪声。之后每条：按回车开始，读完\(controller.corpus.autoStop ? "停 1 秒自动结束" : "再按回车结束")。已录过的条目会跳过，可以分几次录完。")
                    .foregroundStyle(.secondary)
            }
        case .measuringNoise:
            Text("请保持安静…").font(.title3)
        case .finished:
            Label("这一组都录完了。", systemImage: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            itemView
        }
    }

    private var itemView: some View {
        let item = controller.item
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.id).font(.headline.monospaced())
                if controller.recordedIDs.contains(item.id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                if controller.phase == .recording {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(String(format: "%.1f s", controller.recordingSeconds)).monospacedDigit()
                }
            }
            Text(item.prompt).font(.system(size: 28, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if item.spoken != nil {
                Text("原文：\(item.text)").foregroundStyle(.secondary)
            }
            if let expect = item.expect {
                Text(expect).font(.callout).foregroundStyle(.secondary)
            }
            if !item.needsRecording {
                Text("这一条是轻点，不用录音。").foregroundStyle(.secondary)
            }
            if case let .reviewed(status, message, saved) = controller.phase {
                Label(saved ? (message.isEmpty ? "已保存" : "已保存：\(message)") : message,
                      systemImage: status == .reject ? "xmark.circle.fill" : (status == .warn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                    .foregroundStyle(status == .reject ? .red : (status == .warn ? .orange : .green))
            }
            meter
        }
    }

    private var meter: some View {
        let fraction = max(0, min(1, (controller.levelDb + 60) / 60))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3).fill(controller.levelDb > -3 ? Color.red : Color.green)
                    .frame(width: geo.size.width * fraction)
            }
        }.frame(height: 8)
    }

    private var footer: some View {
        HStack {
            switch controller.phase {
            case .needsStart, .failed:
                Spacer()
                Button("开始") { controller.startSession() }.keyboardShortcut(.defaultAction)
            case .measuringNoise:
                Spacer()
            case .recording:
                Spacer()
                Button(controller.corpus.autoStop ? "结束" : "结束（松键）") { controller.stop() }
                    .keyboardShortcut(.defaultAction)
            case .finished:
                Button("回到第一条缺的") { controller.jumpToNextMissing() }.disabled(controller.allRecorded)
                Spacer()
                if controller.corpus.set == "t17" {
                    Button("重新生成 zh.wav") { controller.assembleT17() }.disabled(!controller.allRecorded)
                }
                Button("关闭") { DevWindowHost.close() }.keyboardShortcut(.defaultAction)
            default:
                Button("上一条") { controller.previous() }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("跳到缺的") { controller.jumpToNextMissing() }
                Spacer()
                if controller.recordedIDs.contains(controller.item.id) {
                    Button("听一下") { controller.play() }.keyboardShortcut("p", modifiers: [])
                }
                Button("下一条") { controller.next() }.keyboardShortcut(.rightArrow, modifiers: [])
                if controller.item.needsRecording {
                    Button(controller.recordedIDs.contains(controller.item.id) ? "重录（回车）" : "录这一条（回车）") {
                        controller.record()
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

@MainActor
enum BenchRecordWindow {
    static func run(set: String?, corpus: String?, outPath: String?, smoke: Bool) -> Never {
        requireLaunchServices("record", outPath: outPath)
        guard let set else {
            writeResult(["op": "record", "error": "--set t5|t17 is required"], to: outPath)
            exit(2)
        }
        guard let dir = BenchCorpusSet.locateCorpusDir(explicit: corpus, startingAt: Bundle.main.bundleURL) else {
            writeResult(["op": "record", "error": "tools/bench/corpus not found; pass --corpus <dir>"], to: outPath)
            exit(2)
        }
        let table: BenchCorpusSet
        do {
            table = try BenchCorpusSet.load(set, corpusDir: dir)
        } catch {
            writeResult(["op": "record", "error": "cannot load corpus set '\(set)': \(error)"], to: outPath)
            exit(2)
        }
        let controller = BenchRecordController(corpus: table)
        DevWindowHost.run(
            title: "TalkTalk Dev — 测试录音 \(set)", size: NSSize(width: 720, height: 600),
            view: BenchRecordView(controller: controller),
            onClose: {
                controller.shutdown()
                writeResult(controller.summary, to: outPath)
            },
            smoke: smoke ? {
                var r = controller.summary
                r["smoke"] = true
                r["window_opened"] = true
                r["items"] = table.items.count
                writeResult(r, to: outPath)
            } : nil)
    }
}
#endif
