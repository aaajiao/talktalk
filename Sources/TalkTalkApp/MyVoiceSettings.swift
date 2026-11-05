import Foundation
import Observation
import SwiftUI
import TalkTalkCore
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
    /// Settings › 组件's installer; while it runs no audition and no new take.
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
        Task {
            do {
                if lifecycle.savedAudition == nil {
                    // The audition starts the engine: let it idle out afterwards (§7.6), also on failure.
                    do { _ = try await lifecycle.audition() } catch { await engine?.enrollmentFinished(); throw error }
                    await engine?.enrollmentFinished()
                }
                try await lifecycle.play(lang)
            } catch let e as AuditionMonitorError {
                auditionProblem = e.description
            } catch {
                auditionProblem = "试听没有生成：\(error)"
            }
            auditioning = nil
            reload()
            refreshMonitorAvailability()
        }
    }

    var engineAvailable: Bool { lifecycle?.engine != nil }
    var canAudition: Bool {
        engineAvailable && monitorAvailable && !installerRunning && !externalBusy() && auditioning == nil && !deleting
    }
    /// Why 试听 is grayed out (nil while it can play or is playing).
    var auditionBlockedNote: String? {
        if externalBusy() { return "自检正在运行，完成后可录制或试听。" }
        if !engineAvailable { return "引擎装好并就绪后可试听（经自听输出播到耳机，绝不进 TalkTalk Mic）。" }
        if installerRunning { return "引擎组件正在安装或修复，完成后再试听。" }
        if !monitorAvailable { return monitorUnavailableReason ?? "自听输出暂不可用" }
        return nil
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
            restartRecording(note: "引擎刚刚换过，这一遍没有保存，请再录一遍。")
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

struct MyVoiceSettingsView: View {
    // No @State: the CLT toolchain has no SwiftUIMacros plugin, so view state lives in the model.
    @Bindable var model: MyVoiceModel

    var body: some View {
        if let controller = model.enrollment {
            VStack(alignment: .leading, spacing: 8) {
                if let note = model.recordingNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if model.saveBlocked {
                    HStack {
                        Label("引擎组件正在安装或修复，完成后再保存。", systemImage: "hourglass").foregroundStyle(.secondary)
                        Spacer()
                        // The flow below is held, its own 关闭 too: this one stays usable.
                        Button("关闭") { model.endRecording() }
                    }
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
                    // No profile yet: go straight to the script and the 开始 button.
                    if !model.hasProfile && !model.profileUnreadable { model.beginRecording() }
                }
        }
    }

    private var overview: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 34)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("我的声音").font(.title2.bold())
                        Text("用你的声音朗读英语或德语译文。")
                            .foregroundStyle(.secondary)
                    }
                }
                SpeechFlow(steps: [("mic", "录一段中文"), ("person.crop.circle.badge.checkmark", "保存声音档案"), ("headphones", "听英语／德语")])
            }
            Section {
                if let note = model.recordingNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = model.profile {
                    profileSummary(p)
                } else if model.profileUnreadable {
                    Label("声音档案无法读取，请重新录制。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("尚未创建声音档案", systemImage: "person.crop.circle.badge.plus")
                    SettingsNote("读一遍固定的中文稿子即可创建。没有声音档案时，译音使用系统声音。")
                }
            } header: { Text("声音档案") }
            if model.profile != nil {
                Section {
                    HStack(spacing: 12) {
                        Button { model.audition(.en) } label: { Label("试听英语", systemImage: "play.fill") }
                            .disabled(!model.canAudition)
                        Button { model.audition(.de) } label: { Label("试听德语", systemImage: "play.fill") }
                            .disabled(!model.canAudition)
                        if model.auditioning != nil { ProgressView().controlSize(.small) }
                    }
                    Text(model.auditionBlockedNote ?? "试听在耳机或当前播放设备中响起，不发送到会议。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let problem = model.auditionProblem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Label("听听效果", systemImage: "headphones") }
            }
            Section {
                HStack {
                    Button { model.beginRecording() } label: {
                        Label(model.hasProfile ? "重新录制" : "开始录制", systemImage: "mic.badge.plus")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.deleting || model.installerRunning || !model.canRecord)
                    Spacer()
                    if model.hasProfile {
                        Button("删除声音档案…", role: .destructive) { model.confirmDelete = true }
                            .disabled(model.deleting || !model.canRecord)
                    }
                }
                if model.hasProfile { SettingsNote("重新录制时，旧档案会一直保留到新档案保存成功。") }
                DisclosureGroup("存储与隐私") {
                    SettingsNote("声音档案仅保存在这台 Mac，不上传，不进入备份或 Spotlight 索引。")
                    Text(verbatim: "~/Library/Application Support/TalkTalk/voice/")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("删除我的声音？", isPresented: $model.confirmDelete) {
            Button("删除", role: .destructive) { model.deleteProfile() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("参考音、稿子和声音缓存都会从这台 Mac 上删除。之后译音使用系统声音，直到重新录制。")
        }
    }

    private func profileSummary(_ p: VoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("声音档案已保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
            LabeledContent("录制时间", value: Self.dateText(p.createdAt))
            LabeledContent("试听检查", value: Self.auditionText(p))
            DisclosureGroup("档案详情") {
                VStack(spacing: 8) {
                    LabeledContent("参考音", value: String(format: "%.1f 秒", p.durationSeconds))
                    LabeledContent("语速", value: String(format: "%.1f 字/秒", p.speakingRateCharsPerSecond))
                    LabeledContent("自动检查", value: Self.checksText(p))
                    LabeledContent("声音缓存", value: p.conditioning == "built" ? "已建立" : "引擎预热时建立")
                }
                .font(.callout).padding(.top, 6)
            }
        }
    }

    static func dateText(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    /// The profile's audition state (passed / failed / pending_engine) and its numbers.
    static func auditionText(_ p: VoiceProfile) -> String {
        switch p.audition {
        case "passed":
            let sim = p.auditionResult?.clips.compactMap(\.similarity).min()
            return sim.map { String(format: "通过（音色相似度 %.2f）", $0) } ?? "通过"
        case "failed": return "没通过：请重录"
        default: return "待引擎（引擎就绪后生成）"
        }
    }

    static func checksText(_ p: VoiceProfile) -> String {
        let s = p.checks.status
        let warns = s.values.filter { $0 == .warn }.count
        var parts: [String] = [warns == 0 ? "通过" : "通过（\(warns) 项警告）"]
        if s["transcript"] == .pending { parts.append("转写比对待核对") }
        return parts.joined(separator: "，")
    }
}
