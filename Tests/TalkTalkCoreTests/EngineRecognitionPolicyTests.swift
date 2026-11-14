import Testing
@testable import TalkTalkCore

@Suite struct EngineRecognitionPolicyTests {
    @Test func changingOnlyTTSPreservesSynthesisOnlyAppleCompatibility() {
        let mingOnly = EngineRecognitionPolicy.compatibilityProfile(activeRoles: ["tts": "tts-ming3-0.5b-bf16"])
        #expect(mingOnly == .compact16)
        #expect(EngineRecognitionPolicy.speaking(preferred: .qwen, installedProfile: mingOnly) == .apple)
        let mingAndASR = EngineRecognitionPolicy.compatibilityProfile(activeRoles: [
            "tts": "tts-ming3-0.5b-bf16", "asr": "asr-qwen3-0.6b-8bit"])
        #expect(EngineRecognitionPolicy.speaking(preferred: .qwen, installedProfile: mingAndASR) == .qwen)
        #expect(EngineRecognitionPolicy.listening(preferred: .apple, installedProfile: mingAndASR) == .apple)
        #expect(EngineRecognitionPolicy.compatibilityProfile(activeRoles: [:]) == nil)
    }

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

    @Test func recognitionOnlyInstallationPreservesBothIndependentPreferences() {
        let profile = EngineRecognitionPolicy.compatibilityProfile(activeRoles: ["asr": "asr-qwen3-0.6b-8bit"])
        #expect(profile != .compact16)
        for listen in SpeechRecognitionEngine.allCases {
            for speak in SpeechRecognitionEngine.allCases {
                #expect(EngineRecognitionPolicy.listening(preferred: listen, installedProfile: profile) == listen)
                #expect(EngineRecognitionPolicy.speaking(preferred: speak, installedProfile: profile) == speak)
            }
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
