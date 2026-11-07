// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Foundation
import Observation
import SwiftUI
import TalkTalkCore
import TalkTalkSettingsUI
import TalkTalkVoice

/// Settings › 我的声音 (ARCHITECTURE.md §11, §9.2–§9.4). An overview of the saved profile with
/// 试听 / 重录 / 删除, and the recording flow itself, which is TalkTalkVoice's `EnrollmentView` +
/// `EnrollmentController` from the app's one `VoiceLifecycle` (EngineHost's): every write goes through
/// its queue, never VoiceStore directly. Saves to the real
/// `~/Library/Application Support/TalkTalk/voice/`, shared by TalkTalk.app and TalkTalk-Dev.app.
@MainActor
@Observable
final class MyVoiceModel {
    let store: VoiceStore
    private(set) var profile: VoiceProfile?
    private(set) var profileUnreadable = false
    /// Non-nil while the recording flow is on screen. A fresh controller per visit, so a finished
    /// or abandoned take never leaks into the next one.
    private(set) var enrollment: EnrollmentController?
    /// The 删除… confirmation dialog.
    var confirmDelete = false
    private(set) var deleting = false
    /// 试听: which language is being prepared or played, and why it could not play.
    private(set) var auditioning: Lang?
    private(set) var auditionProblem: String?
    /// 停止 was pressed: a play still being generated is skipped. Observed, so the button shows
    /// play (disabled) at once instead of waiting for the generation to end.
    private(set) var auditionStopped = false
    /// Whether the lifecycle's monitor output can play (read when the page appears and when the
    /// engine instance changes); false: 试听 is grayed out with the monitor's reason.
    private(set) var monitorAvailable = false
    private(set) var monitorUnavailableReason: String?
    @ObservationIgnored private var monitorReadToken = UUID()
    /// Shown after a take was dropped because the engine instance changed under it.
    private(set) var recordingNote: String?
    /// Set by AppDelegate right after construction (onboarding builds its own MyVoiceModel).
    /// The lifecycle is read from it each time: it is rebuilt with the engine instance.
    var engineHost: EngineHost?
    @ObservationIgnored var externalBusy: () -> Bool = { false }
    private var lifecycle: VoiceLifecycle? { engineHost?.lifecycle }
    /// The lifecycle the open recording flow was made from (item 4 of the listen review).
    @ObservationIgnored private var enrollmentSource: VoiceLifecycle?
    @ObservationIgnored private var monitorReadFor: VoiceLifecycle?
    private let onChange: () -> Void
    /// Settings › 安装与维护's installer; while it runs no audition and no new take.
    private let components: EngineComponentsModel

    init(store: VoiceStore, engineHost: EngineHost? = nil, components: EngineComponentsModel = AppUIModels.shared.engine,
         onChange: @escaping () -> Void = {}) {
        self.store = store
        self.engineHost = engineHost
        self.components = components
        self.onChange = onChange
        reload()
        track()
    }

    var installerRunning: Bool { components.running }
    /// The same installed-resource facts used by 安装与维护; no engine is started to read them.
    var synthesisProblem: SettingsProblem? { components.synthesisProblem }
    var synthesisModelName: String? { components.modelName(role: "tts") }
    func refreshSynthesisResources() { components.reload() }
    /// The installer runs and the take is past capture: the flow is held (no save starts).
    var saveBlocked: Bool { installerRunning && !recordingActive }

    var hasProfile: Bool { store.hasProfile }

    func reload() {
        if store.hasProfile {
            profile = try? store.loadProfile()
            profileUnreadable = profile == nil
        } else {
            profile = nil
            profileUnreadable = false
        }
    }

    func beginRecording() {
        guard enrollment == nil, !deleting, !installerRunning, !externalBusy(), let lifecycle else { return }
        auditionProblem = nil
        enrollment = lifecycle.makeEnrollment()
        enrollmentSource = lifecycle
    }

    /// The view's "关闭" / "完成", the settings window closing, or the app quitting.
    func endRecording() {
        enrollment?.cancelIfActive()
        enrollment = nil
        enrollmentSource = nil
        recordingNote = nil
        reload()
        onChange()
    }

    /// §9.4 through the lifecycle: SPEAK switches to the system voice first, queued voice work is
    /// cancelled, only our files are deleted, `/v1/voice/unload` last, passthrough gains cleared.
    func deleteProfile() {
        guard !deleting, !externalBusy(), let lifecycle else { return }
        deleting = true
        Task {
            await lifecycle.delete()
            deleting = false
            reload()
            onChange()
        }
    }

