// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSettingsUI

/// The "我的声音" recording UI (ARCHITECTURE.md, "引擎、翻译与播放", settings visual system §7.7). Embeds
/// anywhere: the dev window of `--bench enroll`, onboarding and the settings page. `onClose` is
/// called by the "完成" / "关闭" buttons; the host decides what closing means. No title: the
/// StepTrack says where the take is, each phase shows only its few words, and every check's
/// message is its help.
public struct EnrollmentView: View {
    @Bindable var controller: EnrollmentController
    var onClose: (() -> Void)?

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    /// The take's smallest height: a host shorter than this (onboarding step 6) scrolls it.
    public static let minimumHeight: Double = 520

    public init(controller: EnrollmentController, onClose: (() -> Void)? = nil) {
        self.controller = controller
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            steps
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .topLeading).padding(.vertical, 4)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: Self.minimumHeight)
    }

    // MARK: - StepTrack (§3.5)

    /// 1 录音 (until the take stops), 2 检查 (until its results are read), 3 试听保存; 0 after
    /// a failure.
    private var currentStep: Int {
        switch controller.phase {
        case .idle, .measuringNoise, .countdown, .recording: 1
        case .analyzing, .review: 2
        case .auditioning, .auditionReview, .saving, .saved: 3
        case .failed: 0
        }
    }

    /// Something runs in this step now (capture, checking, generating or saving).
    private var working: Bool {
        switch controller.phase {
        case .measuringNoise, .countdown, .recording, .analyzing, .auditioning, .saving: true
        case .idle, .review, .auditionReview, .saved, .failed: false
        }
    }

    private func stepState(_ number: Int) -> StepState {
        if controller.phase == .saved || number < currentStep { return .done }
        if number == currentStep {
            if working { return .busy }
            // The checks have run once their results are on screen.
            if case .review = controller.phase { return .done }
        }
        return .todo
    }

    /// Later steps wait (dimmed), except 试听保存 while the checks' results invite 保存.
    private func nodeState(_ number: Int) -> NodeState {
        if case .review = controller.phase, number == 3 { return .ready }
        return currentStep > 0 && number > currentStep ? .dimmed : .ready
    }

    private var steps: some View {
        var checkBadge: (SettingsStatus, String)?
        var auditionBadge: (SettingsStatus, String)?
        switch controller.phase {
        case let .review(report) where !report.canSave:
            checkBadge = (.failed, String(appLocalized: "未通过"))
        case let .review(report) where report.worst == .warn:
            checkBadge = (.warn, String(appLocalized: "有提醒"))
        case let .auditionReview(summary) where !summary.passed:
            auditionBadge = (.failed, String(appLocalized: "未通过"))
        default:
            break
        }
        return FlowGrid(String(appLocalized: "录制步骤"), lanes: [
            FlowLane(String(appLocalized: "录制步骤"), cells: [
                .node(FlowNode(String(appLocalized: "录音"), glyph: .step(1, stepState(1)), state: nodeState(1))),
                .node(FlowNode(String(appLocalized: "检查"), glyph: .step(2, stepState(2)), state: nodeState(2),
                               badge: checkBadge?.0, badgeReason: checkBadge?.1)),
                .node(FlowNode(String(appLocalized: "试听保存"), glyph: .step(3, stepState(3)), state: nodeState(3),
                               badge: auditionBadge?.0, badgeReason: auditionBadge?.1)),
                .empty
            ])
        ])
    }

    // MARK: - phases

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            prepare
        case .measuringNoise:
            VStack(alignment: .leading, spacing: 12) {
                Text("请先保持安静").font(.title3.weight(.semibold))
                ProgressView(value: controller.noiseProgress)
                    .accessibilityLabel(String(appLocalized: "测量环境噪声"))
                meter
            }
        case let .countdown(n):
            VStack(spacing: 14) {
                Text(verbatim: "\(n)")
                    .font(.system(size: Ladder.enrollmentCountdown, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(String(appLocalized: "\(n) 秒后开始"))
                scriptText.opacity(0.5)
                meter
            }
        case .recording:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: Icon.recordingActive)
                        .font(.system(size: Ladder.row))
                        .foregroundStyle(.red)
                        .accessibilityLabel(String(appLocalized: "正在录音"))
                    Text("请自然朗读").font(.title3.weight(.semibold))
                    Spacer()
                    Text(String(appLocalized: "\(Self.decimal(controller.recordingSeconds)) 秒")).monospacedDigit()
                }
                scriptText
                meter
            }
        case .analyzing:
            progress(String(appLocalized: "检查中…"))
        case let .review(report):
            reviewView(report)
        case .auditioning:
            progress(String(appLocalized: "生成试听…"))
        case let .auditionReview(summary):
            auditionView(summary)
        case .saving:
            progress(String(appLocalized: "保存中…"))
        case .saved:
            VStack(alignment: .leading, spacing: 10) {
                StatusLabel(String(appLocalized: "已保存"), .ok)
                FactRow([FactChip(String(appLocalized: "仅本机"), symbol: Icon.privacyPromise,
                                  help: String(appLocalized: "声音档案只保存在这台 Mac"))])
            }
        case let .failed(message):
            let problem = SettingsProblem(.failed, sentence: message)
            StatusLabel(problem.text, problem.status, help: problem.help)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: text).foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    /// The microphone, the facts of a take, and the script.
    private var prepare: some View {
        var facts = [
            FactChip(String(appLocalized: "约 10–20 秒"), symbol: Icon.duration, help: String(appLocalized: "按平时语速读完全文")),
            FactChip(String(appLocalized: "安静 · 离麦一拳"), symbol: Icon.listen, help: String(appLocalized: "自然语速和音量")),
            FactChip(String(appLocalized: "仅本机 · 不上传"), symbol: Icon.privacyPromise,
                     help: String(appLocalized: "录音只保存在这台 Mac"))
        ]
        if controller.hasExistingProfile {
            facts.append(FactChip(String(appLocalized: "旧档案保留到保存"), symbol: Icon.verify,
                                  help: String(appLocalized: "新档案保存前继续用原有声音")))
        }
        return VStack(alignment: .leading, spacing: 14) {
            devicePicker
            FactRow(facts)
            scriptText
        }
    }

    private var devicePicker: some View {
        HStack(spacing: 8) {
            // Nothing acceptable to pick: say why 开始录制 is gray, as 音频 does.
            if !controller.devices.contains(where: { $0.verdict.isAccepted }) {
                StatusLabel(String(appLocalized: "无可用麦克风"), .failed,
                            help: String(appLocalized: "没有可用的麦克风（只支持内建麦克风或 USB 麦克风）"))
            }
            Picker(selection: $controller.selectedUID) {
                ForEach(controller.devices) { row in
                    Text(verbatim: row.verdict.isAccepted
                        ? row.info.name : String(appLocalized: "\(row.info.name)（\(row.verdict.reason ?? "")）"))
                        .tag(Optional(row.id))
                        .selectionDisabled(!row.verdict.isAccepted)
                }
            } label: {
                Label("麦克风", systemImage: Icon.physicalMic).labelStyle(.settingsRow)
            }
            .frame(maxWidth: 420)
            IconButton(Icon.refresh, help: String(appLocalized: "刷新"),
                       accessibilityLabel: String(appLocalized: "刷新麦克风列表")) { controller.refreshDevices() }
        }
    }

    private var scriptText: some View {
        Text(verbatim: controller.script.text)
            .font(.system(size: Ladder.enrollmentScript, weight: .medium))
            .lineSpacing(8)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
    }

    private var meter: some View {
        let fraction = max(0, min(1, (controller.levelDb + 60) / 60))
        let clipping = controller.levelDb > -3
        return HStack(spacing: 8) {
            Image(systemName: Icon.physicalMic)
                .font(.system(size: Ladder.row))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ProgressView(value: fraction)
                .tint(clipping ? Color.red : Color.green)
                .accessibilityLabel(String(appLocalized: "输入音量"))
                .accessibilityValue(Text(verbatim: clipping ? String(appLocalized: "削波")
                                                            : fraction.formatted(.percent.precision(.fractionLength(0)))))
            // Not by color alone: the shape and the word for those who cannot tell red from green.
            if clipping { StatusGlyph(.warn).accessibilityHidden(true) }
        }
    }

    /// 可以用, or the first failed check; then each check as its glyph and name (the message is
    /// its help).
    private func reviewView(_ report: EnrollmentReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rejected = report.results.first(where: { $0.status == .reject }) {
                StatusLabel(String(appLocalized: "未通过：\(rejected.id.title) · 建议重录"), .failed, help: rejected.message)
            } else {
                StatusLabel(String(appLocalized: "可以用"), .ok, help: report.headline)
            }
            ForEach(report.results, id: \.id) { result in
                HStack(spacing: 8) {
                    StatusGlyph(Self.status(result.status)).accessibilityHidden(true)
                    Text(verbatim: result.id.title)
                }
                .padding(.leading, Ladder.rowTextInset - Ladder.rowColumn)
                .help(ifPresent: result.message.isEmpty ? nil : result.message)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(verbatim: [Self.status(result.status).spokenName, result.message]
                    .filter { !$0.isEmpty }.joined(separator: String(appLocalized: "，"))))
            }
            if !controller.engineAvailable {
                StatusLabel(String(appLocalized: "引擎就绪后生成试听"), .waiting,
                            help: String(appLocalized: "可以先保存录音，引擎就绪后再准备声音和试听"))
            }
        }
    }

    /// §9.2 step 7: listen before saving. Playback goes to the monitor output (headphones or the
    /// default output), never into TalkTalk Mic.
    private func auditionView(_ summary: AuditionResult.Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failed = summary.clips.first(where: { $0.failure != nil }), let failure = failed.failure {
                StatusLabel(String(appLocalized: "未通过：\(Self.code(failed.lang)) \(failure.text) · 建议重录"), .failed,
                            help: String(appLocalized: "已自动重新生成一次"))
            } else if controller.auditionUnavailableReason == nil {
                FactRow([FactChip(String(appLocalized: "戴耳机试听"), symbol: Icon.headphones,
                                  help: String(appLocalized: "满意就保存"))])
            }
            // The monitor output cannot play now (meeting mode, no output): saving still works.
            if let reason = controller.auditionUnavailableReason {
                StatusLabel(String(appLocalized: "自听输出不可用"), .warn, help: reason)
            }
            ForEach(summary.clips, id: \.lang) { clip in
                let playing = controller.playingAudition == clip.lang
                let name = clip.lang == .en ? String(appLocalized: "试听英语") : String(appLocalized: "试听德语")
                HStack(spacing: 8) {
                    StatusGlyph(clip.failure == nil ? .ok : .failed)
                        .accessibilityLabel(clip.failure.map(\.text) ?? SettingsStatus.ok.spokenName)
                    Text(verbatim: Self.code(clip.lang)).font(.body.weight(.medium))
                    IconButton(playing ? Icon.stop : Icon.start,
                               help: playing ? String(appLocalized: "停止") : controller.auditionUnavailableReason ?? name,
                               accessibilityLabel: playing ? String(appLocalized: "停止\(name)") : name) {
                        if playing { controller.stopAudition() } else { controller.playAudition(clip.lang) }
                    }
                    .disabled(!playing && (controller.auditionUnavailableReason != nil
                                           || (controller.audition?.clip(clip.lang)?.samples.isEmpty ?? true)))
                }
                .padding(.leading, Ladder.rowTextInset - Ladder.rowColumn)
            }
            if let error = controller.auditionPlaybackError {
                StatusLabel(String(appLocalized: "无法播放"), .warn, help: error)
            }
            FactRow([FactChip(String(appLocalized: "本机播放"), symbol: Icon.thisMac,
                              help: String(appLocalized: "试听不发送到会议"))])
        }
    }

    private var footer: some View {
        HStack {
            if controller.machine.takes > 0 {
                Text(String(appLocalized: "第 \(controller.machine.takes) 遍")).foregroundStyle(.secondary)
            }
            Spacer()
            switch controller.phase {
            case .idle:
                Button("关闭") { onClose?() }
                let canStart = controller.selectedDevice?.verdict.isAccepted ?? false
                Button("开始录制") { controller.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .help(ifPresent: canStart ? nil : String(appLocalized: "没有可用的麦克风（只支持内建麦克风或 USB 麦克风）"))
            case .measuringNoise, .countdown:
                Button("取消") { controller.cancel() }.keyboardShortcut(.cancelAction)
            case .recording:
                Button("取消") { controller.cancel() }.keyboardShortcut(.cancelAction)
                Button("完成录制") { controller.finishRecording() }.keyboardShortcut(.defaultAction)
            case .analyzing, .saving:
                EmptyView()
            case .auditioning:
                // Generating the audition can take a while: leaving restores the saved voice.
                Button("取消") { controller.cancel() }
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
                // With an engine 保存 first makes the audition (step 3), without one it saves.
                Button("保存") { controller.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!report.canSave)
            case .saved:
                Button("完成") { onClose?() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("关闭") { onClose?() }
                // A microphone failure goes back to choosing the microphone; the rest record again.
                Button("再试一次") {
                    if controller.failureNeedsDeviceChoice { controller.cancel() } else { controller.start() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private static func status(_ status: CheckStatus) -> SettingsStatus {
        switch status {
        case .pass: .ok
        case .warn: .warn
        case .reject: .failed
        case .pending: .waiting
        }
    }

    private static func code(_ lang: Lang) -> String { lang == .en ? "EN" : "DE" }

    private static func decimal(_ value: Double) -> String { String(format: "%.1f", value) }
}
