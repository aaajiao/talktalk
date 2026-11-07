// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Observation
import SwiftUI
import TalkTalkCore
import TalkTalkSession
import TalkTalkSettingsUI

/// Whether VoiceOver runs (settings visual system §7.4): 字幕's "用 VoiceOver 读出新字幕"
/// shows only then. `isVoiceOverEnabled` is KVO-observable (NSAccessibility.h; SubtitlePanel
/// observes it too); the callback is not on the main thread, so it hops to the main actor
/// before writing. Hiding the switch never clears `ui.announceNewTranslations`.
@MainActor
@Observable
final class SubtitleSettingsModel {
    private(set) var voiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { @Sendable [weak self] _, change in
            let running = change.newValue
            Task { @MainActor in
                guard let self else { return }
                let now = running ?? NSWorkspace.shared.isVoiceOverEnabled
                if self.voiceOverRunning != now { self.voiceOverRunning = now }
            }
        }
    }
}

/// Settings › 字幕 (settings visual system §7.4). The window's pinned band holds the page-wide
/// switches over the scene cards, the same cards as 使用场景's with the same selection: they
/// only choose which scene's settings are edited and never start or switch a session. The page
/// opens with that scene's window preview, whose hotspots say what the titlebar controls do,
/// then 字号 and 背景 (each saved per scene), the video caption style, and the window's facts.
/// No captions, footers or explanation paragraphs: the rest lives in help and VoiceOver.
struct SubtitleSettingsView: View {
    @Bindable var state: AppState
    @Bindable var navigation: SettingsNavigation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private typealias Icon = SubtitleTokens.SettingsIcon
    private typealias Ladder = SubtitleTokens.SettingsIcon.Size

