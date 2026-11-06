import AppKit
import Testing
import TalkTalkCore

/// A missing SF Symbol draws nothing (the done page's `square.grid.3x1` did). Every glyph the
/// menu bar menu and onboarding name through tokens must exist on this system.
@Suite struct MenuOnboardingSymbolTests {
    private func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    @Test func onboardingStepGlyphsExist() {
        for step in OnboardingStep.allCases {
            #expect(exists(step.guideSymbol), "\(step): \(step.guideSymbol)")
        }
    }

    @Test func menuAndDonePageGlyphsExist() {
        typealias M = SubtitleTokens.MenuIcon
        typealias O = SubtitleTokens.OnboardingIcon
        let names = [M.standby, M.listening, M.warming, M.audioUnconfirmed, M.degraded, M.needsAttention,
                     M.micUnused, M.subtitles, M.restoreWindow, M.restoreInput, M.announcement,
                     M.notifications, M.about, M.onboarding,
                     O.menuBar, O.quickStart, O.otherScenes]
        for name in names {
            #expect(exists(name), "\(name)")
        }
    }
}
