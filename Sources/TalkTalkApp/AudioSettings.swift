// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkAudio
import TalkTalkCore
import TalkTalkVoice

/// MeetingMicGuard's verdict for the meeting-app check (§8.6). SystemInputController feeds this
/// from sysinput's guard while meeting mode runs; otherwise `.notChecked`.
enum MeetingMicCheck: Equatable {
    case notChecked
    case green(app: String)
    /// `detail`: MeetingMicGuardPlan.Verdict.detail ("Zoom 正在用 X：在 <设置路径> 里选 TalkTalk Mic").
    case physicalMic(app: String, detail: String? = nil)
    case nobodyReads

    var text: String {
        switch self {
        case .notChecked: String(localized: "尚未检查。准备会议或电话同传后，可在会议应用中测试麦克风，或在 Phone 接通电话后确认输入。")
        case let .green(app): String(localized: "\(app) 正在用 TalkTalk Mic")
        case let .physicalMic(_, detail?): String(localized: "会议绕过 TalkTalk 使用实体麦克风，按键翻译已停用。\(detail)。")
        case let .physicalMic(app, nil): String(localized: "\(app) 正在使用实体麦克风，TalkTalk 无法在翻译时关闭原声。请在 \(app) 的音频设置里选 TalkTalk Mic。")
        case .nobodyReads: String(localized: "尚无会议应用或 Phone 使用 TalkTalk Mic")
        }
    }

    var color: Color {
        switch self {
        case .notChecked, .nobodyReads: .secondary
        case .green: .green
        case .physicalMic: .red
        }
    }
}

/// "这是耳机吗？" (§11): asked once per unconfirmed Bluetooth or USB output, remembered by UID,
/// read by OutputRouteClassifier as `confirmedHeadphones`.
@MainActor
enum HeadphoneAnswers {
    static let changed = Notification.Name("TalkTalk.headphoneAnswersChanged")
    static func answers(_ d: UserDefaults = .standard) -> [String: Bool] {
        d.dictionary(forKey: UIPrefKey.headphoneAnswers) as? [String: Bool] ?? [:]
    }

    static func names(_ d: UserDefaults = .standard) -> [String: String] {
        d.dictionary(forKey: UIPrefKey.headphoneNames) as? [String: String] ?? [:]
    }

    /// `confirmedHeadphones` for OutputRouteClassifier.classify.
    static func confirmed(_ d: UserDefaults = .standard) -> Set<String> {
        Set(answers(d).filter(\.value).keys)
    }

    static func set(_ isHeadphone: Bool?, uid: String, name: String, _ d: UserDefaults = .standard) {
        var a = answers(d), n = names(d)
        a[uid] = isHeadphone
        n[uid] = isHeadphone == nil ? nil : name
        d.set(a, forKey: UIPrefKey.headphoneAnswers)
        d.set(n, forKey: UIPrefKey.headphoneNames)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Asks when the device has no answer yet; returns the remembered or new answer.
    @discardableResult
    static func askIfNeeded(uid: String, name: String, _ d: UserDefaults = .standard) -> Bool {
        if let known = answers(d)[uid] { return known }
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(name)”是耳机吗？")
        alert.informativeText = String(localized: "外放可能产生回声，TalkTalk 会停用耳机译音和会议原声。这个选择会被记住，也可以在设置 › 音频中修改。")
        alert.addButton(withTitle: String(localized: "是耳机"))
        alert.addButton(withTitle: String(localized: "是扬声器"))
        NSApp.activate()
        let yes = alert.runModal() == .alertFirstButtonReturn
        set(yes, uid: uid, name: name, d)
        return yes
    }
}

@MainActor
@Observable
final class AudioSettingsModel {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let gains: PassthroughGainDefaults
    @ObservationIgnored private var gainObserver: NSObjectProtocol?
    let launch: LaunchAtLogin
    let calibration: PassthroughCalibration

