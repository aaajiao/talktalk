import Testing
@testable import TalkTalkCore

@Suite struct EngineRecognitionPolicyTests {
    @Test func intentionalAppleProfileUsesAppleInBothDirections() {
        for preference in SpeechRecognitionEngine.allCases {
            #expect(EngineRecognitionPolicy.listening(preferred: preference, installedProfile: .compact16) == .apple)
        }
        #expect(EngineRecognitionPolicy.speaking(installedProfile: .compact16) == .apple)
    }

    @Test func qwenProfilesPreserveTheUsersListenChoice() {
        for profile in [EngineProfile.max, .standard, .compact24] {
            for preference in SpeechRecognitionEngine.allCases {
                #expect(EngineRecognitionPolicy.listening(preferred: preference, installedProfile: profile) == preference)
            }
            #expect(EngineRecognitionPolicy.speaking(installedProfile: profile) == .qwen)
        }
    }

    @Test func missingOrUnknownInstallationIsNotAnIntentionalAppleProfile() {
        #expect(EngineRecognitionPolicy.listening(preferred: .qwen, installedProfile: nil) == .qwen)
        #expect(EngineRecognitionPolicy.listening(preferred: .apple, installedProfile: nil) == .apple)
        #expect(EngineRecognitionPolicy.speaking(installedProfile: nil) == .qwen)
    }

    @Test func leavingTheAppleProfileRestoresTheUnchangedPreference() {
        let savedPreference = SpeechRecognitionEngine.qwen
        #expect(EngineRecognitionPolicy.listening(preferred: savedPreference, installedProfile: .compact16) == .apple)
        #expect(EngineRecognitionPolicy.listening(preferred: savedPreference, installedProfile: .standard) == .qwen)
    }
}