    /// 试听 English / Deutsch: generate the saved profile's audition once (or reuse it), then play
    /// it on the monitor output (never TalkTalk Mic). Without an engine or a monitor output, the
    /// reason is shown instead.
    func audition(_ lang: Lang) {
        guard auditioning == nil, canAudition, let lifecycle else { return }
        let engine = engineHost?.engine()
        auditioning = lang
        auditionProblem = nil
        auditionStopped = false
        Task {
            do {
                if lifecycle.savedAudition == nil {
                    // The audition starts the engine: let it idle out afterwards (§7.6), also on failure.
                    do { _ = try await lifecycle.audition() } catch { await engine?.enrollmentFinished(); throw error }
                    await engine?.enrollmentFinished()
                }
                if !auditionStopped { try await lifecycle.play(lang) }
            } catch let e as AuditionMonitorError {
                auditionProblem = e.description
            } catch {
                auditionProblem = String(localized: "试听没有生成：\(String(describing: error))")
            }
            auditioning = nil
            reload()
            refreshMonitorAvailability()
        }
    }

    /// 停止 on the playing language: ends the playback (the play call returns normally), or
    /// skips it while the audition is still being generated.
    func stopAudition() {
        guard auditioning != nil, let lifecycle else { return }
        auditionStopped = true
        Task { await lifecycle.monitor.stop() }
    }

    /// The folder button beside 仅本机 · 不上传.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.voiceURL])
    }

    var engineAvailable: Bool { lifecycle?.engine != nil }
    var canAudition: Bool {
        engineAvailable && monitorAvailable && !installerRunning && !externalBusy() && auditioning == nil && !deleting
    }

    /// 我的声音's one problem line (§7.7): only the most severe. The monitor counts once it has
    /// been read (its reason, not `monitorAvailable`, which is false until then).
    var problem: SettingsProblem? {
        let saved = profile != nil
        return SettingsProblem.mostSevere([
            externalBusy() ? SettingsProblem(.waiting, String(localized: "自检中")) : nil,
            saved && !engineAvailable ? SettingsProblem(.waiting, String(localized: "引擎就绪后可试听"),
                                                          help: String(localized: "试听经自听输出播到耳机，不进 TalkTalk Mic")) : nil,
            installerRunning ? SettingsProblem(.waiting, String(localized: "组件安装中")) : nil,
            saved && engineAvailable ? monitorUnavailableReason.map {
                SettingsProblem(.warn, String(localized: "自听输出不可用"), help: $0)
            } : nil,
            auditionProblem.map { SettingsProblem(.warn, String(localized: "试听失败"), help: $0) },
            profileUnreadable ? SettingsProblem(.warn, String(localized: "声音档案无法读取 · 请重录")) : nil,
            recordingNote.map { SettingsProblem(.warn, String(localized: "引擎已切换 · 请重录"), help: $0) }
        ])
    }

    // MARK: following the engine instance

    /// Observes the host, its lifecycle and the open take's phase; every change runs `reconcile`.
    /// One chain, started in init: each change re-arms it.
    private func track() {
        withObservationTracking {
            _ = engineHost?.lifecycle
            _ = enrollment?.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconcile()
                self?.track()
            }
        }
        reconcile()
    }

    private func reconcile() {
        if let l = lifecycle, monitorReadFor !== l {
            refreshMonitorAvailability()
        } else if lifecycle == nil {
            monitorReadFor = nil
            monitorReadToken = UUID()
            monitorAvailable = false
            monitorUnavailableReason = nil
        }
        // An open take from a lifecycle that was dropped must not commit through its engine,
        // routing and queue: start again from the current one.
        guard let e = enrollment, let from = enrollmentSource, from !== lifecycle else { return }
        switch e.phase {
        case .idle, .failed:
            restartRecording(note: nil)
        case .saved:
            endRecording()
        case .saving:
            break   // already handed to the old queue; reconciled again once it is saved or failed
        default:
            if e.phase.capturing { break }   // let the take finish; dropped as soon as it stops
            restartRecording(note: String(localized: "引擎刚刚换过，这一遍没有保存，请再录一遍。"))
        }
    }

    private func restartRecording(note: String?) {
        enrollment?.cancelIfActive()
        enrollment = nil
        enrollmentSource = nil
        recordingNote = note
        beginRecording()
    }

    /// The page appeared: read the monitor again (it may have been plugged in meanwhile).
    func refreshMonitor() { refreshMonitorAvailability() }

    /// Called by the app on meeting/route changes, and after audition playback finishes or fails.
    func refreshMonitorAvailability() {
        guard let lifecycle else { monitorReadToken = UUID(); monitorReadFor = nil; monitorAvailable = false; monitorUnavailableReason = nil; return }
        monitorReadFor = lifecycle
        let token = UUID(); monitorReadToken = token
        Task {
            let reason = await lifecycle.monitor.unavailableReason
            guard monitorReadToken == token, monitorReadFor === lifecycle else { return }
            monitorAvailable = reason == nil
            monitorUnavailableReason = reason
        }
    }
    var canRecord: Bool { lifecycle != nil }

    var recordingActive: Bool { enrollment?.phase.capturing ?? false }
}


