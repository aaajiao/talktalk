import SwiftUI
import TalkTalkAudio

/// The "我的声音" recording UI (ARCHITECTURE.md §9.2). Embeds anywhere: the dev window of
/// `--bench enroll`, the M1 onboarding and the M2 settings page. `onClose` is called by the
/// "完成" / "关闭" buttons; the host decides what closing means.
public struct EnrollmentView: View {
    @Bindable var controller: EnrollmentController
    var onClose: (() -> Void)?

    public init(controller: EnrollmentController, onClose: (() -> Void)? = nil) {
        self.controller = controller
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            steps
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .topLeading).padding(.vertical, 4)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 520)
    }

    // MARK: - parts

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.wave.2.fill").font(.system(size: 32))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.hasExistingProfile ? "重新录制我的声音" : "创建我的声音").font(.title2.bold())
                Label(controller.hasExistingProfile ? "新档案保存前，继续使用原有声音。" : "录一段中文，用你的声音说英语和德语。",
                      systemImage: controller.hasExistingProfile ? "checkmark.shield" : "waveform")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var currentStep: Int {
        switch controller.phase {
        case .idle, .measuringNoise, .countdown, .recording: 1
        case .analyzing, .review: 2
        case .auditioning, .auditionReview, .saving, .saved: 3
        case .failed: 0
        }
    }

    private var steps: some View {
        HStack(spacing: 12) {
            step(1, title: "录制中文", symbol: "mic")
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            step(2, title: "自动检查", symbol: "checkmark.shield")
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            step(3, title: "试听与保存", symbol: "headphones")
        }
        .padding(.vertical, 8)
    }

    private func step(_ number: Int, title: LocalizedStringKey, symbol: String) -> some View {
        let completed = number < currentStep || controller.phase == .saved
        return VStack(spacing: 6) {
            Image(systemName: completed ? "checkmark.circle.fill" : symbol)
                .font(.title2).accessibilityHidden(true)
            Text(title).font(.callout.weight(number == currentStep ? .semibold : .regular))
        }
        .foregroundStyle(completed ? Color.green : number == currentStep ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(completed
            ? String(localized: "已完成")
            : number == currentStep ? String(localized: "当前步骤") : String(localized: "待完成")))
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            idleView
        case .measuringNoise:
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("请先保持安静").font(.title3.weight(.semibold))
                    ProgressView(value: controller.noiseProgress)
                    Text("测量环境噪声后，会倒数 3 秒再开始录制。").font(.callout).foregroundStyle(.secondary)
                    meter
                }.padding(8)
            } label: { Label("准备麦克风", systemImage: "waveform") }
        case let .countdown(n):
            GroupBox {
                VStack(spacing: 14) {
                    Text("\(n)").font(.system(size: 72, weight: .bold, design: .rounded)).frame(maxWidth: .infinity)
                    scriptText.opacity(0.5)
                    meter
                }.padding(8)
            } label: { Label("准备朗读", systemImage: "timer") }
        case .recording:
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("正在录音", systemImage: "record.circle.fill").foregroundStyle(.red)
                        Spacer()
                        Text(String(format: "%.1f 秒", controller.recordingSeconds)).monospacedDigit()
                    }
                    scriptText
                    meter
                    Text("读完稍作停顿，会自动结束录制。也可以点“完成录制”。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(8)
            } label: { Label("请自然朗读", systemImage: "text.quote") }
        case .analyzing:
            ProgressView("正在检查录音质量…").controlSize(.small).padding(.vertical, 20)
        case let .review(report):
            reviewView(report)
        case .auditioning:
            ProgressView("正在准备你的声音并生成英语、德语试听…").controlSize(.small).padding(.vertical, 20)
        case let .auditionReview(summary):
            auditionView(summary)
        case .saving:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在保存…")
            }
        case .saved:
            savedView
        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    devicePicker
                    Label("找个安静的地方，使用自然语速和音量，离麦克风一拳左右。", systemImage: "person.wave.2")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(8)
            } label: { Label("录制准备", systemImage: "mic") }
            GroupBox {
                scriptText.padding(12)
            } label: { Label("朗读这段中文", systemImage: "text.quote") }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").accessibilityHidden(true)
                Text("开始后先测量环境噪声，再倒数 3 秒。录音仅保存在这台 Mac，不上传。")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var devicePicker: some View {
        HStack {
            Picker("麦克风", selection: $controller.selectedUID) {
                ForEach(controller.devices) { row in
                    Text(row.verdict.isAccepted ? row.info.name : "\(row.info.name)（\(row.verdict.reason ?? "")）")
                        .tag(Optional(row.id))
                        .selectionDisabled(!row.verdict.isAccepted)
                }
            }
            .frame(maxWidth: 420)
            Button("刷新") { controller.refreshDevices() }
        }
    }

    private var scriptText: some View {
        Text(controller.script.text)
            .font(.system(size: 26, weight: .medium))
            .lineSpacing(8)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
    }

    private var meter: some View {
        let fraction = max(0, min(1, (controller.levelDb + 60) / 60))
        return VStack(alignment: .leading, spacing: 5) {
            Text("输入音量").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: fraction).tint(controller.levelDb > -3 ? Color.red : Color.green)
                .accessibilityLabel("输入音量")
        }
    }

    private func reviewView(_ report: EnrollmentReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let headline = report.headline {
                Text(headline).font(.title3).foregroundStyle(report.canSave ? Color.primary : Color.red)
            } else {
                Text("这一遍可以用。").font(.title3)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(report.results, id: \.id) { r in
                        HStack(alignment: .top, spacing: 10) {
                            statusIcon(r.status)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.id.title).fontWeight(.medium)
                                Text(r.message).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Text(valueText(r)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }.padding(8)
            } label: { Label("录音检查", systemImage: "checkmark.shield") }
            Text(String(format: "语速约 %.1f 字/秒（用于估计说话节奏）", report.measurements.speakingRateCharsPerSecond))
                .font(.callout).foregroundStyle(.secondary)
            if !controller.engineAvailable {
                Text("引擎尚未就绪：可以先保存录音，声音准备和英语、德语试听将在引擎就绪后完成。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// §9.2 step 7: listen before saving. Playback goes to the monitor output (headphones or the
    /// default output), never into TalkTalk Mic.
    private func auditionView(_ summary: AuditionResult.Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if summary.passed {
                Text("试听已生成。戴上耳机听一听，满意就保存。").font(.title3)
            } else {
                Text("试听没通过（已自动重新生成一次）：\(summary.failureText ?? "")。建议重录一遍。")
                    .font(.title3).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(summary.clips, id: \.lang) { c in
                GroupBox {
                    HStack(spacing: 12) {
                        statusIcon(c.failure == nil ? .pass : .reject)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.lang == .en ? "英语" : "德语").font(.headline)
                            Text(c.wer.map { String(format: "回读错误率 %.0f%%", $0 * 100) } ?? "—")
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            if c.attempts > 1 { Text("第 \(c.attempts) 次生成").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(controller.playingAudition == c.lang ? "停止" : "试听") {
                            if controller.playingAudition == c.lang { controller.stopAudition() } else { controller.playAudition(c.lang) }
                        }
                        .disabled(controller.playingAudition != c.lang
                            && (controller.audition?.clip(c.lang)?.samples.isEmpty ?? true))
                    }.padding(8)
                }
            }
            if let e = controller.auditionPlaybackError {
                Text("播放不了：\(e)").font(.callout).foregroundStyle(.red)
            }
            Label("试听在耳机或当前播放设备中响起，不发送到会议。", systemImage: "headphones")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var savedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("已保存", systemImage: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
            if let p = controller.savedProfile {
                Text(String(format: "参考音 %.1f 秒，语速 %.1f 字/秒。", p.durationSeconds, p.speakingRateCharsPerSecond))
            }
            Label("声音档案仅保存在这台 Mac。", systemImage: "lock.shield").foregroundStyle(.secondary)
            DisclosureGroup("存储位置") {
                Text(verbatim: "~/Library/Application Support/TalkTalk/voice/")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(controller.machine.takes > 0 ? "第 \(controller.machine.takes) 遍" : "")
                .foregroundStyle(.secondary)
            Spacer()
            switch controller.phase {
            case .idle:
                Button("关闭") { onClose?() }
                Button("开始录制") { controller.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(controller.selectedDevice?.verdict.isAccepted ?? false))
            case .measuringNoise, .countdown:
                Button("取消") { controller.cancel() }
            case .recording:
                Button("取消") { controller.cancel() }
                Button("完成录制") { controller.finishRecording() }.keyboardShortcut(.defaultAction)
            case .analyzing, .saving, .auditioning:
                EmptyView()
            case let .auditionReview(summary):
                Button("放弃") { controller.cancel() }
                Button("重录") { controller.retake() }
                Button("保存") { controller.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!summary.passed)
            case let .review(report):
                Button("放弃") { controller.cancel() }
                Button("重录") { controller.retake() }
                Button(controller.engineAvailable ? "生成试听" : "保存声音档案") { controller.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!report.canSave)
            case .saved:
                Button("完成") { onClose?() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("关闭") { onClose?() }
                Button("再试一次") { controller.start() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func statusIcon(_ s: CheckStatus) -> some View {
        switch s {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .reject: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    private func valueText(_ r: CheckResult) -> String {
        guard let v = r.value else { return "—" }
        switch r.id {
        case .duration, .pause: return String(format: "%.1f s", v)
        case .clipping: return String(format: "%.3f%%", v * 100)
        case .level, .noiseFloor: return String(format: "%.0f dBFS", v)
        case .snr: return String(format: "%.0f dB", v)
        case .transcript: return String(format: "CER %.0f%%", v * 100)
        case .audition: return "—"
        }
    }
}
