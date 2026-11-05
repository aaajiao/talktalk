import Testing
import TalkTalkCore
@testable import TalkTalkSession

@Suite struct RemoteVADIngestTests {
    @Test func partialVADFrameIsUnknownUntilClassifiedAndResetClearsCoverage() {
        let ingest = AudioIngest()
        let start: HostTime = 1_000_000_000
        ingest.push(Array(repeating: 0, count: 160), host: start)
        #expect(ingest.remoteVADOverlap(from: start, to: start + 10_000_000) == nil)
        ingest.push(Array(repeating: 0, count: 160), host: start + 10_000_000)
        #expect(ingest.remoteVADOverlap(from: start, to: start + 20_000_000) == 0)
        ingest.reset()
        #expect(ingest.remoteVADOverlap(from: start, to: start + 20_000_000) == nil)
    }
}
