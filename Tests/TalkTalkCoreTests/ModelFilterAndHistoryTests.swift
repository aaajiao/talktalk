import Testing
@testable import TalkTalkCore

@Suite struct ModelFilterTests {
    typealias L = ModelFilter.Listed

    /// The five GPT-6+ ids measured on 2026-11-04 (O14) plus older and non-text ids.
    var listed: [L] {
        [L(id: "gpt-6-astra", created: 1_780_000_000), L(id: "gpt-6-luna", created: 1_781_000_000),
         L(id: "gpt-6-sol", created: 1_779_000_000), L(id: "gpt-6.1-sol", created: 1_790_000_000),
         L(id: "gpt-6.1-terra", created: 1_791_000_000), L(id: "gpt-5.5", created: 1), L(id: "gpt-5-mini", created: 1),
         L(id: "gpt-4o", created: 1), L(id: "gpt-6-realtime", created: 2), L(id: "gpt-6-tts", created: 2),
         L(id: "gpt-6.1-transcribe", created: 2), L(id: "o3", created: 1), L(id: "text-embedding-3-large", created: 1),
         L(id: "gpt-7-luna-mini", created: 3)]
    }

    @Test func measuredIdsAllSurviveInOrder() {
        let p = ModelFilter.picker(listed, current: "gpt-6-luna")
        #expect(p.models.map(\.id) == ["gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-luna", "gpt-6-astra", "gpt-6-sol"])
        #expect(p.models.first { $0.isDefault }?.id == "gpt-6-luna")
        #expect(p.snapshots.isEmpty)
    }

    @Test func specialisedTextTiersStayVisible() {
        let more = listed + [L(id: "gpt-6-codex", created: 5), L(id: "gpt-6-pro", created: 5), L(id: "gpt-6-chat", created: 5),
                             L(id: "gpt-6-search", created: 5), L(id: "gpt-6-image", created: 5)]
        let ids = ModelFilter.picker(more, current: nil).models.map(\.id)
        #expect(ids.contains("gpt-6-codex") && ids.contains("gpt-6-pro") && ids.contains("gpt-6-chat"))
        #expect(!ids.contains("gpt-6-search") && !ids.contains("gpt-6-image"))
        #expect(!ids.contains("gpt-7-luna-mini"))     // known limitation: one-word tier only
    }

    @Test func snapshotsRetirementAndSorting() {
        let rows = [L(id: "gpt-6-luna", created: 10), L(id: "gpt-6-luna-2026-09-01", created: 9),
                    L(id: "gpt-6-sol", created: 10, shutdown_date: "2027-01-15"), L(id: "gpt-6-astra", created: 10),
                    L(id: "gpt-7-nova", created: 1)]
        let p = ModelFilter.picker(rows, current: "gpt-6-sol")
        #expect(p.models.map(\.id) == ["gpt-7-nova", "gpt-6-astra", "gpt-6-luna", "gpt-6-sol"])
        #expect(p.models.last?.retiring == true)
        #expect(p.snapshots.map(\.id) == ["gpt-6-luna-2026-09-01"])
        #expect(!ModelFilter.picker(rows, current: "gpt-6-luna").models.contains { $0.id == "gpt-6-sol" })
    }

    @Test func parseAndKnownTable() {
        #expect(ModelFilter.parse("gpt-6.1-terra") == .init(major: 6, minor: 1, tier: "terra", date: nil))
        #expect(ModelFilter.parse("gpt-6") == nil)
        #expect(ModelFilter.known["gpt-6-astra"]?.supportsEffortNone == false)
        #expect(ModelFilter.known["gpt-6-luna"]?.supportsEffortNone == true)
    }

    @Test func retirementFallback() {
        #expect(ModelFilter.resolve(selection: "gpt-6-sol", listed: listed) == .keep("gpt-6-sol"))
        #expect(ModelFilter.resolve(selection: "gpt-6-nova", listed: listed) == .fellBackToDefault(from: "gpt-6-nova"))
        #expect(ModelFilter.resolve(selection: "gpt-6-sol", listed: listed, got404: true) == .fellBackToDefault(from: "gpt-6-sol"))
        #expect(ModelFilter.resolve(selection: "gpt-6-luna", listed: [L(id: "gpt-6-luna", created: 1, shutdown_date: "2027-03-01")]) == .defaultRetiring)
    }
}

@Suite struct MTHistoryTests {
    @Test func pendingClauseIsContextForTheNext() {
        var h = MTHistory()
        let c1 = h.submit(1, session: .speakZhDe, source: "s1")
        h.receive(1, session: .speakZhDe, target: "t1")
        let c2 = h.submit(2, session: .speakZhDe, source: "s2")
        let ev = h.drainEvents()
        #expect(c1.isEmpty)
        #expect(c2 == [MTTurn(source: "s1", target: "t1")])
        #expect(ev.isEmpty)
    }