    private var presentation: SubtitlePanel.Presentation { state.requestedScenario.subtitlePresentation }
    private var video: Bool { presentation == .video }
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
        Form {
            // Z2: the main graphic, without a header.
            Section { preview }
            fontSizeSection
            backgroundSection
            if video { styleSection }
            windowSection
        }
        .formStyle(.grouped)
        .labelStyle(.settingsRow)
        .id(state.requestedScenario)
        .settingsPageScroll(navigation, subpage: state.requestedScenario)
        // The scene cards warn about a chosen app that is not running.
        .onAppear { state.onRefreshSources?() }
    }

    // MARK: preview

    private var preview: some View {
        // The backdrop follows the system appearance (live); the window itself is always dark.
        SubtitleLayoutPreview(configuration: .init(
            scene: scene, fontSize: fontSize.wrappedValue, opacity: opacity.wrappedValue,
            videoStyle: state.videoCaptionStyle, videoArrangement: state.videoCaptionArrangement,
            darkBackdrop: colorScheme == .dark, display: display,
            speakingLanguages: state.speakLanguages(for: state.requestedScenario)))
            .overlay(alignment: .topLeading) {
                Text("示例")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.leading, 6)
                    .padding(.top, 3)
                    .allowsHitTesting(false)
            }
            .padding(.vertical, 4)
    }

    // MARK: 字号 and 背景

    private var fontSizeSection: some View {
        let defaultSize = SubtitleOpacityControl.defaultFontSize(for: scene)
        let size = fontSize.wrappedValue
        let value = String(localized: "\(Int(size)) 磅")
        return Section {
            HStack(spacing: 8) {
                Slider(value: fontSize, in: 16...36, step: 1) {
                    Text("字号")
                } minimumValueLabel: {
                    endGlyph(Icon.fontSmaller)
                } maximumValueLabel: {
                    endGlyph(Icon.fontLarger)
                } tick: { step in
                    step == defaultSize ? SliderTick(step) : nil
                }
                .labelsHidden()
                .accessibilityLabel(String(localized: "字号"))
                .accessibilityValue(Text(verbatim: value))
                valueText(value, enabled: true)
                IconButton(Icon.reset, help: String(localized: "恢复默认字号")) { fontSize.wrappedValue = defaultSize }
                    .disabled(size == defaultSize)
            }
            .padding(.leading, Ladder.rowTextInset)
        } header: {
            SectionHeader(String(localized: "字号"), symbol: Icon.fontSize)
        }
    }

    private var opacityControl: SubtitleOpacityControl {
        SubtitleOpacityControl.make(scene: scene, videoStyle: state.videoCaptionStyle, reduceTransparency: reduceTransparency)
    }

    /// Greyed with the reason in help while Reduce Transparency fixes the background (and a
    /// trailing accessibility glyph says so) or the stroke style draws none.
    private var backgroundSection: some View {
        let control = opacityControl
        let defaultOpacity = SubtitleOpacityControl.defaultOpacity
        let percent = Int((opacity.wrappedValue * 100).rounded())
        let atDefault = abs(opacity.wrappedValue - defaultOpacity) < 0.001
        let reason: String? = switch control.note {
        case .reduceTransparency?: String(localized: "系统已开启降低透明度")
        case .strokeHasNoBackground?: String(localized: "描边样式没有背景")
        case nil: nil
        }
        return Section {
            HStack(spacing: 8) {
                Slider(value: opacity, in: 0.35...1, step: 0.05) {
                    Text("背景")
                } minimumValueLabel: {
                    endGlyph(Icon.backgroundClear)
                } maximumValueLabel: {
                    endGlyph(Icon.backgroundSolid)
                } tick: { step in
                    abs(step - defaultOpacity) < 0.025 ? SliderTick(step) : nil
                }
                .labelsHidden()
                .disabled(!control.enabled)
                // The visible name is the short section title; VoiceOver keeps what N% measures.
                .accessibilityLabel(String(localized: "背景不透明度"))
                .accessibilityValue(Text(verbatim: "\(percent)%"))
                .accessibilityHint(reason ?? String(localized: "只调背景，文字不变淡"))
                valueText("\(percent)%", enabled: control.enabled)
                if control.note == .reduceTransparency {
                    Image(systemName: Icon.reduceTransparency)
                        .font(.system(size: Ladder.inline))
                        .foregroundStyle(.secondary)
                        .frame(width: Ladder.hitArea, height: Ladder.hitArea)
                        .help(String(localized: "系统已开启降低透明度"))
                        .accessibilityLabel(video ? String(localized: "系统已开启“降低透明度”，改用实底")
                                                  : String(localized: "系统已开启“降低透明度”，背景不透明"))
                }
                IconButton(Icon.reset, help: String(localized: "恢复默认 85%")) { opacity.wrappedValue = defaultOpacity }
                    .disabled(!control.enabled || atDefault)
            }
            .padding(.leading, Ladder.rowTextInset)
            .help(reason ?? String(localized: "只调背景，文字不变淡"))
        } header: {
            SectionHeader(String(localized: "背景"), symbol: Icon.background)
        }
    }

    /// The smaller/larger glyphs at a slider's ends (13 pt, secondary).
    private func endGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: Ladder.inline))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func valueText(_ text: String, enabled: Bool) -> some View {
        Text(verbatim: text)
            .monospacedDigit()
            .foregroundStyle(enabled ? .primary : .secondary)
            .frame(width: 48, alignment: .trailing)
            .accessibilityHidden(true)
    }

    // MARK: 样式 (video only)

    private var styleSection: some View {
        Section {
            ThumbnailChoice(String(localized: "样式"), options: styleOptions,
                            selection: $state.videoCaptionStyle, size: .wide)
                .padding(.leading, Ladder.rowTextInset)
                .padding(.vertical, 4)
            LabeledContent {
                ThumbnailChoice(String(localized: "排列"), options: arrangementOptions,
                                selection: $state.videoCaptionArrangement, size: .compact)
                    .padding(.vertical, 4)
            } label: {
                Label("排列", systemImage: Icon.captionArrangement)
            }
            Toggle(isOn: $state.videoLongSilenceDim) {
                Label("静默变暗", systemImage: Icon.silenceDim)
            }
            .help("8 秒无新内容时变暗")
            .accessibilityHint(String(localized: "最后一页读完 8 秒后无新内容时，文字降到 35%"))
        } header: {
            SectionHeader(String(localized: "样式"), symbol: Icon.subtitles)
        }
    }

    private var styleOptions: [ThumbnailChoice<VideoCaptionStyle>.Option] {
        [
            .init(.fittedGlass, name: String(localized: "贴合玻璃"), help: String(localized: "只在文字后面铺毛玻璃")) {
                CaptionStyleThumbnail(style: .fittedGlass)
            },
            .init(.stroke, name: String(localized: "描边"), help: String(localized: "不铺背景，文字加描边和阴影")) {
                CaptionStyleThumbnail(style: .stroke)
            },
            .init(.plate, name: String(localized: "实底"), help: String(localized: "每行文字后垫深色底块")) {
                CaptionStyleThumbnail(style: .plate)
            },
        ]
    }

    private var arrangementOptions: [ThumbnailChoice<VideoCaptionArrangement>.Option] {
        [
            .init(.sourceFirst, name: String(localized: "原文在上")) {
                CaptionArrangementThumbnail(arrangement: .sourceFirst)
            },
            .init(.translationFirst, name: String(localized: "中文在上")) {
                CaptionArrangementThumbnail(arrangement: .translationFirst)
            },
        ]
    }

    // MARK: 窗口

    /// The window's behaviour as facts (§5.4 keeps 共享屏幕不可见 and 收起后继续 visible); the one
    /// ⓘ says how to bring a minimized window back.
    private var windowSection: some View {
        Section {
            FactRow([
                FactChip(String(localized: "可拖动"), symbol: Icon.windowMovable,
                         help: String(localized: "拖标题栏或文字；视频可在菜单锁定")),
                FactChip(String(localized: "不抢焦点"), symbol: Icon.windowNoFocus,
                         help: String(localized: "键盘输入留在当前 App")),
                FactChip(String(localized: "收起后继续"), symbol: Icon.windowMinimize,
                         help: video ? String(localized: "最小化后收听和翻译继续，可从菜单栏恢复")
                                     : String(localized: "最小化后同传继续，可从菜单栏恢复")),
                FactChip(String(localized: "共享屏幕不可见"), symbol: Icon.windowNotShared,
                         // Only what NSWindow.SharingType.none is documented to do: Apple calls
                         // it a legacy constant that can leave content out of certain sharing
                         // situations and must not be relied on to hide content from capture
                         // (ARCHITECTURE, LISTEN). The help promises no more than that.
                         help: String(localized: "部分共享方式下可能不显示，不作保证")),
            ], indented: true)
        } header: {
            SectionHeader(String(localized: "窗口"), symbol: Icon.subtitleWindow,
                          info: [String(localized: "最小化后从菜单栏选“恢复字幕窗口”。")])
        }
    }
}

