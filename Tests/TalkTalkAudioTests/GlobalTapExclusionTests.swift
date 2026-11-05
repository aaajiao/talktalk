import Testing
@testable import TalkTalkAudio

@Suite struct GlobalTapExclusionTests {
    @Test func excludesDescendantsAndResponsibleXPCWithoutReadingFiles() {
        let resolver = MeetingSourceResolver(lookup: .init(
            parentPID: { [11: 10, 21: 20, 31: 1, 41: 40][$0] },
            bundleID: { [10: "com.aaajiao.talktalk.dev", 20: "com.readread.app", 40: "us.zoom.xos"][$0] },
            responsiblePID: { $0 == 31 ? 20 : nil }))
        let processes = [11, 21, 31, 41, 99].map {
            AudioProcessInfo(objectID: UInt32($0), pid: Int32($0), bundleID: nil, isRunningInput: false, isRunningOutput: true)
        }
        #expect(resolver.globalTapExclusions(processes, ownPID: 99) == [11, 21, 31, 99])
    }
}
