import SwiftUI
import TalkTalkCore

/// Updates native SwiftUI localized keys without replacing view identity or running
/// disappearance handlers. String(appLocalized:) also observes the shared language runtime.
private struct AppLanguageEnvironment: ViewModifier {
    private let language = AppLanguageStore.shared

    func body(content: Content) -> some View {
        content.environment(\.locale, language.locale)
    }
}

public extension View {
    func appLanguage() -> some View { modifier(AppLanguageEnvironment()) }
}
