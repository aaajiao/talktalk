import Foundation
import Testing
@testable import TalkTalkCore

@Suite struct PolicyProfileTests {
    /// Golden: decode → encode must reproduce the file exactly (as JSON values). A key the Swift
    /// types do not model would be dropped by encoding and fail here.
    @Test func roundTripsTheDefaultFileWithoutLosingAField() throws {
        let data = try Data(contentsOf: TestResources.resource("PolicyProfile.default.json"))
        let profile = try PolicyProfile.decode(data)
        let reencoded = try JSONEncoder().encode(profile)
        let original = try JSONSerialization.jsonObject(with: data) as! NSDictionary
        let again = try JSONSerialization.jsonObject(with: reencoded) as! NSDictionary
        #expect(original == again)
    }

    /// The file is §5.3 verbatim.
    @Test func defaultFileIsTheArchitectureBlock() throws {
        let doc = try String(contentsOf: TestResources.repoRoot.appendingPathComponent("docs/ARCHITECTURE.md"), encoding: .utf8)
        guard let start = doc.range(of: "```json\n{\"listen\":"),
              let end = doc.range(of: "```", range: start.upperBound..<doc.endIndex) else {
            Issue.record("§5.3 JSON block not found"); return
        }
        let block = String(doc[doc.index(start.lowerBound, offsetBy: 8)..<end.lowerBound])
        let fromDoc = try JSONSerialization.jsonObject(with: Data(block.utf8)) as! NSDictionary
        let fromFile = try JSONSerialization.jsonObject(with: Data(contentsOf: TestResources.resource("PolicyProfile.default.json"))) as! NSDictionary
        #expect(fromDoc == fromFile)
    }

    @Test func hedgeStructsMatchTheJSONFieldByField() throws {
        let p = try TestResources.profile()
        let h = p.speak.mt.hedge
        #expect(h == HedgeConfig(enabled: true, on: .firstTextDelta, afterMs: 1000, stallAfterDeltaMs: 500, maxInFlight: 2,
                                 fastFailHedge: true, failAfterDeltaMinRemainMs: 800, startAppleAtHedge: true, pauseAfter429S: 30))
        #expect(p.speak.mt.totalDeadlineMs == 2500)
        #expect(p.speak.mt.extendToDrain == ExtendToDrain(enabled: true, ttsFirstChunkMs: "rollingP95", marginMs: 100,
                                                          unrenderedFactor: 0.7, inFlightFactor: 0, maxDeadlineMs: 5000,
                                                          subtractAppleP95WhenLate: true))
        #expect(p.speak.mt.guardRetry == GuardRetry(hedgeAfterMs: 0, floorMs: 1200, fromDrain: true, maxMs: 2500, onlyIfMaskedMs: 1500))
        #expect(p.speak.mt.afterNewlineGraceMs == 300)
        #expect(p.speak.mt.maxOutputTokens(for: .en) == 48)
        #expect(p.speak.mt.maxOutputTokens(for: .de) == 56)
    }

    /// HedgePolicy decodes straight from the speak.mt object: same field names as the JSON.
    @Test func hedgePolicyDecodesDirectlyFromSpeakMT() throws {
        let data = try Data(contentsOf: TestResources.resource("PolicyProfile.default.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let mt = (root["speak"] as! [String: Any])["mt"]!
        let policy = try JSONDecoder().decode(HedgePolicy.self, from: JSONSerialization.data(withJSONObject: mt))
        #expect(policy == (try TestResources.profile()).speakHedgePolicy)
    }

    @Test func listenHedgeTakesMissingFieldsFromSpeak() throws {
        let p = try TestResources.profile()
        #expect(p.listen.finalMT.hedge.enabled == false)
        #expect(p.listen.finalMT.hedge.afterMs == 0)
        #expect(p.listen.finalMT.hedge.stallAfterDeltaMs == nil)
        var expected = p.speak.mt.hedge
        expected.enabled = false
        expected.afterMs = 0
        #expect(p.listenFinalHedge == expected)
        #expect(p.listenHedgePolicy.totalDeadlineMs == 2000)
        #expect(p.listenHedgePolicy.extendToDrain.enabled == false)
    }

    @Test func cloudURLsNeverDoubleTheVersionPrefix() throws {
        var c = try TestResources.profile().cloud
        #expect(c.url(c.responsesPath)?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(c.keepWarmURL(model: "gpt-6-luna")?.absoluteString == "https://api.openai.com/v1/models/gpt-6-luna")
        c.origin = "https://api.openai.com/"
        #expect(c.url("/v1/models")?.absoluteString == "https://api.openai.com/v1/models")
        #expect(c.store == false)
        #expect(c.model == "gpt-6-luna")
        #expect(c.effort == "none")
    }

    @Test func germanCommitMinOverride() throws {
        let p = try TestResources.profile()
        #expect(p.speak.commitMin(for: .en).estCjk == 8)
        #expect(p.speak.commitMin(for: .de).estCjk == 10)
        #expect(p.speak.commitMin(for: .de).speechS == 1.5)
        #expect(p.speak.commitMin(for: .de).sinceOnsetS == 1.2)
        #expect(p.listen.finalize.silenceMs(for: .de) == 1000)
    }

    @Test func decodingFailsOnAMissingRequiredField() throws {
        let data = try Data(contentsOf: TestResources.resource("PolicyProfile.default.json"))
        var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var speak = root["speak"] as! [String: Any]
        var mt = speak["mt"] as! [String: Any]
        var hedge = mt["hedge"] as! [String: Any]
        hedge.removeValue(forKey: "afterMs")
        mt["hedge"] = hedge; speak["mt"] = mt; root["speak"] = speak
        #expect(throws: DecodingError.self) {
            try PolicyProfile.decode(JSONSerialization.data(withJSONObject: root))
        }
    }
}
