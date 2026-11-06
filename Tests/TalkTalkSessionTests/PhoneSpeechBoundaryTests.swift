import Testing
import TalkTalkSession

@Suite struct PhoneSpeechBoundaryTests {
    @Test func initialNoReaderLeavesLocalSpeechUnpaused() {
        var boundary = PhoneSpeechBoundary()
        #expect(!boundary.resetPending)
        let unknown = boundary.observe(reader: nil)
        let initial = boundary.observe(reader: false)
        #expect(unknown == nil)
        #expect(initial == nil)
        #expect(!boundary.resetPending)
    }

    @Test func preparingDuringAnExistingCallOnlyEstablishesTheBaseline() {
        var boundary = PhoneSpeechBoundary()
        let initial = boundary.observe(reader: true)
        #expect(initial == nil)
        #expect(!boundary.resetPending)
    }

    @Test func repeatedNoReaderAndMissingObservationsDoNotInventBoundaries() {
        var boundary = PhoneSpeechBoundary()
        let observations: [Bool?] = [false, false, nil, false, nil, false]
        for reader in observations {
            let reset = boundary.observe(reader: reader)
            #expect(reset == nil)
            #expect(!boundary.resetPending)
        }
    }

    @Test func readerArrivalAndLossEachRequireOneReset() throws {
        var boundary = PhoneSpeechBoundary()
        let initial = boundary.observe(reader: false)
        #expect(initial == nil)
        let observedArrival = boundary.observe(reader: true)
        let arrival = try #require(observedArrival)
        #expect(boundary.resetPending)
        let repeatedArrival = boundary.observe(reader: true)
        #expect(repeatedArrival == nil)
        let completedArrival = boundary.completeReset(token: arrival)
        #expect(completedArrival)
        #expect(!boundary.resetPending)
        // An active reader can be silent without changing this state.
        let silentReader = boundary.observe(reader: true)
        #expect(silentReader == nil)

        let observedLoss = boundary.observe(reader: false)
        let loss = try #require(observedLoss)
        #expect(loss > arrival)
        #expect(boundary.resetPending)
        let repeatedLoss = boundary.observe(reader: false)
        #expect(repeatedLoss == nil)
        let completedLoss = boundary.completeReset(token: loss)
        #expect(completedLoss)
        #expect(!boundary.resetPending) // Local speech resumes even with no Phone reader.
        let stillNoReader = boundary.observe(reader: false)
        #expect(stillNoReader == nil)
    }

    @Test func unknownObservationPreservesTheLastDefiniteStateAndPendingReset() throws {
        var boundary = PhoneSpeechBoundary()
        let initial = boundary.observe(reader: true)
        let unknownBeforeLoss = boundary.observe(reader: nil)
        #expect(initial == nil)
        #expect(unknownBeforeLoss == nil)
        let observedLoss = boundary.observe(reader: false)
        let loss = try #require(observedLoss)
        let unknownDuringReset = boundary.observe(reader: nil)
        #expect(unknownDuringReset == nil)
        #expect(boundary.resetPending)
        let completedLoss = boundary.completeReset(token: loss)
        #expect(completedLoss)
        let unknownAfterReset = boundary.observe(reader: nil)
        let stillNoReader = boundary.observe(reader: false)
        #expect(unknownAfterReset == nil)
        #expect(stillNoReader == nil)
        #expect(!boundary.resetPending)
    }

    @Test func lateCompletionCannotReleaseANewerResetBarrier() throws {
        var boundary = PhoneSpeechBoundary()
        let initial = boundary.observe(reader: false)
        #expect(initial == nil)
        let observedArrival = boundary.observe(reader: true)
        let arrival = try #require(observedArrival)
        let observedLoss = boundary.observe(reader: false)
        let loss = try #require(observedLoss)
        #expect(loss > arrival)
        #expect(!boundary.isPendingReset(token: arrival))
        #expect(boundary.isPendingReset(token: loss))
        let completedArrival = boundary.completeReset(token: arrival)
        #expect(!completedArrival)
        #expect(boundary.resetPending)
        let completedLoss = boundary.completeReset(token: loss)
        #expect(completedLoss)
        #expect(!boundary.resetPending)
        #expect(!boundary.isPendingReset(token: loss))
        let duplicateCompletion = boundary.completeReset(token: loss)
        #expect(!duplicateCompletion)
    }

    @Test func invalidationRevokesOldCompletionAndReestablishesTheBaseline() throws {
        var boundary = PhoneSpeechBoundary()
        let initial = boundary.observe(reader: true)
        #expect(initial == nil)
        let observedOld = boundary.observe(reader: false)
        let old = try #require(observedOld)
        #expect(boundary.isPendingReset(token: old))
        boundary.invalidate()
        #expect(!boundary.resetPending)
        #expect(!boundary.isPendingReset(token: old))
        let invalidatedCompletion = boundary.completeReset(token: old)
        #expect(!invalidatedCompletion)
        let newBaseline = boundary.observe(reader: true)
        #expect(newBaseline == nil)
        #expect(!boundary.resetPending)

        let observedCurrent = boundary.observe(reader: false)
        let current = try #require(observedCurrent)
        #expect(current > old)
        #expect(!boundary.isPendingReset(token: old))
        #expect(boundary.isPendingReset(token: current))
        let oldCompletion = boundary.completeReset(token: old)
        #expect(!oldCompletion)
        #expect(boundary.resetPending)
        let currentCompletion = boundary.completeReset(token: current)
        #expect(currentCompletion)
    }
}
