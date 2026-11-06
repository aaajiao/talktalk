// l10n: zh-Hans (scripts/check-strings.sh)
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// Settings › 字幕 (redesign §7 字幕页). The pinned scene cards are the same as 使用场景's and
/// share its selection: they only choose which scene's settings are edited and never start or
/// switch a session.
struct SubtitleSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    private var presentation: SubtitlePanel.Presentation { state.requestedScenario.subtitlePresentation }
    private var video: Bool { presentation == .video }
    private var phone: Bool { presentation == .phone }
    private var scene: SubtitleScene {
        switch presentation {
        case .meeting: .meeting
        case .phone: .phone
        case .video: .video
        }
    }

    private var display: SubtitleStyle.Display {
        SubtitleStyle.Display(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency,
                              reduceMotion: reduceMotion)
    }

    private var fontSize: Binding<Double> {
        Binding(get: {
            switch presentation {
            case .meeting: state.subtitleFontSize
            case .phone: state.phoneSubtitleFontSize
            case .video: state.videoSubtitleFontSize
            }
        }, set: {
            switch presentation {
            case .meeting: state.subtitleFontSize = $0
            case .phone: state.phoneSubtitleFontSize = $0
            case .video: state.videoSubtitleFontSize = $0
            }
        })
    }
    private var opacity: Binding<Double> {
        Binding(get: {
            switch presentation {
            case .meeting: state.subtitleBackgroundOpacity
            case .phone: state.phoneSubtitleBackgroundOpacity
            case .video: state.videoSubtitleBackgroundOpacity
            }
        }, set: {
            switch presentation {
            case .meeting: state.subtitleBackgroundOpacity = $0
            case .phone: state.phoneSubtitleBackgroundOpacity = $0
            case .video: state.videoSubtitleBackgroundOpacity = $0
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScenarioCardHeader(selection: state.requestedScenario,
                               running: state.meetingActive ? state.meetingMode : nil,
                               startedAt: state.meetingStartedAt) { state.requestedScenario = $0 }

            Form {
                Section {
                    Toggle(isOn: $state.subtitlesVisible) {
                        Label("显示字幕（所有场景）", systemImage: "captions.bubble")
                    }
                    Toggle(isOn: $state.announceNewTranslations) {
                        Label("朗读新译文（VoiceOver）", systemImage: "voiceover")
                    }
                    .help("用 VoiceOver 朗读每条定稿译文，不读草稿")
                    .accessibilityHint(String(localized: "用 VoiceOver 朗读每条定稿译文，不读草稿"))
                } footer: {
                    // The preview sits in a footer: no grouped card around the window picture
                    // (macOS grouped forms ignore listRowBackground).
                    preview.padding(.top, 8)
                }

                Section {
                    LabeledContent("基础字号") {
                        let defaultSize = SubtitleOpacityControl.defaultFontSize(for: scene)
                        HStack {
                            Slider(value: fontSize, in: 16...36, step: 1) {
                                Text("基础字号")
                            } minimumValueLabel: {
                                Image(systemName: "textformat.size.smaller").accessibilityHidden(true)
                            } maximumValueLabel: {
                                Image(systemName: "textformat.size.larger").accessibilityHidden(true)
                            }
                            .labelsHidden()
                            .frame(minWidth: 150)
                            .accessibilityLabel(String(localized: "基础字号"))
                            .accessibilityValue(String(localized: "\(Int(fontSize.wrappedValue)) 磅"))
                            Text("\(Int(fontSize.wrappedValue)) 磅").monospacedDigit().frame(width: 54, alignment: .trailing)
                            Button { fontSize.wrappedValue = defaultSize } label: {
                                Image(systemName: SubtitleTokens.SettingsIcon.reset)
                            }
                            .buttonStyle(.borderless)
                            .help("恢复默认字号")
                            .accessibilityLabel(String(localized: "恢复默认字号"))
                            .disabled(fontSize.wrappedValue == defaultSize)
                        }
                    }
                } header: {
                    HStack {
                        Text("字幕大小")
                        InfoButton(topic: String(localized: "字幕大小"), lines: [
                            String(localized: "字号、背景和窗口位置按场景分别保存。"),
                            video ? String(localized: "长句分页，每页最多两行；中文下方的圆点表示还有下一页。")
                                : String(localized: "向上滚动时暂停跟随；点“N 条新字幕”回到最新。")
                        ])
                    }
                }

                if video { videoCaptionSettings }

                backgroundSettings

                Section {
                    Label("不出现在屏幕共享中", systemImage: "rectangle.on.rectangle.slash").foregroundStyle(.secondary)
                    Label {
                        Text(video ? String(localized: "最小化后收听和翻译继续，可从菜单栏恢复")
                             : String(localized: "最小化后同传继续，可从菜单栏恢复"))
                    } icon: {
                        // The yellow traffic light it refers to.
                        Image(systemName: "minus.circle.fill").foregroundStyle(.yellow)
                    }
                } header: {
                    HStack {
                        Text("窗口")
                        InfoButton(topic: String(localized: "字幕窗口"), lines: windowNotes)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var windowNotes: [String] {
        var lines = [String(localized: "拖动标题栏或文字区域移动；视频可在菜单中锁定位置。"),
                     String(localized: "不抢键盘焦点。")]
        if !video { lines.append(String(localized: "标题栏右侧是发声状态、右⌥ 和结束；点状态查看说明。")) }
        if phone { lines.append(String(localized: "拨号、接听和挂断在 Phone 中完成。")) }
        return lines
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("布局预览").font(.headline).foregroundStyle(.primary)
            // The backdrop follows the system appearance (live); the window itself is always dark.
            SubtitleLayoutPreview(configuration: .init(
                scene: scene, fontSize: fontSize.wrappedValue, opacity: opacity.wrappedValue,
                videoStyle: state.videoCaptionStyle, videoArrangement: state.videoCaptionArrangement,
                darkBackdrop: colorScheme == .dark, display: display))
            if video {
                Text("预览显示鼠标悬停时的标题栏").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    private var opacityControl: SubtitleOpacityControl {
        SubtitleOpacityControl.make(scene: scene, videoStyle: state.videoCaptionStyle, reduceTransparency: reduceTransparency)
    }

    private var backgroundSettings: some View {
        Section {
            LabeledContent("背景不透明度") {
                let percent = Int((opacity.wrappedValue * 100).rounded())
                HStack {
                    Slider(value: opacity, in: 0.35...1, step: 0.05) {
                        Text("背景不透明度")
                    } minimumValueLabel: {
                        Image(systemName: "circle.dotted").accessibilityHidden(true)
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill").accessibilityHidden(true)
                    }
                    .labelsHidden()
                    .frame(minWidth: 150).disabled(!opacityControl.enabled)
                    .accessibilityLabel(String(localized: "背景不透明度"))
                    .accessibilityValue(Text(verbatim: "\(percent)%"))
                    .help("默认 85%；只调背景，文字不变淡")
                    Text(verbatim: "\(percent)%")
                        .monospacedDigit().frame(width: 54, alignment: .trailing)
                        .foregroundStyle(opacityControl.enabled ? .primary : .secondary)
                }
            }
            switch opacityControl.note {
            case .reduceTransparency?:
                Label(video
                      ? String(localized: "系统已开启“降低透明度”，改用实底")
                      : String(localized: "系统已开启“降低透明度”，背景不透明"),
                      systemImage: "accessibility")
                    .font(.callout).foregroundStyle(.secondary)
            case .strokeHasNoBackground?:
                Label("描边样式不使用背景", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        } header: {
            Text("窗口背景")
        }
    }

    private var videoCaptionSettings: some View {
        Section {
            Picker("字幕样式", selection: $state.videoCaptionStyle) {
                Text("贴合玻璃").help("只在文字后面铺毛玻璃").tag(VideoCaptionStyle.fittedGlass)
                Text("描边").help("不铺背景，文字加描边和阴影").tag(VideoCaptionStyle.stroke)
                Text("实底").help("每行文字后垫深色底块").tag(VideoCaptionStyle.plate)
            }
            .pickerStyle(.segmented)
            Picker("排列", selection: $state.videoCaptionArrangement) {
                Text("原文在上").tag(VideoCaptionArrangement.sourceFirst)
                Text("中文在上").tag(VideoCaptionArrangement.translationFirst)
            }
            .pickerStyle(.segmented)
            Toggle("长静默时变暗", isOn: $state.videoLongSilenceDim)
                .help("最后一页读完 8 秒后无新内容时，文字降到 35%")
        } header: {
            Text("视频字幕")
        }
    }
}
