import CAudioCore
import Foundation
import Testing

/// Seeded xorshift64 so that a failing random test reproduces.
struct RTRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ oneIn: Int) -> Bool { Int.random(in: 0..<oneIn, using: &self) == 0 }
}

/// ringO: the playout side of tt_ring (clause marks, hold-back, pause, jump, lead limit).
@Suite struct RingOTests {
    private func write(_ r: OpaquePointer, _ value: Float, _ frames: Int, _ flags: UInt32, _ tag: UInt32) -> UInt32 {
        let buf = [Float](repeating: value, count: max(frames, 1))
        return buf.withUnsafeBufferPointer { tt_ring_write_clause(r, $0.baseAddress, UInt32(frames), flags, tag) }
    }

    private func play(_ r: OpaquePointer, _ frames: Int, resume: UInt32 = 3840) -> ([Float], tt_ring_playout_report) {
        var out = [Float](repeating: .nan, count: frames)
        var rep = tt_ring_playout_report()
        let got = out.withUnsafeMutableBufferPointer { tt_ring_playout_read(r, $0.baseAddress!, UInt32(frames), resume, &rep) }
        #expect(got == UInt32(frames))
        return (out, rep)
    }

    static func starts(_ rep: tt_ring_playout_report) -> [(tag: UInt32, offset: UInt32)] {
        let tags = withUnsafeBytes(of: rep.start_tag) { Array($0.bindMemory(to: UInt32.self)) }
        let offsets = withUnsafeBytes(of: rep.start_offset) { Array($0.bindMemory(to: UInt32.self)) }
        return (0..<Int(rep.start_count)).map { (tags[$0], offsets[$0]) }
    }

    private func fadeIn(_ i: Int, _ len: UInt32) -> Float { tt_fade_in_gain(UInt32(i), len) }
    private func fadeOut(_ i: Int, _ len: UInt32) -> Float { tt_fade_out_gain(UInt32(i), len) }

    @Test func fadeShapesAreLinear() {
        #expect(tt_fade_in_gain(0, 240) == 0)
        #expect(tt_fade_in_gain(120, 240) == 0.5)
        #expect(tt_fade_in_gain(240, 240) == 1)
        #expect(tt_fade_out_gain(0, 240) == Float(239) / 240)
        #expect(tt_fade_out_gain(239, 240) == 0)
        #expect(tt_fade_out_gain(240, 240) == 0)
        #expect(tt_fade_in_gain(5, 0) == 1)
        #expect(tt_fade_out_gain(5, 0) == 0)
    }

