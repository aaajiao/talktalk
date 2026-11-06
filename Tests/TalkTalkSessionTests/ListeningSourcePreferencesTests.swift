import Foundation
import Testing
@testable import TalkTalkSession

@Suite struct ListeningSourcePreferencesTests {
    @Test func meetingAndVideoSelectionsPersistIndependently() throws {
        try withDefaults { defaults, suite in
            ListeningSourcePreferences.setSource("us.zoom.xos", for: .meeting, defaults: defaults)
            ListeningSourcePreferences.setSource("com.apple.Safari", for: .captions, defaults: defaults)

            let reloaded = try #require(UserDefaults(suiteName: suite))
            #expect(ListeningSourcePreferences.source(for: .meeting, defaults: reloaded) == "us.zoom.xos")
            #expect(ListeningSourcePreferences.source(for: .captions, defaults: reloaded) == "com.apple.Safari")

            ListeningSourcePreferences.setSource("com.google.Chrome", for: .captions, defaults: reloaded)
            #expect(ListeningSourcePreferences.source(for: .meeting, defaults: defaults) == "us.zoom.xos")
            #expect(ListeningSourcePreferences.source(for: .captions, defaults: defaults) == "com.google.Chrome")
        }
    }

    @Test func legacyMeetingChoiceIsPreservedWithoutMigratingIntoVideo() throws {
        try withDefaults { defaults, _ in
            defaults.set("com.microsoft.teams2", forKey: "meeting.lastSource")

            #expect(ListeningSourcePreferences.source(for: .meeting, defaults: defaults) == "com.microsoft.teams2")
            #expect(ListeningSourcePreferences.source(for: .captions, defaults: defaults) == nil)
            #expect(defaults.object(forKey: "captions.lastSource") == nil)
        }
    }

    @Test func phoneAlwaysUsesPhoneAndIgnoresWrites() throws {
        try withDefaults { defaults, _ in
            ListeningSourcePreferences.setSource("us.zoom.xos", for: .meeting, defaults: defaults)
            ListeningSourcePreferences.setSource("com.apple.Safari", for: .captions, defaults: defaults)
            let sources: [String?] = ["com.google.Chrome", MeetingMode.phoneAppID, "", nil]
            for source in sources {
                ListeningSourcePreferences.setSource(source, for: .phone, defaults: defaults)
                #expect(ListeningSourcePreferences.source(for: .phone, defaults: defaults) == MeetingMode.phoneAppID)
            }
            #expect(ListeningSourcePreferences.source(for: .meeting, defaults: defaults) == "us.zoom.xos")
            #expect(ListeningSourcePreferences.source(for: .captions, defaults: defaults) == "com.apple.Safari")
            #expect(defaults.object(forKey: "phone.lastSource") == nil)
        }
    }

    @Test func stalePhoneSelectionsAreIgnoredAndCannotBeSavedOutsidePhone() throws {
        try withDefaults { defaults, _ in
            defaults.set(MeetingMode.phoneAppID, forKey: "meeting.lastSource")
            defaults.set(MeetingMode.phoneAppID, forKey: "captions.lastSource")
            #expect(ListeningSourcePreferences.source(for: .meeting, defaults: defaults) == nil)
            #expect(ListeningSourcePreferences.source(for: .captions, defaults: defaults) == nil)

            ListeningSourcePreferences.setSource(MeetingMode.phoneAppID, for: .meeting, defaults: defaults)
            ListeningSourcePreferences.setSource(MeetingMode.phoneAppID, for: .captions, defaults: defaults)
            #expect(defaults.object(forKey: "meeting.lastSource") == nil)
            #expect(defaults.object(forKey: "captions.lastSource") == nil)
            #expect(ListeningSourcePreferences.source(for: .phone, defaults: defaults) == MeetingMode.phoneAppID)
        }
    }

    @Test func clearingOneScenarioLeavesTheOtherSelectionAlone() throws {
        try withDefaults { defaults, _ in
            ListeningSourcePreferences.setSource("us.zoom.xos", for: .meeting, defaults: defaults)
            ListeningSourcePreferences.setSource("com.apple.Safari", for: .captions, defaults: defaults)
            ListeningSourcePreferences.setSource("", for: .captions, defaults: defaults)
            #expect(ListeningSourcePreferences.source(for: .meeting, defaults: defaults) == "us.zoom.xos")
            #expect(ListeningSourcePreferences.source(for: .captions, defaults: defaults) == nil)
            #expect(defaults.object(forKey: "captions.lastSource") == nil)

            ListeningSourcePreferences.setSource("com.google.Chrome", for: .captions, defaults: defaults)
            ListeningSourcePreferences.setSource(nil, for: .meeting, defaults: defaults)
            #expect(ListeningSourcePreferences.source(for: .meeting, defaults: defaults) == nil)
            #expect(defaults.object(forKey: "meeting.lastSource") == nil)
            #expect(ListeningSourcePreferences.source(for: .captions, defaults: defaults) == "com.google.Chrome")
        }
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "TalkTalkTests.ListeningSourcePreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }
}
