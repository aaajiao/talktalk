import Testing
@testable import TalkTalkCloud

// These tests never touch the real Keychain; they cover naming and the no-echo helpers.
@Suite struct KeychainSecretTests {
    @Test func serviceNamesFollowTheBundleID() {
        #expect(KeychainSecret.openAI(bundleID: "com.aaajiao.talktalk")?.service == "com.aaajiao.talktalk.openai")
        #expect(KeychainSecret.openAI(bundleID: "com.aaajiao.talktalk.dev")?.service == "com.aaajiao.talktalk.dev.openai")
        #expect(KeychainSecret.openAI(bundleID: "com.aaajiao.talktalk.dev")?.account == "api-key")
        // The bench entry is for command-line tools only; the app never derives it.
        #expect(KeychainSecret.openAI(bundleID: "com.aaajiao.talktalk.bench") == nil)
        #expect(KeychainSecret.openAI(bundleID: "") == nil)
    }

    @Test func shapeProblemsNeverContainTheKey() {
        let fake = "sk-proj-" + String(repeating: "A", count: 150) + "Zq9x"
        #expect(APIKeyShape.problem(fake) == nil)
        #expect(APIKeyShape.normalized("  \(fake)\n") == fake)
        for bad in ["", "pk-" + fake, "sk-short", fake + " tail", fake + "ü"] {
            let reason = APIKeyShape.problem(bad)
            #expect(reason != nil)
            #expect(!(reason ?? "").contains("AAAA"))
        }
        #expect(APIKeyShape.masked(fake) == "sk-…Zq9x")
    }
}