    var devices: [MicPolicy.Device] = []
    var micUID: String? {
        didSet { defaults.set(micUID, forKey: UIPrefKey.micUID); refreshGain(); calibration.cancel() }
    }
    var hotMic: Bool { didSet { defaults.set(hotMic, forKey: UIPrefKey.hotMic) } }
    var monitor: Bool { didSet { defaults.set(monitor, forKey: UIPrefKey.monitor) } }
    var cuesEnabled: Bool { didSet { defaults.set(cuesEnabled, forKey: UIPrefKey.cuesEnabled) } }
    var cueDbfs: Double { didSet { defaults.set(cueDbfs, forKey: UIPrefKey.cueDbfs) } }
    var switchDefaultInput: Bool { didSet { defaults.set(switchDefaultInput, forKey: UIPrefKey.switchDefaultInput) } }
    var headphones: [(uid: String, name: String, isHeadphone: Bool)] = []
    /// Set by SystemInputController from MeetingMicGuard during meeting mode.
    var meetingMic: MeetingMicCheck = .notChecked
    /// Calibrated passthrough gain of the selected mic (PassthroughGainStore, voice-m2 /
    /// passthrough-audio); nil: not calibrated or the store is not on main yet.
    var passthroughGainDb: Double?

    init(defaults: UserDefaults = .standard, launch: LaunchAtLogin) {
        self.defaults = defaults
        gains = PassthroughGainDefaults(defaults: defaults)
        calibration = PassthroughCalibration(gains: gains)
        self.launch = launch
        micUID = defaults.string(forKey: UIPrefKey.micUID)
        hotMic = defaults.object(forKey: UIPrefKey.hotMic) as? Bool ?? true
        monitor = defaults.object(forKey: UIPrefKey.monitor) as? Bool ?? false
        cuesEnabled = defaults.object(forKey: UIPrefKey.cuesEnabled) as? Bool ?? true
        cueDbfs = defaults.object(forKey: UIPrefKey.cueDbfs) as? Double ?? -30
        switchDefaultInput = defaults.object(forKey: UIPrefKey.switchDefaultInput) as? Bool ?? true
        gainObserver = NotificationCenter.default.addObserver(forName: PassthroughGainDefaults.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGain() }
        }
    }

    isolated deinit { if let gainObserver { NotificationCenter.default.removeObserver(gainObserver) } }

    private func refreshGain() {
        passthroughGainDb = selection.device.flatMap { gains.gainDb(micUIDHash: VoiceProfile.micUIDHash($0.uid)) }
    }

    func reload() {
        devices = InputDeviceCatalog.inputDevices().map {
            MicPolicy.Device(uid: $0.uid, name: $0.name, transport: $0.transport, isAggregate: $0.isAggregate, isAlive: $0.isAlive)
        }
        let names = HeadphoneAnswers.names(defaults)
        headphones = HeadphoneAnswers.answers(defaults)
            .map { (uid: $0.key, name: names[$0.key] ?? $0.key, isHeadphone: $0.value) }
            .sorted { $0.name < $1.name }
        refreshGain()
    }

    var selection: MicPolicy.Selection { MicPolicy.select(devices, userUID: micUID) }
    var pickable: [MicPolicy.Device] { MicPolicy.pickable(devices) }

    /// Picking a Bluetooth mic needs a second confirmation (§3.2 PickNotice).
    func pick(_ uid: String?) {
        guard let uid, let d = devices.first(where: { $0.uid == uid }) else { micUID = nil; return }
        if let n = MicPolicy.pickNotice(d), n.needsConfirmation {
            let a = NSAlert()
            a.messageText = String(localized: "用“\(d.name)”的麦克风？")
            a.informativeText = n.text
            a.addButton(withTitle: String(localized: "仍然使用"))
            a.addButton(withTitle: String(localized: "取消"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        micUID = uid
    }

    func forgetHeadphone(_ uid: String) {
        HeadphoneAnswers.set(nil, uid: uid, name: "", defaults)
        reload()
    }

    func setHeadphone(_ uid: String, name: String, _ yes: Bool) {
        HeadphoneAnswers.set(yes, uid: uid, name: name, defaults)
        reload()
    }

    var loginStronglyRecommended: Bool {
        switchDefaultInput && SystemInputPlan.Config.default.loginStartStronglyRecommended
    }
}

struct AudioSettingsView: View {
    @Bindable var model: AudioSettingsModel
    var meetingActive = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                soundPaths(proxy)
                microphone.id("audio.microphone")
                capture
                calibration
                defaultInput.id("audio.meetingInput")
                meetingCheck
                playback.id("audio.playback")
                headphones
            }
            .formStyle(.grouped)
        }
        .onAppear { model.reload(); model.launch.refresh() }
        .onDisappear { model.calibration.cancel() }
        .onChange(of: meetingActive) { _, on in if on { model.calibration.cancel() } }
    }