    @Test func clauseFadesInPlaysAndEndsWithTheHoldBackFade() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        #expect(write(r, 1, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 7) == 1000)
        let (a, ra) = play(r, 480)
        #expect(Self.starts(ra).map(\.tag) == [7])
        #expect(Self.starts(ra).map(\.offset) == [0])
        for i in 0..<240 { #expect(a[i] == fadeIn(i, 240)) }
        #expect(a[240..<480].allSatisfy { $0 == 1 })
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_PLAYING)
        // 480..759 full, 760..999 is the 5 ms hold-back, faded because END has arrived.
        let (b, rb) = play(r, 520)
        #expect(b[0..<280].allSatisfy { $0 == 1 })
        for i in 0..<240 { #expect(b[280 + i] == fadeOut(i, 240)) }
        #expect(rb.events & TT_RING_EV_ENDED != 0)
        #expect(rb.events & TT_RING_EV_UNDERRUN == 0)
        #expect(rb.ring_frames == 520 && rb.audio_frames == 520)
        let (c, rc) = play(r, 480)
        #expect(c.allSatisfy { $0 == 0 })
        #expect(rc.audio_frames == 0)
        #expect(tt_ring_playout_underruns(r) == 0)
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_IDLE)
    }

    @Test func holdBackFadesOutAsUnderrunAndResumesAfterRebuffer() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 1000, TT_RING_CLAUSE_START, 1)   // no END: more audio is expected
        _ = play(r, 480)
        let (b, rb) = play(r, 520)
        #expect(rb.events & TT_RING_EV_UNDERRUN != 0)
        #expect(rb.zero_offset == 520)
        for i in 0..<240 { #expect(b[280 + i] == fadeOut(i, 240)) }
        #expect(tt_ring_playout_underruns(r) == 1)
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_UNDERRUN)
        // Resume needs resume_frames (3840) beyond the 240-frame hold-back.
        _ = write(r, 1, 3000, 0, 0)
        let (_, rc) = play(r, 480)
        #expect(rc.audio_frames == 0)
        _ = write(r, 1, 1100, 0, 0)
        let (d, rd) = play(r, 480)
        #expect(rd.events & TT_RING_EV_RESUMED != 0)
        for i in 0..<240 { #expect(d[i] == fadeIn(i, 240)) }
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_PLAYING)
    }

    @Test func underrunWaitingForRebufferResumesAtOnceWhenTheClauseEnds() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 600, TT_RING_CLAUSE_START, 1)
        _ = play(r, 600)
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_UNDERRUN)
        _ = write(r, 0.5, 300, TT_RING_CLAUSE_END, 0)   // isLast: no rebuffer wait
        let (out, rep) = play(r, 480)
        #expect(rep.events & TT_RING_EV_RESUMED != 0)
        #expect(rep.audio_frames == 300)
        #expect(out[300..<480].allSatisfy { $0 == 0 })
    }

    @Test func pauseParksOnTheNextClauseStartAndResumesThere() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        _ = play(r, 480)
        tt_ring_set_pause(r, true)
        #expect(tt_ring_pause_requested(r))
        var audio: UInt32 = 480
        var parkedEvents = 0
        for _ in 0..<10 {
            let (_, rep) = play(r, 480)
            audio += rep.audio_frames
            if rep.events & TT_RING_EV_PARKED != 0 { parkedEvents += 1 }
        }
        #expect(audio == 2000)           // clause 1 completes, clause 2 is untouched
        #expect(parkedEvents == 1)
        #expect(tt_ring_is_parked(r))
        #expect(tt_ring_available(r) == 2000)   // read index fixed on the START mark
        tt_ring_set_pause(r, false)
        let (b, rb) = play(r, 480)
        #expect(Self.starts(rb).map(\.tag) == [2])
        #expect(Self.starts(rb).map(\.offset) == [0])
        for i in 0..<240 { #expect(b[i] == fadeIn(i, 240)) }
    }

    @Test func pauseBeforeAStartWithoutEndFadesOverTheLastFiveMilliseconds() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START, 1)   // clause 1 not marked ended
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        var all = play(r, 480).0
        tt_ring_set_pause(r, true)
        for _ in 1..<10 { all += play(r, 480).0 }
        for i in 0..<240 { #expect(all[1760 + i] == fadeOut(i, 240)) }
        #expect(all[2000..<4800].allSatisfy { $0 == 0 })
        #expect(tt_ring_is_parked(r))
    }

    @Test func idleRingParksAtOnce() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        tt_ring_set_pause(r, true)
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        let (out, rep) = play(r, 480)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(rep.audio_frames == 0)
        #expect(tt_ring_is_parked(r))
    }

    @Test func flushSupersedesACutAlreadyFadingAndKeepsLaterFrames() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 5000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        _ = write(r, 0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        _ = play(r, 960)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))
        _ = play(r, 480) // first third of the old cut's fade
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_WRITE_INDEX))
        _ = write(r, 0.25, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 3)
        _ = play(r, 480)
        let (_, report) = play(r, 480)
        #expect(report.events & TT_RING_EV_FLUSHED != 0)
        #expect(report.events & TT_RING_EV_CUT == 0)
        #expect(!tt_ring_jump_pending(r))
        #expect(tt_ring_available(r) == 2000)
        let (fresh, _) = play(r, 480)
        #expect(fresh[240...].allSatisfy { $0 == 0.25 })
    }

    @Test func jumpToNextStartCutsWithThirtyMillisecondFade() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 5000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        _ = write(r, 0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        _ = play(r, 960)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))
        #expect(tt_ring_jump_pending(r))
        #expect(!tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))   // one at a time
        var all: [Float] = []
        var cut: tt_ring_playout_report?
        var start2 = -1
        for k in 0..<6 {
            let (out, rep) = play(r, 480)
            all += out
            if rep.events & TT_RING_EV_CUT != 0 { cut = rep }
            for s in Self.starts(rep) where s.tag == 2 { start2 = k * 480 + Int(s.offset) }
        }
        let c = try #require(cut)
        #expect(c.cut_tag == 1)
        #expect(c.cut_dropped == 5000 - 960 - 1440)
        for i in 0..<1440 { #expect(all[i] == fadeOut(i, 1440)) }
        #expect(start2 == 1440)
        for i in 0..<240 { #expect(all[1440 + i] == 0.5 * fadeIn(i, 240)) }
        #expect(!tt_ring_jump_pending(r))
    }

    @Test func jumpWithoutLaterStartGoesToTheRequestWriteIndex() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 5000, TT_RING_CLAUSE_START, 1)
        _ = play(r, 480)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))
        _ = write(r, 0.25, 3000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)   // written after the request: kept
        var start2 = -1
        var sawCut = false
        for k in 0..<8 {
            let (_, rep) = play(r, 480)
            if rep.events & TT_RING_EV_CUT != 0 { sawCut = true }
            for s in Self.starts(rep) where s.tag == 2 { start2 = k * 480 + Int(s.offset) }
        }
        #expect(sawCut)
        #expect(start2 == 1440)
    }

    @Test func flushFadesThenDropsEverythingUpToTheRequest() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 5000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        _ = write(r, 1, 5000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        _ = play(r, 480)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_WRITE_INDEX))
        _ = write(r, 0.25, 3000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 3)
        var all: [Float] = []
        var flushed: tt_ring_playout_report?
        var tags: [UInt32] = []
        var start3 = -1
        for k in 0..<8 {
            let (out, rep) = play(r, 480)
            all += out
            if rep.events & TT_RING_EV_FLUSHED != 0 { flushed = rep }
            for s in Self.starts(rep) {
                tags.append(s.tag)
                if s.tag == 3 { start3 = k * 480 + Int(s.offset) }
            }
        }
        let f = try #require(flushed)
        #expect(f.cut_tag == 1)
        #expect(f.cut_dropped == 10000 - 480 - 1440)
        for i in 0..<1440 { #expect(all[i] == fadeOut(i, 1440)) }
        #expect(tags == [3])   // clause 2 never played
        #expect(start3 == 1440)
    }

    @Test func jumpWhileNotPlayingHasNoFade() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 1000, TT_RING_CLAUSE_START, 1)
        _ = play(r, 1000)   // runs dry mid-clause
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_UNDERRUN)
        _ = write(r, 1, 500, 0, 0)   // rest of clause 1, skipped by the jump
        _ = write(r, 0.5, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))
        let (out, rep) = play(r, 480)
        #expect(rep.events & TT_RING_EV_CUT != 0)
        #expect(rep.cut_dropped == 500)
        #expect(Self.starts(rep).map(\.tag) == [2])
        #expect(Self.starts(rep).map(\.offset) == [0])
        for i in 0..<240 { #expect(out[i] == 0.5 * fadeIn(i, 240)) }
    }

    @Test func jumpAtAClauseStartSkipsNothing() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 100, TT_RING_CLAUSE_START, 1)   // below the hold-back: not started yet
        _ = play(r, 480)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))
        _ = write(r, 1, 900, TT_RING_CLAUSE_END, 0)
        let (_, rep) = play(r, 480)
        #expect(rep.cut_dropped == 0)
        #expect(Self.starts(rep).map(\.tag) == [1])
    }

    @Test func writerNeverLeadsByMoreThanHalfASecond() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        #expect(tt_ring_capacity(r) >= 96000)   // 2 s
        tt_ring_set_max_lead(r, 24000)
        #expect(tt_ring_max_lead(r) == 24000)
        #expect(write(r, 1, 30000, TT_RING_CLAUSE_START, 1) == 24000)
        #expect(tt_ring_lead_room(r) == 0)
        #expect(write(r, 1, 100, 0, 0) == 0)
        #expect(tt_ring_overrun_frames(r) == 0)   // refused by the lead limit, not overrun
        _ = play(r, 480)
        #expect(tt_ring_lead_room(r) == 480)
        tt_ring_set_max_lead(r, 0)
        #expect(tt_ring_max_lead(r) == tt_ring_capacity(r))
    }

    @Test func startAndEndMarksWaitUntilFramesAreStored() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        tt_ring_set_max_lead(r, 1000)
        #expect(write(r, 1, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1) == 1000)
        // Lead room 0: neither mark of clause 2 may be pushed yet.
        #expect(write(r, 0.5, 500, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2) == 0)
        var tags: [UInt32] = []
        for _ in 0..<3 { tags += Self.starts(play(r, 480).1).map(\.tag) }
        #expect(tags == [1])
        #expect(write(r, 0.5, 500, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2) == 500)
        tags = []
        var ended = false
        for _ in 0..<3 {
            let rep = play(r, 480).1
            tags += Self.starts(rep).map(\.tag)
            if rep.events & TT_RING_EV_ENDED != 0 { ended = true }
        }
        #expect(tags == [2])
        #expect(ended)
        #expect(tt_ring_playout_underruns(r) == 0)
    }

    @Test func markQueueOverflowIsRefusedAndCounted() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        var stored = 0
        for t in 0..<Int(TT_RING_MAX_MARKS) { stored += Int(write(r, 1, 1, TT_RING_CLAUSE_START, UInt32(t))) }
        #expect(stored == Int(TT_RING_MAX_MARKS))
        #expect(write(r, 1, 1, TT_RING_CLAUSE_START, 999) == 0)
        #expect(tt_ring_mark_overflows(r) == 1)
    }

    @Test func playoutResetDropsEverything() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 5000, TT_RING_CLAUSE_START, 1)
        _ = play(r, 480)
        tt_ring_set_pause(r, true)
        _ = tt_ring_request_jump(r, TT_RING_JUMP_WRITE_INDEX)
        tt_ring_playout_reset(r)
        #expect(tt_ring_available(r) == 0)
        #expect(!tt_ring_pause_requested(r))
        #expect(!tt_ring_jump_pending(r))
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_IDLE)
        _ = write(r, 0.5, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        #expect(Self.starts(play(r, 480).1).map(\.tag) == [2])
    }

    // MARK: Suspend (the consumer gives its output to ringP)

    /// A cut fade in progress when the consumer suspends completes at once: the jump happens and
    /// is acknowledged, and nothing of the cut clause plays afterwards. With pause requested the
    /// ring parks.
    @Test func suspendCompletesACutInProgress() throws {
        for pause in [false, true] {
            let r = try #require(tt_ring_create(96000))
            defer { tt_ring_destroy(r) }
            _ = write(r, 1, 20000, TT_RING_CLAUSE_START, 1)
            _ = play(r, 960)
            #expect(tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))   // no later START: the write index
            let (a, _) = play(r, 480)   // the first third of the 30 ms cut fade
            for i in 0..<480 { #expect(a[i] == fadeOut(i, 1440)) }
            if pause { tt_ring_set_pause(r, true) }
            var rep = tt_ring_playout_report()
            tt_ring_playout_suspend(r, &rep)
            #expect(rep.events & TT_RING_EV_CUT != 0)
            #expect(rep.cut_tag == 1 && rep.cut_dropped == 20000 - 1440 && rep.cut_offset == 0)
            #expect(!tt_ring_jump_pending(r))
            #expect(tt_ring_available(r) == 0)
            #expect(tt_ring_is_parked(r) == pause)
            #expect((rep.events & TT_RING_EV_PARKED != 0) == pause)
            if !pause { #expect(tt_ring_playout_state(r) == TT_RING_STATE_IDLE) }
            let (b, rb) = play(r, 480)
            #expect(b.allSatisfy { $0 == 0 } && rb.audio_frames == 0)
            tt_ring_set_pause(r, false)
            _ = write(r, 0.5, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
            let (c, rc) = play(r, 480)
            #expect(Self.starts(rc).map(\.tag) == [2])
            for i in 0..<240 { #expect(c[i] == 0.5 * fadeIn(i, 240)) }
        }
    }

    @Test func suspendCompletesAPauseFadeAndTheRingStaysParkedUntilUnpaused() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START, 1)
        _ = write(r, 0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        _ = play(r, 480)
        tt_ring_set_pause(r, true)
        let (a, _) = play(r, 1400)   // full gain to 1760, then 120 frames into the fade before clause 2
        for i in 0..<120 { #expect(a[1280 + i] == fadeOut(i, 240)) }
        var rep = tt_ring_playout_report()
        tt_ring_playout_suspend(r, &rep)
        #expect(rep.events == TT_RING_EV_PARKED && rep.parked_offset == 0)
        #expect(rep.ring_frames == 120)
        #expect(tt_ring_is_parked(r))
        #expect(tt_ring_available(r) == 2000)   // on clause 2's START
        tt_ring_playout_suspend(r, &rep)   // still paused: still parked, nothing new to report
        #expect(rep.events == 0 && tt_ring_is_parked(r))
        tt_ring_set_pause(r, false)
        tt_ring_playout_suspend(r, &rep)
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_IDLE)
        let (b, rb) = play(r, 480)
        #expect(Self.starts(rb).map(\.tag) == [2])
        for i in 0..<240 { #expect(b[i] == 0.5 * fadeIn(i, 240)) }
    }

    @Test func suspendCompletesAnEndOrUnderrunFade() throws {
        for ended in [true, false] {
            let r = try #require(tt_ring_create(96000))
            defer { tt_ring_destroy(r) }
            _ = write(r, 1, 1000, TT_RING_CLAUSE_START | (ended ? TT_RING_CLAUSE_END : 0), 1)
            _ = play(r, 900)   // 140 frames into the hold-back fade
            var rep = tt_ring_playout_report()
            tt_ring_playout_suspend(r, &rep)
            #expect(rep.events == (ended ? TT_RING_EV_ENDED : TT_RING_EV_UNDERRUN))
            #expect(rep.ring_frames == 100 && tt_ring_available(r) == 0)
            #expect(tt_ring_playout_state(r) == (ended ? TT_RING_STATE_IDLE : TT_RING_STATE_UNDERRUN))
            #expect(tt_ring_playout_underruns(r) == (ended ? 0 : 1))
            let (out, _) = play(r, 480)
            #expect(out.allSatisfy { $0 == 0 })
        }
    }

    /// A suspend inside a hold-back fade that holds the next clause's START stops on that START:
    /// clause 1 ended (no underrun), and clause 2 plays from its first frame with its first
    /// sample reported. Skipping to the fade's end used to drop clause 2's START and first
    /// frames (no out.first_sample, current tag left on clause 1). Review 2026-11-05.
    @Test func suspendInAHoldBackFadeStopsOnTheNextClauseStart() throws {
        for clause2Ends in [false, true] {
            for pause in [false, true] {
                let note: Comment = "clause 2 ends \(clause2Ends), pause \(pause)"
                let r = try #require(tt_ring_create(96000))
                defer { tt_ring_destroy(r) }
                _ = write(r, 1, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
                _ = write(r, 0.5, 100, TT_RING_CLAUSE_START | (clause2Ends ? TT_RING_CLAUSE_END : 0), 2)
                let (_, r0) = play(r, 960)   // the hold-back fade runs 860..<1100, START at 1000
                #expect(Self.starts(r0).map(\.tag) == [1], note)
                if pause { tt_ring_set_pause(r, true) }
                var rep = tt_ring_playout_report()
                tt_ring_playout_suspend(r, &rep)
                #expect(rep.events == TT_RING_EV_ENDED | (pause ? TT_RING_EV_PARKED : 0), note)
                #expect(rep.ring_frames == 40 && tt_ring_available(r) == 100, note)
                #expect(tt_ring_playout_state(r) == (pause ? TT_RING_STATE_PARKED : TT_RING_STATE_IDLE), note)
                #expect(tt_ring_playout_underruns(r) == 0, note)
                if pause { tt_ring_set_pause(r, false) }
                if !clause2Ends { _ = write(r, 0.5, 2000, TT_RING_CLAUSE_END, 2) }
                let (out, r1) = play(r, 480)
                #expect(Self.starts(r1).map(\.tag) == [2] && Self.starts(r1).map(\.offset) == [0], note)
                if clause2Ends {   // 100 frames: fade-in and the END fade together
                    #expect(r1.events == TT_RING_EV_ENDED && r1.ring_frames == 100, note)
                    for i in 0..<100 { #expect(out[i] == 0.5 * (fadeIn(i, 240) * fadeOut(i, 100)), note) }
                } else {
                    #expect(r1.events == 0 && r1.ring_frames == 480, note)
                    for i in 0..<240 { #expect(out[i] == 0.5 * fadeIn(i, 240), note) }
                    #expect(out[240...].allSatisfy { $0 == 0.5 }, note)
                }
                #expect(tt_ring_playout_underruns(r) == 0, note)
            }
        }
    }

    @Test func aJumpRequestedWhileSuspendedHappensAtOnceWithoutAFade() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 5000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        _ = write(r, 0.5, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        _ = play(r, 960)
        var rep = tt_ring_playout_report()
        tt_ring_playout_suspend(r, &rep)   // ringP took over
        #expect(rep.events == 0 && tt_ring_playout_state(r) == TT_RING_STATE_PLAYING)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))
        tt_ring_playout_suspend(r, &rep)
        #expect(rep.events == TT_RING_EV_CUT)
        #expect(rep.cut_tag == 1 && rep.cut_dropped == 5000 - 960 && rep.ring_frames == 0)
        #expect(!tt_ring_jump_pending(r))
        #expect(tt_ring_playout_state(r) == TT_RING_STATE_IDLE)
        let (out, rb) = play(r, 480)
        #expect(Self.starts(rb).map(\.tag) == [2])
        #expect(Self.starts(rb).map(\.offset) == [0])
        for i in 0..<240 { #expect(out[i] == 0.5 * fadeIn(i, 240)) }
    }

    // MARK: Jumps: underrun, parked, same-call hand-over, flushed marks

    /// A jump after the ring ran dry inside a clause drops that clause although the read index
    /// does not move: the reader is idle again, so a pause parks it and the next clause starts
    /// without the rebuffer threshold.
    @Test func jumpOutOfAnUnderrunLeavesTheReaderIdle() throws {
        for kind in [TT_RING_JUMP_NEXT_START, TT_RING_JUMP_WRITE_INDEX] {
            let r = try #require(tt_ring_create(96000))
            defer { tt_ring_destroy(r) }
            _ = write(r, 1, 1000, TT_RING_CLAUSE_START, 1)   // no END
            _ = play(r, 2000)
            #expect(tt_ring_playout_state(r) == TT_RING_STATE_UNDERRUN && tt_ring_available(r) == 0)
            #expect(tt_ring_request_jump(r, kind))
            tt_ring_set_pause(r, true)
            let (_, rep) = play(r, 480)
            #expect(rep.cut_dropped == 0)
            #expect(rep.events & (kind == TT_RING_JUMP_NEXT_START ? TT_RING_EV_CUT : TT_RING_EV_FLUSHED) != 0)
            #expect(rep.events & TT_RING_EV_PARKED != 0)
            #expect(tt_ring_is_parked(r), "kind \(kind)")

            // Without pause: a clause longer than the hold-back starts at once (300 frames, far
            // below hold-back + rebuffer threshold), END or not.
            let q = try #require(tt_ring_create(96000))
            defer { tt_ring_destroy(q) }
            _ = write(q, 1, 1000, TT_RING_CLAUSE_START, 1)
            _ = play(q, 2000)
            #expect(tt_ring_request_jump(q, kind))
            _ = play(q, 480)
            #expect(tt_ring_playout_state(q) == TT_RING_STATE_IDLE, "kind \(kind)")
            _ = write(q, 0.5, 300, TT_RING_CLAUSE_START, 2)
            let (out, rq) = play(q, 480)
            #expect(Self.starts(rq).map(\.tag) == [2])
            #expect(rq.audio_frames == 300)
            for i in 0..<60 { #expect(out[i] == 0.5 * fadeIn(i, 240)) }
        }
    }

    @Test func aFlushWhileParkedKeepsTheRingParked() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 1)
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        _ = play(r, 480)
        tt_ring_set_pause(r, true)
        for _ in 0..<5 { _ = play(r, 480) }
        #expect(tt_ring_is_parked(r) && tt_ring_available(r) == 2000)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_WRITE_INDEX))
        let (out, rep) = play(r, 480)
        #expect(rep.events & TT_RING_EV_FLUSHED != 0 && rep.cut_dropped == 2000)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(tt_ring_is_parked(r) && tt_ring_available(r) == 0)
        _ = write(r, 0.5, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 3)
        #expect(play(r, 480).1.audio_frames == 0)   // still paused
        tt_ring_set_pause(r, false)
        #expect(Self.starts(play(r, 480).1).map(\.tag) == [3])
    }

    /// A cut that completes inside a call hands over to the next clause in the same call at the
    /// exact offsets, and the jump counts as acknowledged: the next request is a new cut with
    /// its own fade.
    @Test func cutCompletingMidCallStartsTheNextClauseInTheSameCall() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 3000, TT_RING_CLAUSE_START, 1)
        _ = write(r, 0.5, 3000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)
        _ = play(r, 480)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_NEXT_START))
        let (a, ra) = play(r, 2400)
        #expect(ra.events == TT_RING_EV_CUT)
        #expect(ra.cut_offset == 1440 && ra.cut_tag == 1 && ra.cut_dropped == 3000 - 480 - 1440)
        #expect(Self.starts(ra).map(\.tag) == [2] && Self.starts(ra).map(\.offset) == [1440])
        #expect(ra.ring_frames == 2400 && ra.audio_frames == 2400)
        for i in 0..<1440 { #expect(a[i] == fadeOut(i, 1440)) }
        for i in 0..<240 { #expect(a[1440 + i] == 0.5 * fadeIn(i, 240)) }
        #expect(a[1680..<2400].allSatisfy { $0 == 0.5 })
        #expect(!tt_ring_jump_pending(r))

        #expect(tt_ring_request_jump(r, TT_RING_JUMP_WRITE_INDEX))
        let (b, rb) = play(r, 480)
        #expect(rb.events == 0)
        for i in 0..<480 { #expect(b[i] == 0.5 * fadeOut(i, 1440)) }
        _ = play(r, 480)
        let (_, rd) = play(r, 480)
        #expect(rd.events == TT_RING_EV_FLUSHED)
        #expect(rd.cut_offset == 480 && rd.cut_tag == 2 && rd.cut_dropped == 6000 - 5400)
    }

    /// A flush drops the marks pushed before the request, including a START exactly at the
    /// request's write index (a clause with no frames yet): only clauses written after the flush
    /// are reported.
    @Test func flushDropsAStartAtTheRequestWriteIndex() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 2000, TT_RING_CLAUSE_START, 1)
        _ = play(r, 480)
        #expect(write(r, 0, 0, TT_RING_CLAUSE_START, 2) == 0)   // START mark at 2000, no frames yet
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_WRITE_INDEX))
        let (_, ra) = play(r, 2000)
        var tags = Self.starts(ra).map(\.tag)
        #expect(ra.events & TT_RING_EV_FLUSHED != 0 && ra.cut_dropped == 2000 - 480 - 1440)
        _ = write(r, 0.5, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 3)
        for _ in 0..<4 { tags += Self.starts(play(r, 480).1).map(\.tag) }
        #expect(tags == [3])
    }

    /// A flush whose 30 ms fade runs over two reads and passes the next clause's START still
    /// reports the clause it cut. The read used to keep the acknowledgement it loaded at its
    /// start, so after the fade completed it took the same request again (target = read index,
    /// no second jump) and reported the tag of the last START the fade had passed (found by
    /// speak-playout porting the read loop; fixed by 43ff2b5).
    @Test func aFlushFadeOverTwoReadsReportsTheClauseItCut() throws {
        let r = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(r) }
        _ = write(r, 1, 1000, TT_RING_CLAUSE_START, 1)
        _ = write(r, 0.5, 3000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 2)   // START at 1000
        _ = play(r, 480)
        #expect(tt_ring_request_jump(r, TT_RING_JUMP_WRITE_INDEX))   // target 4000
        let (a, ra) = play(r, 480)
        #expect(ra.events == 0 && tt_ring_jump_pending(r))
        for i in 0..<480 { #expect(a[i] == fadeOut(i, 1440)) }
        let (b, rb) = play(r, 1440)   // the fade passes clause 2's START at ring frame 1000
        for i in 0..<960 { #expect(b[i] == (960 + i < 1000 ? 1 : 0.5) * fadeOut(480 + i, 1440), "\(i)") }
        #expect(b[960...].allSatisfy { $0 == 0 })
        #expect(rb.events == TT_RING_EV_FLUSHED)
        #expect(rb.cut_tag == 1 && rb.cut_offset == 960 && rb.cut_dropped == 4000 - 1920)
        #expect(rb.start_count == 0)   // clause 2 was flushed, its START only faded past
        #expect(!tt_ring_jump_pending(r))
        _ = write(r, 0.25, 1000, TT_RING_CLAUSE_START | TT_RING_CLAUSE_END, 3)
        let (_, rc) = play(r, 480)
        #expect(rc.events == 0 && Self.starts(rc).map(\.tag) == [3])
    }

    /// SPSC stress through the playout path: 10^7 frames in random clauses and random block
    /// sizes on a producer thread, random read sizes on the consumer. Frame k carries the value
    /// k + 1, so the consumer can check every frame it gets: nothing dropped (all frames are
    /// consumed), nothing duplicated or reordered (audio frame i of a read is ring frame
    /// base + i, at full gain except inside a fade), every clause start reported once, at its
    /// exact position, and no overrun.
    @Test func spscStressThroughPlayoutKeepsEveryFrame() throws {
        let ring = try #require(tt_ring_create(96000))
        defer { tt_ring_destroy(ring) }
        tt_ring_set_max_lead(ring, 24000)
        let total = 10_000_000
        var rng = RTRandom(seed: 42)
        var lengths: [Int] = []
        var starts: [Int] = []
        var sum = 0
        // Clauses are longer than any read (and the last one too), so no read holds a whole clause.
        while sum < total {
            var l = min(rng.int(1100...30000), total - sum)
            if total - sum - l < 1100 { l = total - sum }
            starts.append(sum)
            lengths.append(l)
            sum += l
        }
        nonisolated(unsafe) let r = ring
        let clauseLengths = lengths
        let producerDone = ManagedAtomicFlag()
        let producer = Thread {
            var prng = RTRandom(seed: 7)
            var buf = [Float](repeating: 0, count: 2000)
            var pos = 0
            for (c, len) in clauseLengths.enumerated() {
                var remaining = len
                var first = true
                while remaining > 0 {
                    let chunk = min(prng.int(1...2000), remaining)
                    for i in 0..<chunk { buf[i] = Float(pos + i + 1) }
                    let flags = (first ? TT_RING_CLAUSE_START : 0) | (chunk == remaining ? TT_RING_CLAUSE_END : 0)
                    let n = Int(buf.withUnsafeBufferPointer { tt_ring_write_clause(r, $0.baseAddress, UInt32(chunk), flags, UInt32(c + 1)) })
                    if n > 0 { first = false }
                    remaining -= n
                    pos += n
                    if n < chunk { usleep(20) }
                }
            }
            producerDone.set()
        }
        producer.start()

        var out = [Float](repeating: 0, count: 1024)
        var base = 0
        var nonExact = 0
        var bad = 0
        var badStarts = 0
        var nextTag: UInt32 = 1
        var resumedEvents = 0
        var endedEvents = 0
        var underrunEvents = 0
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let n = rng.int(1...1024)
            var rep = tt_ring_playout_report()
            // 80 ms rebuffer threshold (feedIOProc's minimum), longer than any read.
            _ = out.withUnsafeMutableBufferPointer { tt_ring_playout_read(r, $0.baseAddress!, UInt32(n), 3840, &rep) }
            if rep.ring_frames != rep.audio_frames { bad += 1 }
            if rep.events & TT_RING_EV_RESUMED != 0 { resumedEvents += 1 }
            if rep.events & TT_RING_EV_ENDED != 0 { endedEvents += 1 }
            if rep.events & TT_RING_EV_UNDERRUN != 0 { underrunEvents += 1 }
            out.withUnsafeBufferPointer { o in
                for i in 0..<Int(rep.audio_frames) {
                    let e = Float(base + i + 1)
                    if o[i] != e {
                        nonExact += 1
                        if !(o[i] >= 0 && o[i] <= e) { bad += 1 }
                    }
                }
                for i in Int(rep.audio_frames)..<n where o[i] != 0 { bad += 1 }
            }
            for s in Self.starts(rep) {
                if s.tag != nextTag || base + Int(s.offset) != starts[Int(nextTag) - 1] { badStarts += 1 }
                nextTag += 1
            }
            base += Int(rep.ring_frames)
            if producerDone.isSet && base >= total { break }
        }
        #expect(base == total)
        #expect(bad == 0)
        #expect(badStarts == 0)
        #expect(Int(nextTag) - 1 == lengths.count)
        // An event that happens twice in one call is reported once. Here none can: a second END
        // would need a whole clause in one read, a second underrun a rebuffer within one read. So
        // the report bits count the events.
        #expect(underrunEvents == Int(tt_ring_playout_underruns(r)))
        // Only fades are below full gain, 5 ms each: a fade-in at the first start, after every
        // resume and after every end (the next clause starts from idle), a fade-out before every
        // end and every underrun.
        #expect(nonExact <= 240 * (1 + resumedEvents + 2 * endedEvents + underrunEvents),
                "nonExact \(nonExact), resumed \(resumedEvents), ended \(endedEvents), underruns \(underrunEvents)")
        #expect(tt_ring_overrun_frames(r) == 0)
        #expect(tt_ring_mark_overflows(r) == 0)
    }

    /// The plain SPSC data path at 10^7 frames with random block sizes on both sides.
    @Test func plainSpscStressTenMillionFrames() throws {
        let ring = try #require(tt_ring_create(8192))
        defer { tt_ring_destroy(ring) }
        let total = 10_000_000
        nonisolated(unsafe) let r = ring
        let producer = Thread {
            var prng = RTRandom(seed: 99)
            var buf = [Float](repeating: 0, count: 4096)
            var next = 0
            while next < total {
                let n = min(prng.int(1...4096), total - next)
                for i in 0..<n { buf[i] = Float(next + i + 1) }
                var written = 0
                while written < n {
                    let room = Int(tt_ring_capacity(r)) - Int(tt_ring_available(r))
                    let m = min(n - written, room)
                    if m == 0 { usleep(10); continue }
                    written += Int(buf.withUnsafeBufferPointer { tt_ring_write_strided(r, $0.baseAddress! + written, UInt32(m), 1) })
                }
                next += n
            }
        }
        producer.start()
        var rng = RTRandom(seed: 5)
        var expected = 0
        var ok = true
        var buf = [Float](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(120)
        while expected < total && Date() < deadline {
            let want = rng.int(1...4096)
            let n = Int(buf.withUnsafeMutableBufferPointer { tt_ring_read(r, $0.baseAddress!, UInt32(want)) })
            buf.withUnsafeBufferPointer { b in
                for i in 0..<n where b[i] != Float(expected + i + 1) { ok = false }
            }
            expected += n
        }
        #expect(ok)
        #expect(expected == total)
        #expect(tt_ring_overrun_frames(r) == 0)
    }
}

/// A set-once flag readable from another thread.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