    @Test func inFlightClauseIsAGapAndNobodyWaits() {
        var h = MTHistory()
        _ = h.submit(1, session: .speakZhEn, source: "s1")
        h.receive(1, session: .speakZhEn, target: "t1")
        h.markSpoken(1, session: .speakZhEn)
        _ = h.submit(2, session: .speakZhEn, source: "s2")
        let ctx3 = h.submit(3, session: .speakZhEn, source: "s3")
        #expect(ctx3 == [MTTurn(source: "s1", target: "t1")])
        let ev = h.drainEvents()
        #expect(ev == [.ctxGap(job: 3, missing: [2])])
    }

    @Test func droppingClauseNRetranslatesNPlusOneWithHistoryToNMinusOne() {
        var h = MTHistory()
        for j in 1...4 as ClosedRange<JobID> {
            _ = h.submit(j, session: .speakZhDe, source: "s\(j)")
            h.receive(j, session: .speakZhDe, target: "t\(j)")
        }
        h.markSpoken(1, session: .speakZhDe)
        // Clause 3 is near synthesis (< 2 s): kept with stale context. Clause 4 is far: retranslated.
        let lead: [JobID: Int] = [3: 1500, 4: 5000]
        let redo = h.rollback(from: 2, session: .speakZhDe) { lead[$0] }
        #expect(redo.map(\.job) == [4])
        #expect(redo.first?.history == [MTTurn(source: "s1", target: "t1"), MTTurn(source: "s3", target: "t3")])
        let ev = h.drainEvents()
        #expect(ev == [.ctxStale(job: 3)])

        var g = MTHistory()
        for j in 1...3 as ClosedRange<JobID> {
            _ = g.submit(j, session: .speakZhDe, source: "s\(j)")
            g.receive(j, session: .speakZhDe, target: "t\(j)")
        }
        let r = g.rollback(from: 2, session: .speakZhDe) { _ in 9000 }
        #expect(r == [MTHistory.Retranslation(job: 3, source: "s3", history: [MTTurn(source: "s1", target: "t1")])])
    }

    @Test func clausesWithAudioAlwaysPlay() {
        var h = MTHistory()
        for j in 1...3 as ClosedRange<JobID> {
            _ = h.submit(j, session: .speakZhEn, source: "s\(j)")
            h.receive(j, session: .speakZhEn, target: "t\(j)")
        }
        h.markSynthesisStarted(3, session: .speakZhEn)
        let redo = h.rollback(from: 2, session: .speakZhEn) { _ in 9000 }
        #expect(redo.isEmpty)
        h.markSpoken(1, session: .speakZhEn); h.markSpoken(3, session: .speakZhEn)
        #expect(h.spoken(.speakZhEn) == [MTTurn(source: "s1", target: "t1"), MTTurn(source: "s3", target: "t3")])
    }

    @Test func onlyTheWinningLegIsRecorded() {
        var h = MTHistory()
        _ = h.submit(1, session: .listenEnZh, source: "s")
        let first = h.receive(1, session: .listenEnZh, target: "winner")
        let second = h.receive(1, session: .listenEnZh, target: "loser")
        let ctx = h.submit(2, session: .listenEnZh, source: "s2")
        #expect(first && !second)
        #expect(ctx == [MTTurn(source: "s", target: "winner")])
    }

    @Test func summarizeAndHardInterrupt() {
        var h = MTHistory()
        for j in 1...4 as ClosedRange<JobID> {
            _ = h.submit(j, session: .speakZhDe, source: "s\(j)")
            h.receive(j, session: .speakZhDe, target: "t\(j)")
        }
        h.markSpoken(1, session: .speakZhDe)
        let ctx = h.merge([2, 3], into: 9, session: .speakZhDe, source: "s2 s3")
        #expect(ctx == [MTTurn(source: "s1", target: "t1")])
        #expect(h.entries[.speakZhDe]?.map(\.job) == [1, 9, 4])
        h.cancelAll(session: .speakZhDe)
        #expect(h.entries[.speakZhDe]?.map(\.job) == [1])
    }

    @Test func directionsAreIndependent() {
        var h = MTHistory()
        _ = h.submit(1, session: .speakZhEn, source: "a")
        h.receive(1, session: .speakZhEn, target: "b")
        let ctx = h.submit(2, session: .listenEnZh, source: "c")
        #expect(ctx.isEmpty)
    }
}
