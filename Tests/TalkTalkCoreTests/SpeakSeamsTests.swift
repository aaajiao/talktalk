import Testing
@testable import TalkTalkCore

struct SpeakSeamsTests {
    @Test func latencyWindowUsesNearestRankAndEvictsOldSamples() {
        var p95 = RollingP95(capacity: 20)
        #expect(p95.value == nil)
        p95.record(1000)
        #expect(p95.value == 1000)
        for n in 1...19 { p95.record(Double(n)) }
        #expect(p95.value == 19)
        p95.record(20)
        #expect(p95.value == 19)
        p95.record(21)
        #expect(p95.value == 20)
        p95.record(.nan); p95.record(.infinity); p95.record(-1)
        #expect(p95.count == 20)
        #expect(p95.value == 20)
    }

    @Test func sharedJobsStayUniqueAcrossConcurrentConsumers() async {
        let jobs = JobIDSequence()
        let ids = await withTaskGroup(of: JobID.self, returning: [JobID].self) { group in
            for _ in 0..<32 { group.addTask { jobs.next() } }
            var ids: [JobID] = []
            for await id in group { ids.append(id) }
            return ids
        }
        #expect(Set(ids).count == 32)
        #expect(ids.min() == 1 && ids.max() == 32)
    }
}