/// Settings › 我的声音 (settings visual system §7.7). The page opens with its flow: 录中文 with
/// the page's one primary action, the profile, and 试听 in English and German, followed by the
/// translated-voice path; then one problem line, safety facts and a native delete button. Recording replaces the
/// page with TalkTalkVoice's `EnrollmentView`. The profile's details are under 隐私与诊断 ›
/// 故障检查 › 技术详情.
struct MyVoiceSettingsView: View {
    // No @State: the CLT toolchain has no SwiftUIMacros plugin, so view state lives in the model.
    @Bindable var model: MyVoiceModel
    var navigation: SettingsNavigation? = nil
    var driver: DriverComponentsPage? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    private typealias Icon = SubtitleTokens.SettingsIcon

    var body: some View {
        ZStack {
            content
        }
        .onAppear {
            model.refreshSynthesisResources()
            driver?.load()
        }
    }

    @ViewBuilder private var content: some View {
        if let controller = model.enrollment {
            VStack(alignment: .leading, spacing: 0) {
                if model.recordingNote != nil || model.saveBlocked {
                    HStack(spacing: 8) {
                        if let note = model.recordingNote {
                            StatusLabel(String(localized: "引擎已切换 · 请重录"), .warn, help: note)
                        }
                        if model.saveBlocked {
                            StatusLabel(String(localized: "组件安装中"), .waiting,
                                        help: String(localized: "引擎组件正在安装或修复，完成后再保存"))
                            Spacer(minLength: 8)
                            // The flow below is held, its own 关闭 too: this one stays usable.
                            Button("关闭") { model.endRecording() }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                // While the installer runs nothing is saved (the take itself may finish).
                EnrollmentView(controller: controller, onClose: { model.endRecording() })
                    .disabled(model.saveBlocked)
            }
        } else {
            overview
                .disabled(model.externalBusy())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear {
                    model.refreshMonitor()
                    // System-voice users can read the overview too. The existing 录制 button
                    // explicitly opens the recording flow, whether or not a profile exists.
                }
        }
    }

    private var overview: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    FlowGrid.myVoice(model, driver: driver, links: links)
                    if let problem = SettingsProblem.mostSevere([model.problem, model.synthesisProblem]) {
                        StatusLabel(problem.text, problem.status, help: problem.help)
                    }
                    facts
                    synthesisFacts
                }
                .padding(.vertical, 4)
            }
            if model.hasProfile {
                Section {
                    LabeledContent {
                        SettingsDestructiveButton(String(localized: "删除…"), help: String(localized: "删除声音档案"),
                                                  accessibilityLabel: String(localized: "删除声音档案")) {
                            model.confirmDelete = true
                        }
                            .disabled(model.deleting || !model.canRecord)
                    } label: {
                        Label("声音档案", systemImage: Icon.myVoice)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .labelStyle(.settingsRow)
        .alert("删除声音档案？", isPresented: $model.confirmDelete) {
            Button("取消", role: .cancel) {}
            // macOS uses its ordinary confirmation button after the explicit delete request.
            Button("删除声音档案") { model.deleteProfile() }
        } message: {
            Text("参考音、稿子和声音缓存从这台 Mac 删除；之后译音用系统声音。")
        }
    }

    private var links: ScenarioLinks? {
        navigation.map { navigation in
            ScenarioLinks { section, subpage, anchor in navigation.open(section, subpage, anchor: anchor) }
        }
    }

    /// The synthesis facts moved from the former 模型 › 语音合成 page, beside the voice profile.
    private var synthesisFacts: some View {
        FactRow([
            FactChip(String(localized: "会议·电话生成译音"), symbol: SubtitleTokens.SceneIcon.meeting,
                     help: String(localized: "会议和电话同传使用合成译音")),
            FactChip(String(localized: "视频不生成"), symbol: Icon.noSpeech,
                     help: String(localized: "视频字幕只显示文字"))
        ], info: InfoButton(topic: String(localized: "合成译音"), lines: [
            String(localized: "已有声音档案但克隆引擎暂不可用时，会等待恢复或不发送该段（未发送），不会改用系统声音。")
        ]))
    }

    /// The safety facts (§5.4): this Mac only, with the ⓘ and the folder beside that chip (§7.7,
    /// so not `FactRow`, whose ⓘ ends the row); playback stays on this Mac; the system voice
    /// while there is no profile. Stacks when the row does not fit and, like `FactRow`, always
    /// at the largest text sizes.
    private var facts: some View {
        Group {
            if typeSize.foldsSettingsGraphics {
                VStack(alignment: .leading, spacing: 6) { factItems }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { factItems }
                    VStack(alignment: .leading, spacing: 6) { factItems }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var factItems: some View {
        HStack(spacing: 2) {
            FactChip(String(localized: "仅本机 · 不上传"), symbol: Icon.privacyPromise,
                     help: String(localized: "声音档案只保存在这台 Mac"))
            InfoButton(topic: String(localized: "声音档案"),
                       lines: [String(localized: "声音档案只保存在这台 Mac，不进备份与 Spotlight 索引。")])
            if model.hasProfile {
                IconButton(Icon.finder, help: String(localized: "在 Finder 中显示"),
                           accessibilityLabel: String(localized: "在 Finder 中显示声音档案")) { model.revealInFinder() }
            }
        }
        FactChip(String(localized: "本机播放"), symbol: Icon.thisMac, help: String(localized: "试听不发送到会议"))
        // Not for an unreadable profile: that waits for recovery, never the system voice.
        if !model.hasProfile {
            FactChip(String(localized: "未录制时用系统声音"), symbol: Icon.speech, help: String(localized: "录制后译音用你的声音"))
        }
    }
}

/// 我的声音's graphic: recording and audition, then the existing translated-voice path.
@MainActor
extension FlowGrid {
    static func myVoice(_ model: MyVoiceModel, driver: DriverComponentsPage? = nil, links: ScenarioLinks? = nil) -> FlowGrid {
        typealias Icon = SubtitleTokens.SettingsIcon
        let profile = model.profile
        let busy = model.externalBusy()
        let record = FlowNode(String(localized: "录中文"), glyph: .symbol(Icon.physicalMic), accessory: .controls {
            Button { model.beginRecording() } label: {
                Label(model.hasProfile ? String(localized: "重录") : String(localized: "录制"), systemImage: Icon.record)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy || model.deleting || model.installerRunning || !model.canRecord)
            .help(model.hasProfile ? String(localized: "旧档案保留到新档案保存") : String(localized: "读一遍中文稿子"))
        })
        let state: (status: SettingsStatus, text: String) =
            model.profileUnreadable ? (.warn, String(localized: "无法读取"))
            : model.recordingNote != nil ? (.warn, String(localized: "引擎已切换 · 请重录"))
            : profile != nil ? (.ok, String(localized: "已保存"))
            : (.pending, String(localized: "未录制"))
        let date = profile?.createdDate
        let saved = FlowNode(String(localized: "声音档案"), glyph: .symbol(Icon.myVoice), badge: state.status,
                             badgeReason: state.text,
                             accessory: date.map { date in
                                 .display {
                                     Text(verbatim: VoiceProfile.shortDate(date))
                                         .font(.caption2)
                                         .foregroundStyle(.secondary)
                                         .monospacedDigit()
                                 }
                             },
                             satellite: profile == nil && !model.profileUnreadable
                                 ? FlowSatellite(String(localized: "系统声音"), symbol: Icon.speech,
                                                 help: String(localized: "未录制时用系统声音"), dashed: true)
                                 : nil,
                             help: date?.formatted(date: .abbreviated, time: .shortened))
        let audition: FlowNode
        if let profile {
            audition = FlowNode(String(localized: "试听"), glyph: .symbol(Icon.headphones), badge: profile.auditionStatus,
                                badgeReason: profile.auditionNote, accessory: .controls {
                                    HStack(spacing: 4) {
                                        AuditionButton(model: model, lang: .en)
                                        AuditionButton(model: model, lang: .de)
                                    }
                                })
        } else {
            audition = FlowNode(String(localized: "试听"), glyph: .symbol(Icon.headphones), state: .dimmed,
                                help: String(localized: "录制后可试听"))
        }
        return FlowGrid(String(localized: "我的声音"), lanes: [
            FlowLane(String(localized: "我的声音"), gutter: .symbol(Icon.me), cells: [
                .node(record), .node(saved), .node(audition), .empty
            ]),
            synthesizedVoiceLane(model, driver: driver, links: links)
        ])
    }

    /// Translation → synthesis (my voice or system voice) → TalkTalk Mic → other party.
    private static func synthesizedVoiceLane(_ model: MyVoiceModel, driver: DriverComponentsPage?, links: ScenarioLinks?) -> FlowLane {
        typealias Icon = SubtitleTokens.SettingsIcon
        let problem = model.synthesisProblem
        let driverProblem = driver?.driverProblem
        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
        // The profile controls are in this same graphic, so the satellite needs no self-link.
        let satellite = model.hasProfile
            ? FlowSatellite(String(localized: "我的声音"), symbol: Icon.myVoice, help: String(localized: "用我的声音合成译音"))
            : FlowSatellite(String(localized: "系统声音"), symbol: Icon.speech,
                            help: String(localized: "未录制时用系统声音"), dashed: true)
        let speech = FlowNode(String(localized: "合成译音"), glyph: .symbol(Icon.speech),
                              badge: problem?.status, badgeReason: problem?.text,
                              link: problem == nil ? nil
                                  : links?.node(String(localized: "安装与维护 · 语音资源"), .components, .components(.engine)),
                              satellite: satellite, help: model.synthesisModelName)
        return FlowLane(String(localized: "译音"), gutter: .voice(translating), cells: [
            .node(FlowNode(String(localized: "译文"), glyph: .symbol(Icon.translation))),
            .node(speech),
            .node(FlowNode("TalkTalk Mic", glyph: .symbol(Icon.talkTalkMic), badge: driverProblem?.status,
                           badgeReason: driverProblem?.text,
                           link: links?.node(String(localized: "安装与维护 · TalkTalk Mic"), .components, .components(.driver)))),
            .node(FlowNode(String(localized: "对方听到译音"), glyph: .symbol(Icon.remote)))
        ])
    }
}

/// EN / DE on the 试听 node: play, or stop while that language plays (or is being made). After
/// 停止 it shows play at once, disabled until the audition's task ends.
private struct AuditionButton: View {
    let model: MyVoiceModel
    let lang: Lang

    var body: some View {
        let playing = model.auditioning == lang && !model.auditionStopped
        let name = lang == .en ? String(localized: "试听英语") : String(localized: "试听德语")
        Button {
            if playing { model.stopAudition() } else { model.audition(lang) }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: playing ? SubtitleTokens.SettingsIcon.stop : SubtitleTokens.SettingsIcon.start)
                    .font(.system(size: SubtitleTokens.SettingsIcon.Size.badge))
                Text(verbatim: lang == .en ? "EN" : "DE")
                    .font(.system(size: SubtitleTokens.SettingsIcon.Size.badge, weight: .medium))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!playing && !model.canAudition)
        .help(playing ? String(localized: "停止") : name)
        .accessibilityLabel(playing ? String(localized: "停止\(name)") : name)
    }
}

/// The saved profile in the words of 我的声音 and 故障检查 › 技术详情 (§7.7, §7.16).
extension VoiceProfile {
    var createdDate: Date? { ISO8601DateFormatter().date(from: createdAt) }

    /// "11-06" on the 声音档案 node; the full date is its help.
    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }

    /// The audition check (passed / failed / pending_engine) as the 试听 node's badge.
    var auditionStatus: SettingsStatus {
        switch audition {
        case "passed": .ok
        case "failed": .failed
        default: .waiting
        }
    }

    var auditionNote: String {
        switch audition {
        case "passed":
            let similarity = auditionResult?.clips.compactMap(\.similarity).min()
            return similarity.map { String(localized: "音色相似度 \(Self.decimal($0, 2))") } ?? String(localized: "通过")
        case "failed": return String(localized: "建议重录")
        default: return String(localized: "引擎就绪后生成")
        }
    }

    /// "参考音 6.2 秒 · 4.1 字/秒".
    var referenceText: String {
        String(localized: "参考音 \(Self.decimal(durationSeconds, 1)) 秒 · \(Self.decimal(speakingRateCharsPerSecond, 1)) 字/秒")
    }

    var checkWarnings: Int { checks.status.values.filter { $0 == .warn }.count }

    var checksText: String {
        let warns = checkWarnings
        var parts: [String] = [warns == 0 ? String(localized: "自动检查通过") : String(localized: "自动检查通过（\(warns) 项警告）")]
        if checks.status["transcript"] == .pending { parts.append(String(localized: "转写比对待核对")) }
        return parts.joined(separator: String(localized: "，"))
    }

    var conditioningBuilt: Bool { conditioning == "built" }

    /// A fixed-precision number, as the previous "%.Nf" text.
    static func decimal(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
}