/// The stand-in video picture (SubtitleTokens.captionThumbnailPicture) inside a thumbnail's
/// white or black backdrop: captions sit on a video, and the black outline and plates need
/// something other than black to show against in Dark Mode.
private struct CaptionThumbnailPicture: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(nsColor: SubtitleStyle.nsColor(SubtitleTokens.captionThumbnailPicture)))
            .padding(4)
    }
}

/// A 72 × 40 picture of one video caption style (§3.12), from the caption tokens: the grey
/// source line over the white Chinese line on the video picture, behind one glass block
/// (贴合玻璃), outlined with no background (描边), or each on its own dark plate (实底).
private struct CaptionStyleThumbnail: View {
    let style: VideoCaptionStyle

    var body: some View {
        ZStack {
            CaptionThumbnailPicture()
            if style == .fittedGlass {
                // The live glass is the dark HUD material, whatever the page behind it.
                RoundedRectangle(cornerRadius: 5)
                    .fill(.thinMaterial)
                    .environment(\.colorScheme, .dark)
                    .frame(width: 56, height: 24)
            }
            VStack(spacing: 3) {
                line(width: 30, height: 3, color: Color(nsColor: SubtitleStyle.color(.videoSource)))
                line(width: 44, height: 4, color: Color(nsColor: SubtitleStyle.color(.textPrimary)))
            }
        }
    }

    private func line(width: Double, height: Double, color: Color) -> some View {
        Capsule()
            .fill(color)
            .overlay {
                if style == .stroke { Capsule().stroke(Color(nsColor: .black), lineWidth: 1) }
            }
            .frame(width: width, height: height)
            .padding(.horizontal, style == .plate ? 3 : 0)
            .padding(.vertical, style == .plate ? 1.5 : 0)
            .background {
                if style == .plate {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(VideoCaptionStyle.plateAlpha(reduceTransparency: false)))
                }
            }
    }
}

/// A 48 × 32 picture of the caption order, from the same caption tokens and video picture as
/// the style thumbnails: the thinner, shorter grey source line and the bolder white Chinese
/// line, in the chosen order.
private struct CaptionArrangementThumbnail: View {
    let arrangement: VideoCaptionArrangement

    var body: some View {
        ZStack {
            CaptionThumbnailPicture()
            VStack(spacing: 4) {
                if arrangement == .sourceFirst {
                    source
                    translation
                } else {
                    translation
                    source
                }
            }
        }
    }

    private var source: some View {
        Capsule().fill(Color(nsColor: SubtitleStyle.color(.videoSource))).frame(width: 26, height: 3)
    }

    private var translation: some View {
        Capsule().fill(Color(nsColor: SubtitleStyle.color(.textPrimary))).frame(width: 34, height: 4)
    }
}