    private func soundPaths(_ proxy: ScrollViewProxy) -> some View {
        Section {
            SpeechFlow(steps: [
                ("mic", String(localized: "实体麦克风")),
                ("character.bubble", String(localized: "原声／按键翻译")),
                ("waveform", "TalkTalk Mic"),
                ("person.2.wave.2", String(localized: "会议应用"))
            ], links: [
                0: .init(String(localized: "选择采音设备")) { proxy.scrollTo("audio.microphone", anchor: .top) },
                2: .init(String(localized: "设置会议输入")) { proxy.scrollTo("audio.meetingInput", anchor: .top) }
            ])
            Label("TalkTalk 选实体麦收音；会议应用选 TalkTalk Mic 接收声音。", systemImage: "arrow.triangle.branch")
                .font(.callout).foregroundStyle(.secondary)
            SpeechFlow(steps: [
                ("speaker.wave.2", String(localized: "会议声音与可选译音")),
                ("headphones", String(localized: "耳机播放"))
            ], links: [
                1: .init(String(localized: "设置耳机播放")) { proxy.scrollTo("audio.playback", anchor: .top) }
            ])
        } header: {
            Text("声音如何流动")
        } footer: {
            Text("耳机负责播放，采音可以使用内建麦克风。视频字幕只收听应用声音，不使用麦克风。")
        }
    }

