import Foundation
import Observation
import Synchronization
import Testing
import TalkTalkTestSupport
@testable import TalkTalkCore

@Suite(.temporaryFiles) struct AppLocalizationTests {
    @Test func explicitBundlesSwitchImmediatelyAndKeepNumericInterpolation() throws {
        let bundle = try fixtureBundle()
        let runtime = AppLocalizationRuntime(bundle: bundle, language: .english)
        #expect(runtime.localized("通用") == "General")
        #expect(runtime.localized("数量 \(7)") == "Count 7")
        #expect(runtime.snapshot().locale.identifier == "en")
        runtime.setLanguage(.chinese)
        #expect(runtime.localized("通用") == "通用")
        #expect(runtime.localized("数量 \(7)") == "数量 7")
        #expect(runtime.snapshot().locale.identifier == "zh-Hans")
        runtime.setLanguage(.english)
        #expect(runtime.localized("通用") == "General")
    }

    @Test func missingLocalizationBundleAndMissingKeysFallBack() throws {
        let bundle = try fixtureBundle(includeChinese: false)
        let runtime = AppLocalizationRuntime(bundle: bundle, language: .chinese)
        #expect(runtime.snapshot().bundle.bundleURL == bundle.bundleURL)
        #expect(runtime.localized("unknown-l10n-test-key") == "unknown-l10n-test-key")
        runtime.setLanguage(.english)
        #expect(runtime.localized("unknown-l10n-test-key") == "unknown-l10n-test-key")
    }

    @Test func localizedStringReadsParticipateInObservation() throws {
        let runtime = AppLocalizationRuntime(bundle: try fixtureBundle(), language: .english)
        let changes = Mutex(0)
        withObservationTracking {
            #expect(runtime.localized("通用") == "General")
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        runtime.setLanguage(.english)
        #expect(changes.withLock { $0 } == 0)
        runtime.setLanguage(.chinese)
        #expect(changes.withLock { $0 } == 1)
        #expect(runtime.localized("通用") == "通用")
    }

    @MainActor
    @Test func selectionPersistsAndSystemChoiceUsesOriginalSystemLanguage() throws {
        let suite = "AppLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("de", forKey: "meeting.listen.sourceLanguage")
        let runtime = AppLocalizationRuntime(bundle: try fixtureBundle(), language: .english)
        let store = AppLanguageStore(defaults: defaults, preferredLanguages: ["zh-Hant", "en-US"], runtime: runtime)
        #expect(store.selection == .system)
        #expect(store.language == .chinese)
        #expect(runtime.localized("通用") == "通用")
        let changes = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: AppLanguageStore.didChangeNotification,
                                                              object: store, queue: nil) { _ in
            changes.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.selection = .english
        #expect(runtime.localized("通用") == "General")
        #expect(AppLanguage.load(defaults: defaults) == .english)
        store.selection = .system
        #expect(store.locale.identifier == "zh-Hans")
        #expect(runtime.localized("通用") == "通用")
        store.selection = .chinese // Same resolved language; save choice without notifying again.
        #expect(AppLanguage.load(defaults: defaults) == .chinese)
        #expect(changes.withLock { $0 } == 2)
        #expect(defaults.string(forKey: "meeting.listen.sourceLanguage") == "de")
    }

    @Test func backgroundReadsUseCompleteSnapshotsWhileLanguageChanges() async throws {
        let runtime = AppLocalizationRuntime(bundle: try fixtureBundle(), language: .english)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for language in [AppLanguage.chinese, .english, .chinese, .english] {
                    runtime.setLanguage(language)
                }
            }
            group.addTask {
                for _ in 0..<20 {
                    let text = runtime.localized("数量 \(7)")
                    #expect(text == "Count 7" || text == "数量 7")
                }
            }
        }
    }

    private func fixtureBundle(includeChinese: Bool = true) throws -> Bundle {
        let root = try TestTemporaryDirectory.make(prefix: "tt-localization")
            .appendingPathComponent("Fixture.bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.aaajiao.talktalk.l10n-test.\(UUID().uuidString)",
                    "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let translations = ["en": "\"通用\" = \"General\";\n\"数量 %lld\" = \"Count %lld\";\n",
                            "zh-Hans": "\"通用\" = \"通用\";\n\"数量 %lld\" = \"数量 %lld\";\n"]
        for (language, strings) in translations where language == "en" || includeChinese {
            let folder = resources.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try strings.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        return try #require(Bundle(url: root))
    }
}
