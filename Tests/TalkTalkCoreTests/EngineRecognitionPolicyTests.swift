import Testing
@testable import TalkTalkCore

@Suite struct EngineRecognitionPolicyTests {
    @Test func legacySynthesisOnlyProfileUsesAppleInBothDirections() {
        for preference in SpeechRecognitionEngine.allCases {
            #expect(EngineRecognitionPolicy.listening(preferred: preference, installedProfile: .compact16) == .apple)
            #expect(EngineRecognitionPolicy.speaking(preferred: preference, installedProfile: .compact16) == .apple)
        }
    }

    @Test func localProfilesKeepListenAndSpeakChoicesIndependent() {
        for profile in EngineProfile.selectablePresets {
            for listen in SpeechRecognitionEngine.allCases {
                for speak in SpeechRecognitionEngine.allCases {
                    #expect(EngineRecognitionPolicy.listening(preferred: listen, installedProfile: profile) == listen)
                    #expect(EngineRecognitionPolicy.speaking(preferred: speak, installedProfile: profile) == speak)
                }
            }
        }
    }

    @Test func missingOrCustomInstallationPreservesExplicitChoices() {
        for preference in SpeechRecognitionEngine.allCases {
            #expect(EngineRecognitionPolicy.listening(preferred: preference, installedProfile: nil) == preference)
            #expect(EngineRecognitionPolicy.speaking(preferred: preference, installedProfile: nil) == preference)
        }
    }

    @Test func leavingLegacyProfileRestoresEachUnchangedPreference() {
        for listen in SpeechRecognitionEngine.allCases {
            for speak in SpeechRecognitionEngine.allCases {
                #expect(EngineRecognitionPolicy.listening(preferred: listen, installedProfile: .compact16) == .apple)
                #expect(EngineRecognitionPolicy.speaking(preferred: speak, installedProfile: .compact16) == .apple)
                #expect(EngineRecognitionPolicy.listening(preferred: listen, installedProfile: .standard) == listen)
                #expect(EngineRecognitionPolicy.speaking(preferred: speak, installedProfile: .standard) == speak)
            }
        }
    }
}
