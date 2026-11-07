// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import SwiftUI
import TalkTalkAudio
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI
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
        case .notChecked: String(appLocalized: "尚未检查。准备会议或电话同传后，可在会议应用中测试麦克风，或在 Phone 接通电话后确认输入。")
        case let .green(app): String(appLocalized: "\(app) 正在用 TalkTalk Mic")
        case let .physicalMic(_, detail?): String(appLocalized: "会议绕过 TalkTalk 使用实体麦克风，按键翻译已停用。\(detail)。")
        case let .physicalMic(app, nil): String(appLocalized: "\(app) 正在使用实体麦克风，TalkTalk 无法在翻译时关闭原声。请在 \(app) 的音频设置里选 TalkTalk Mic。")
        case .nobodyReads: String(appLocalized: "尚无会议应用或 Phone 使用 TalkTalk Mic")
        }
    }

    /// The other party hearing the raw microphone blocks speech: the red risk glyph. No app
    /// reading TalkTalk Mic during a session is orange, as the menu's line and the status item.
    var status: SettingsStatus {
        switch self {
        case .notChecked: .pending
        case .nobodyReads: .warn
        case .green: .ok
        case .physicalMic: .risk
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

    /// Asks when the device has no answer yet; returns the remembered or new answer. The answer
    /// can be changed or forgotten on 音频 › 耳机.
    @discardableResult
    static func askIfNeeded(uid: String, name: String, _ d: UserDefaults = .standard) -> Bool {
        if let known = answers(d)[uid] { return known }
        let alert = NSAlert()
        alert.messageText = String(appLocalized: "“\(name)”是耳机吗？")
        alert.informativeText = String(appLocalized: "外放时停用耳机译音和会议原声，避免回声。")
        alert.addButton(withTitle: String(appLocalized: "是耳机"))
        alert.addButton(withTitle: String(appLocalized: "是扬声器"))
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
    /// The device list has been read once: before that an empty list says nothing.
    private(set) var devicesLoaded = false
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
    /// The meeting's output is a speaker now (OutputRouteProbe, set by SystemInputController while
    /// a session runs; nil when unknown or no session): 耳机译音 and the passthrough are off.
    var speakerMode: Bool?
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
        devicesLoaded = true
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
            a.messageText = String(appLocalized: "用“\(d.name)”的麦克风？")
            a.informativeText = n.text
            a.addButton(withTitle: String(appLocalized: "仍然使用"))
            a.addButton(withTitle: String(appLocalized: "取消"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        micUID = uid
    }

    /// Calibrates the selected microphone (`PassthroughCalibration`); not during a session.
    func calibrate(meetingActive: Bool) {
        let device = selection.device.flatMap { InputDeviceCatalog.device(uid: $0.uid) }
        calibration.start(device: device, meetingActive: meetingActive)
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

extension ScenarioFacts {
    /// The running session's meeting or Phone check (§7.6), the words of 音频's node and TalkTalk
    /// Mic row and of the menu's check line: in phone mode pending 通话前检查 before the call and
    /// orange only while call audio runs (as `phoneCheck`); 未检查 while no speaking session runs.
    /// Read with `mode` = the session's scene.
    var sessionCheck: SettingsProblem {
        let phone = state.meetingMode == .phone
        let mic = micCheck
        switch mic {
        case let .physicalMic(app, _):
            return SettingsProblem(.risk, phone ? String(appLocalized: "对方能听到原声 · Phone 选“使用系统设置”")
                                                : String(appLocalized: "对方能听到原声 · 在 \(app) 选 TalkTalk Mic"),
                                   help: mic.text)
        case _ where risk:
            return SettingsProblem(.risk, SettingsStatus.risk.spokenName)
        case .green:
            return SettingsProblem(.ok, mic.text)
        case .nobodyReads where !phone || state.phoneAudioActive:
            return SettingsProblem(.warn, phone ? String(appLocalized: "Phone 尚未使用 TalkTalk Mic")
                                                : String(appLocalized: "会议尚未使用 TalkTalk Mic"), help: mic.text)
        case .nobodyReads, .notChecked:
            // 视频字幕 never uses TalkTalk Mic: its session leaves the check 未检查.
            let speaking = running && state.meetingMode.supportsSpeaking
            let text = !speaking ? String(appLocalized: "未检查")
                : phone ? String(appLocalized: "通话前检查") : String(appLocalized: "会议麦克风待确认")
            return SettingsProblem(.pending, text)
        }
    }
}

/// What 音频's graphic, problem line and rows read (§7.6): the microphone choice, the meeting or
/// Phone check of the running session, TalkTalk Mic and the playback route.
@MainActor
struct AudioFacts {
    let model: AudioSettingsModel
    let state: AppState
    let driver: DriverComponentsPage

    private var scene: ScenarioFacts { ScenarioFacts(state: state, mode: state.meetingMode, audio: model) }

    /// The other party can hear the original voice now.
    var risk: Bool { scene.risk }

    /// The microphone row's and node's one fact: the pick that could not be used, no microphone,
    /// call quality over Bluetooth or Continuity's delay. nil before the list is read.
    var micProblem: SettingsProblem? {
        guard model.devicesLoaded else { return nil }
        let selection = model.selection
        let pick: SettingsProblem? = selection.userPickProblem.map {
            switch $0 {
            case .missing: SettingsProblem(.warn, String(appLocalized: "所选设备不在 · 暂用自动"))
            case .notAlive: SettingsProblem(.warn, String(appLocalized: "所选设备不可用 · 暂用自动"))
            case let .excluded(e): SettingsProblem(.warn, String(appLocalized: "\(e.text)不可用 · 暂用自动"))
            }
        }
        guard let device = selection.device else {
            return SettingsProblem.mostSevere([pick, SettingsProblem(.failed, String(appLocalized: "无可用麦克风"))])
        }
        let notice: SettingsProblem? = MicPolicy.pickNotice(device).map {
            switch $0 {
            case .confirmBluetoothHFP: SettingsProblem(.warn, String(appLocalized: "通话音质"), help: $0.text)
            case .continuityLatency: SettingsProblem(.waiting, String(appLocalized: "延迟约 125 ms"), help: $0.text)
            }
        }
        return SettingsProblem.mostSevere([pick, notice])
    }

    /// The meeting or Phone check of the running session (§7.6): `ScenarioFacts.sessionCheck`.
    var check: SettingsProblem { scene.sessionCheck }

    /// TalkTalk Mic's node: the driver's state, else ok while 同传时设为系统默认输入 is on.
    var talkTalkMic: SettingsProblem? {
        driver.driverProblem
            ?? (model.switchDefaultInput ? SettingsProblem(.ok, String(appLocalized: "同传时设为默认输入")) : nil)
    }

    /// The meeting plays through a speaker now: 耳机译音 and the passthrough stop.
    var speakerOut: Bool { model.speakerMode == true }

    /// The page's one problem line (§2): only the most severe.
    var problem: SettingsProblem? {
        let check = check
        let meeting: SettingsProblem? = switch check.status {
        case .risk: SettingsProblem(.risk, SettingsStatus.risk.spokenName, help: check.text)
        case .warn: check
        default: nil
        }
        let speaker = speakerOut
            ? SettingsProblem(.warn, String(appLocalized: "正在外放 · 耳机译音已停用"),
                              help: String(appLocalized: "停用耳机译音与原声通路，避免回声"))
            : nil
        return SettingsProblem.mostSevere([meeting, micProblem, speaker])
    }

    /// The microphone's menu glyph: headset, iPhone, this Mac or a microphone.
    static func symbol(_ device: MicPolicy.Device) -> String {
        if MicPolicy.isBluetooth(device) { return SubtitleTokens.SettingsIcon.headphones }
        if MicPolicy.isContinuity(device) { return SubtitleTokens.SettingsIcon.iPhone }
        if device.transport == "bltn" { return SubtitleTokens.SettingsIcon.thisMac }
        return SubtitleTokens.SettingsIcon.physicalMic
    }
}

/// Settings › 音频 (settings visual system §7.6). The page opens with its flow: what the
/// microphone sends through TalkTalk Mic to the meeting or Phone, and what the headphones play.
/// Each node leads to its section, whose header carries the node's glyph; a link from another
/// page lands on one of them and flashes it. No footers or explanation lines: the one fact per
/// row sits at its end, the rest is in help, the ⓘ and VoiceOver.
struct AudioSettingsView: View {
    @Bindable var model: AudioSettingsModel
    @Bindable var state: AppState
    let driver: DriverComponentsPage
    @Bindable var navigation: SettingsNavigation

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    var body: some View {
        let facts = AudioFacts(model: model, state: state, driver: driver)
        ScrollViewReader { proxy in
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        FlowGrid.audio(facts, monitor: $model.monitor) { jump($0, proxy) }
                        if let problem = facts.problem {
                            StatusLabel(problem.text, problem.status, help: problem.help)
                        }
                    }
                    .padding(.vertical, 4)
                }
                microphone(facts).id(SettingsAnchor.microphone)
                talkTalkMic(facts).id(SettingsAnchor.talkTalkMic)
                headphones.id(SettingsAnchor.playback)
            }
            .formStyle(.grouped)
            .labelStyle(.settingsRow)
            // Back from 通用 ›: the previous position. A flow link's or menu row's anchor scrolls
            // the page itself, also while this page is already shown.
            .settingsPageScroll(navigation, subpage: SettingsSection.audio)
            .settingsAnchorTarget(navigation, proxy)
        }
        .onAppear { model.reload(); model.launch.refresh(); driver.load() }
        // Leaving the page stops a calibration and forgets its outcome: it belonged to this visit.
        .onDisappear { model.calibration.reset() }
        .onChange(of: state.meetingActive) { _, on in if on { model.calibration.cancel() } }
    }

    /// A node's in-page link (§6.3): scroll to its section and flash the header once.
    private func jump(_ anchor: String, _ proxy: ScrollViewProxy) {
        proxy.scrollTo(anchor, anchor: .top)
        navigation.flow.flash(anchor)
    }

    // MARK: 麦克风

    private func microphone(_ facts: AudioFacts) -> some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if let problem = facts.micProblem {
                        StatusLabel(problem.text, problem.status, help: problem.help)
                    }
                    microphonePicker
                }
            } label: {
                Label("麦克风", systemImage: Icon.physicalMic)
            }
            inputVolume
            calibrationResult
        } header: {
            SectionHeader(String(appLocalized: "麦克风"), symbol: Icon.physicalMic,
                          info: [String(appLocalized: "换麦后可单独校准，不必重录声音档案。")])
                .flowFlash(SettingsAnchor.microphone, in: navigation.flow)
        }
    }

    /// 自动 · <the automatic choice>, then every usable device with its glyph; a pick that is
    /// gone keeps its entry (warn, not selectable) so the menu still shows what was chosen.
    /// Choosing the current entry again changes nothing (no second Bluetooth alert, no reset).
    private var microphonePicker: some View {
        let automatic = MicPolicy.select(model.devices, userUID: nil).device
        let missing = model.micUID.flatMap { uid in model.pickable.contains { $0.uid == uid } ? nil : uid }
        return Picker(String(appLocalized: "麦克风"), selection: Binding(get: { model.micUID ?? "" },
                                                                    set: {
                                                                        let uid = $0.isEmpty ? nil : $0
                                                                        guard uid != model.micUID else { return }
                                                                        model.pick(uid)
                                                                    })) {
            Label {
                Text(verbatim: automatic.map { String(appLocalized: "自动 · \($0.name)") } ?? String(appLocalized: "自动"))
            } icon: {
                Image(systemName: Icon.auto)
            }
            .tag("")
            if let missing {
                Label {
                    Text(verbatim: model.devices.first { $0.uid == missing }?.name ?? String(appLocalized: "所选设备"))
                } icon: {
                    Image(systemName: Icon.statusWarn)
                }
                .tag(missing)
                .selectionDisabled()
            }
            ForEach(model.pickable, id: \.uid) { device in
                Label {
                    Text(verbatim: device.name)
                } icon: {
                    Image(systemName: AudioFacts.symbol(device))
                }
                .tag(device.uid)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    /// 原声音量: the calibrated gain or 未校准, and 校准… (not during a session).
    private var inputVolume: some View {
        let calibration = model.calibration
        return LabeledContent {
            HStack(spacing: 8) {
                if case let .calibrated(gain)? = calibration.outcome {
                    StatusLabel(Self.decibels(gain), .ok)
                } else if let gain = model.passthroughGainDb {
                    Text(verbatim: Self.decibels(gain)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    StatusLabel(String(appLocalized: "未校准"), .pending)
                }
                Button("校准…") { model.calibrate(meetingActive: state.meetingActive) }
                    .disabled(state.meetingActive || model.selection.device == nil || calibration.running)
                    .help(ifPresent: state.meetingActive ? String(appLocalized: "会中不可校准") : nil)
            }
        } label: {
            Label("原声音量", systemImage: Icon.inputVolume)
        }
    }

    /// While calibrating: the level, what to do and 取消; afterwards the outcome, except a gain,
    /// which the row above shows.
    @ViewBuilder private var calibrationResult: some View {
        let calibration = model.calibration
        if calibration.running {
            let db = calibration.levelDb ?? -60
            HStack(spacing: 8) {
                ProgressView(value: min(1, max(0, (db + 60) / 60)))
                    .progressViewStyle(.linear)
                    .tint(db > -3 ? .red : .accentColor)
                    .frame(width: 80)
                    .accessibilityLabel(String(appLocalized: "输入音量"))
                Text(String(appLocalized: "按平常音量读一句（约 \(PassthroughCalibration.seconds) 秒）"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                FactChip(String(appLocalized: "不保存录音"), symbol: Icon.privacyPromise, help: String(appLocalized: "只测电平"))
                Button("取消") { calibration.cancel() }
            }
            .padding(.leading, Ladder.rowTextInset)
        } else if let outcome = calibration.outcome, let problem = Self.problem(outcome) {
            StatusLabel(problem.text, problem.status, help: problem.help)
                .padding(.leading, Ladder.rowTextInset)
        }
    }

    private static func problem(_ outcome: PassthroughCalibration.Outcome) -> SettingsProblem? {
        switch outcome {
        case .calibrated: nil
        case .unclear: SettingsProblem(.warn, String(appLocalized: "未测到清晰语音或削波 · 重试"))
        case .microphoneChanged: SettingsProblem(.warn, String(appLocalized: "麦克风已变 · 已取消"))
        case .needsPermission: SettingsProblem(.warn, String(appLocalized: "需麦克风权限"))
        case let .failed(error): SettingsProblem(.failed, String(appLocalized: "未完成"), help: error)
        case .cancelled: SettingsProblem(.pending, String(appLocalized: "已取消"))
        }
    }

    private static func decibels(_ gain: Double) -> String { "\(String(format: "%+.1f", gain)) dB" }

    // MARK: TalkTalk Mic

    private func talkTalkMic(_ facts: AudioFacts) -> some View {
        let check = facts.check
        return Section {
            LabeledContent {
                HStack(spacing: 8) {
                    InfoButton(topic: String(appLocalized: "默认输入"),
                               lines: [String(appLocalized: "结束同传或退出时自动还原；你手动改过的输入会保留。")])
                    Toggle(String(appLocalized: "同传时设为系统默认输入"), isOn: $model.switchDefaultInput)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } label: {
                Label("同传时设为系统默认输入", systemImage: Icon.talkTalkMic)
            }
            if model.switchDefaultInput {
                FactRow([FactChip(String(appLocalized: "听写、Siri 等也会收到原声或译音"), symbol: Icon.talkTalkMic,
                                  help: String(appLocalized: "跟随系统默认输入的应用"))], indented: true)
            }
            LabeledContent {
                StatusLabel(check.text, check.status, help: check.help)
            } label: {
                Label("会议 · Phone", systemImage: SubtitleTokens.SceneIcon.meeting)
            }
            // §7.6: only while 登录时启动 is recommended and off; the switch is on 通用.
            if model.loginStronglyRecommended,
               let recommended = model.launch.recommendedProblem(stronglyRecommended: true) {
                LabeledContent {
                    HStack(spacing: 8) {
                        StatusLabel(recommended.text, recommended.status, help: recommended.help)
                        Button("通用 ›") { navigation.open(.general) }
                            .buttonStyle(.link)
                            .help("打开通用设置")
                    }
                } label: {
                    Label("登录时启动", systemImage: Icon.launchAtLogin)
                }
            }
        } header: {
            SectionHeader("TalkTalk Mic", symbol: Icon.talkTalkMic)
                .flowFlash(SettingsAnchor.talkTalkMic, in: navigation.flow)
        }
    }

    // MARK: 耳机

    private var headphones: some View {
        Section {
            Toggle(isOn: $model.monitor) {
                Label("耳机译音", systemImage: Icon.headphones)
            }
            FactRow([FactChip(String(appLocalized: "外放时自动停用"), symbol: Icon.speaker,
                              help: String(appLocalized: "停用耳机译音与原声通路，避免回声"))], indented: true)
            // The devices asked about once (`HeadphoneAnswers`); nothing at all while there are none.
            ForEach(model.headphones, id: \.uid) { device in
                LabeledContent {
                    HStack(spacing: 8) {
                        Picker(String(appLocalized: "设备类型"), selection: Binding(get: { device.isHeadphone },
                                                                             set: { model.setHeadphone(device.uid, name: device.name, $0) })) {
                            Label("耳机", systemImage: Icon.headphones).tag(true)
                            Label("扬声器", systemImage: Icon.speaker).tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        // Reversible (asked again on the next connection): a list removal, not destructive.
                        IconButton(Icon.remove, help: String(appLocalized: "忘记此设备"),
                                   accessibilityLabel: String(appLocalized: "忘记 \(device.name)")) {
                            model.forgetHeadphone(device.uid)
                        }
                    }
                } label: {
                    Label {
                        Text(verbatim: device.name)
                    } icon: {
                        Image(systemName: device.isHeadphone ? Icon.headphones : Icon.speaker)
                    }
                }
            }
        } header: {
            SectionHeader(String(appLocalized: "耳机"), symbol: Icon.headphones)
                .flowFlash(SettingsAnchor.playback, in: navigation.flow)
        }
    }
}

/// 音频's graphic (§7.6): the original voice or the translation from the microphone through
/// TalkTalk Mic to the meeting or Phone; the meeting's sound, with the translation while
/// 耳机译音 is on and nothing plays through a speaker, to the headphones. Every node scrolls to
/// its section (`jump`).
@MainActor
extension FlowGrid {
    static func audio(_ facts: AudioFacts, monitor: Binding<Bool>, jump: @escaping (String) -> Void) -> FlowGrid {
        typealias Icon = SubtitleTokens.SettingsIcon
        let original = VoiceState.resolve(audio: .original, scene: .meeting, phoneInputConfirmed: true)
        let translating = VoiceState.resolve(audio: .translating, scene: .meeting, phoneInputConfirmed: true)
        let device = facts.model.selection.device
        let mic = facts.micProblem
        let talkTalkMic = facts.talkTalkMic
        let check = facts.check
        let speaker = facts.speakerOut
        let microphone = FlowNode(String(appLocalized: "麦克风"), glyph: .symbol(Icon.physicalMic), badge: mic?.status,
                                  badgeReason: mic?.text,
                                  link: NodeLink(String(appLocalized: "麦克风")) { jump(SettingsAnchor.microphone) },
                                  accessory: device.map { device in
                                      .display {
                                          Text(verbatim: device.name)
                                              .font(.caption2)
                                              .foregroundStyle(.secondary)
                                              .lineLimit(1)
                                              .truncationMode(.tail)
                                      }
                                  },
                                  help: device?.name)
        let input = FlowNode("TalkTalk Mic", glyph: .symbol(Icon.talkTalkMic),
                             state: facts.model.switchDefaultInput ? .ready : .off,
                             badge: talkTalkMic?.status, badgeReason: talkTalkMic?.text,
                             link: NodeLink("TalkTalk Mic") { jump(SettingsAnchor.talkTalkMic) })
        let meeting = FlowNode(String(appLocalized: "会议 · Phone"), glyph: .symbol(SubtitleTokens.SceneIcon.meeting),
                               state: facts.risk || check.status == .risk ? .risk
                                   : check.status == .warn ? .needsAction : .ready,
                               badge: check.status, badgeReason: check.text,
                               link: NodeLink("TalkTalk Mic") { jump(SettingsAnchor.talkTalkMic) })
        let sound = FlowNode(String(appLocalized: "会议声音"), glyph: .symbol(Icon.speech))
        let headphones = FlowNode(String(appLocalized: "耳机"), glyph: .symbol(speaker ? Icon.speaker : Icon.headphones),
                                  badge: speaker ? .warn : nil,
                                  badgeReason: speaker ? String(appLocalized: "正在外放 · 耳机译音已停用") : nil,
                                  link: NodeLink(String(appLocalized: "耳机")) { jump(SettingsAnchor.playback) },
                                  accessory: .controls {
                                      Toggle(String(appLocalized: "耳机译音"), isOn: monitor)
                                          .labelsHidden()
                                          .toggleStyle(.switch)
                                          .controlSize(.mini)
                                          .help(String(appLocalized: "耳机译音"))
                                  })
        return FlowGrid(String(appLocalized: "音频路径"), lanes: [
            FlowLane(String(appLocalized: "我说话 · 原声与译音"), gutter: .voices([original, translating]), cells: [
                .node(microphone), .node(input), .node(meeting), .empty
            ]),
            FlowLane(String(appLocalized: "听会议"), gutter: .symbol(Icon.headphones), cells: [
                .node(sound),
                // Through a speaker 耳机译音 stops: no capsule on a path that does not play.
                monitor.wrappedValue && !speaker
                    ? .carry(translating, spoken: String(appLocalized: "译音也在耳机播放")) : .pass,
                .node(headphones),
                .empty
            ])
        ])
    }
}
