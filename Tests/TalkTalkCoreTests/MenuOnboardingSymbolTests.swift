import AppKit
import Testing
import TalkTalkCore

/// A missing SF Symbol draws nothing (the done page's `square.grid.3x1` did). Every glyph
/// onboarding names through tokens must exist on this system; the menu's glyphs are checked
/// with the other token families in SettingsSymbolTests.
@Suite struct MenuOnboardingSymbolTests {
    private func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    @Test func onboardingStepGlyphsExist() {
        for step in OnboardingStep.allCases {
            #expect(exists(step.guideSymbol), "\(step): \(step.guideSymbol)")
        }
    }

    @Test func donePageGlyphsExist() {
        typealias O = SubtitleTokens.OnboardingIcon
        for name in [O.menuBar, O.quickStart, O.otherScenes] {
            #expect(exists(name), "\(name)")
        }
    }
}