    private var microphone: some View {
        let sel = model.selection
        return Section {
            Picker("采音设备", selection: Binding(get: { model.micUID ?? "" }, set: { model.pick($0.isEmpty ? nil : $0) })) {
                Text("自动（内建麦克风优先）").tag("")
                ForEach(model.pickable, id: \.uid) { d in Text(verbatim: d.name).tag(d.uid) }
            }
            if let d = sel.device {
                LabeledContent("已选采音设备") { Text(verbatim: d.name).foregroundStyle(.secondary) }
                if let n = MicPolicy.pickNotice(d) {
                    Text(n.text).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("没有可用的麦克风", systemImage: "mic.slash").font(.callout).foregroundStyle(.red)
            }
            if let p = sel.userPickProblem {
                Text(problemText(p)).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("采音设备如何选择") {
                SettingsNote("自动选择时优先使用内建麦。这里只选实体设备，不受系统默认输入影响。换麦后可单独校准音量，不必重录声音档案。")
            }
        } header: {
            Text("实体麦克风 · 采集你的声音")
        }
    }

    private func problemText(_ p: MicPolicy.UserPickProblem) -> String {
        switch p {
        case .missing: String(localized: "你选的麦克风现在不在，暂时改用上面这一个。")
        case .notAlive: String(localized: "你选的麦克风当前不可用，暂时改用上面这一个。")
        case let .excluded(e): String(localized: "你选的麦克风不能用（\(e.text)），暂时改用上面这一个。")
        }
    }

    private var capture: some View {
        Section {
            LabeledContent("收音方式", value: String(localized: "按场景启用麦克风"))
            Label("需要静音时，使用会议应用或 Phone 的静音按钮。", systemImage: "mic.slash")
                .font(.callout)
        } header: {
            Text("会议与电话收音")
        } footer: {
            Text("会议和电话同传准备好后即可收音；电话不必等接通，点按右⌥就能开始翻译，再点按结束发言。电话接收状态另行检查，不影响拨号前试说。默认不保存录音；视频字幕不使用麦克风。")
        }
    }

    private var playback: some View {
        Section {
            Toggle("在耳机中听到译音", isOn: $model.monitor)
        } header: {
            Text("耳机 · 播放声音")
        } footer: {
            Text("开启后，你也能听到译音。外放时停用耳机译音和 TalkTalk 的原声通路，避免回声；不更改系统默认输出。")
        }
    }

    private var calibration: some View {
        Section {
            if let g = model.passthroughGainDb {
                LabeledContent("校准增益") { Text("\(String(format: "%+.1f", g)) dB").monospacedDigit() }
            } else {
                LabeledContent("校准状态") {
                    Label("尚未校准 · 0 dB", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button("读一句话校准音量") {
                    let device = model.selection.device.flatMap { InputDeviceCatalog.device(uid: $0.uid) }
                    model.calibration.start(device: device, meetingActive: meetingActive)
                }
                .disabled(meetingActive || model.selection.device == nil || model.calibration.running)
                if model.calibration.running {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.calibration.cancel() }
                }
            }
            if let message = model.calibration.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("原声音量")
        } footer: {
            Text("只测电平，不保存录音。请先停止会议同传或视频字幕再校准。")
        }
    }

    private var defaultInput: some View {
        Section {
            Toggle("会议或电话同传时将系统默认输入设为 TalkTalk Mic", isOn: $model.switchDefaultInput)
            LabeledContent("在会议应用或 Phone 中选择", value: model.switchDefaultInput
                ? String(localized: "TalkTalk Mic，或跟随系统默认") : "TalkTalk Mic")
            if model.loginStronglyRecommended {
                LaunchAtLoginRow(launch: model.launch, stronglyRecommended: true)
            }
            DisclosureGroup("默认输入如何恢复") {
                SettingsNote("准备会议或电话同传时自动接入；停止同传或退出 TalkTalk 时自动还原。Phone 需选择“使用系统设置”；你手动更改过的输入会保留。")
            }
        } header: {
            Text("TalkTalk Mic · 通话输入")
        } footer: {
            Text("跟随系统默认输入的应用（听写、Siri、录音等）也会接收原声或译音。视频字幕不更改默认输入。")
        }
    }

    private var headphones: some View {
        Section {
            if model.headphones.isEmpty {
                Text("还没有已确认的设备").foregroundStyle(.secondary)
            }
            ForEach(model.headphones, id: \.uid) { h in
                LabeledContent {
                    HStack(spacing: 12) {
                        Picker("设备类型", selection: Binding(get: { h.isHeadphone }, set: { model.setHeadphone(h.uid, name: h.name, $0) })) {
                            Text("耳机").tag(true)
                            Text("扬声器").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Button("忘记") { model.forgetHeadphone(h.uid) }
                    }
                } label: {
                    Text(verbatim: h.name)
                }
            }
            DisclosureGroup("设备分类说明") {
                SettingsNote("首次连接蓝牙或 USB 播放设备时，会询问它是耳机还是扬声器。选择会被记住，可随时修改或忘记。")
            }
        } header: {
            Text("已记住的耳机与扬声器")
        } footer: {
            Text("这里的设备分类不表示当前正在使用的输出。")
        }
    }

    private var meetingCheck: some View {
        Section {
            Label(model.meetingMic.text, systemImage: meetingCheckSymbol).font(.callout).foregroundStyle(model.meetingMic.color)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("会议与电话应用检查")
        } footer: {
            Text("会议应用请选择 TalkTalk Mic；Phone 可在“音频 › 麦克风”选择“使用系统设置”，跟随 TalkTalk 的默认输入切换。")
        }
    }

    private var meetingCheckSymbol: String {
        switch model.meetingMic {
        case .green: "checkmark.circle.fill"
        case .physicalMic: "exclamationmark.triangle.fill"
        case .notChecked, .nobodyReads: "circle.dashed"
        }
    }
}
