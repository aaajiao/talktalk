import CAudioCore
import Foundation
@testable import TalkTalkAudio
import TalkTalkCore

/// Swift model of the tt_ring Playout contract (CAudioCore tt_ring.h / tt_ring.c) with a consumer
/// that is a line-by-line port of tt_ring_playout_read and tt_ring_playout_suspend, plus the out.*
/// events feedIOProc derives from a report (tt_ioproc_feed.c handle_o_report: sorted by output
/// frame, each at its own frame). `consume(_:at:)` is one read call, `suspend(at:)` one cycle in
/// which the feed plays something else; FakeVsCRingTests runs the same scripts against the C ring
/// and compares sample by sample and event by event.
/// What it models:
/// - capacity rounded up to a power of two (≥ 1024); lead limit; never overwrites; at most 256
///   unretired marks (a write that would overflow stores nothing);
/// - START / END marks (START only when something is stored or frames == 0, END only when all
///   frames were stored);
/// - the 5 ms hold-back before the write index, played only as a fade-out segment (END there:
///   then idle; otherwise: then underrun); START marks inside any segment but a cut's are
///   reported and passed like any other (review E); resume after `resumeFrames` beyond the
///   hold-back (capped at lead − hold) or once the END has arrived; every start from silence
///   fades in over 5 ms;
/// - pause: a START in [read, write] with pause requested wins over the hold-back fade: fade out
///   over the 5 ms before it and park on it; an idle ring parks at once;
/// - jump: taken by the reader at its next read, behind a running fade segment; while playing a
///   30 ms fade (shorter when the target or the write index is closer), then read = next START
///   at or after read (bounded by the request's write index) or the request's write index.
///   `jumpPending` from the request until the reader has made the jump (request_jump refuses
///   meanwhile): at most the fade plus one read while the feed reads the ring, at once on the
///   next suspend while it does not. A jump that drops the clause in progress (it moved, or the
///   ring had run dry inside the clause) leaves the reader idle; a parked reader stays parked. A
///   write-index jump (flush) also drops the marks pushed before the request;
/// - suspend: a fade segment in progress completes at once (a cut makes its jump; a hold-back
///   fade that holds the next clause's START stops on it, the clause before ended), a pending
///   jump is made at once without a fade, an idle ring with pause requested parks, a parked one
///   without unparks, and a playing one fades in when it is read again;
/// - events: each kind at most once per call, at the output frame of its first occurrence.
final class FakePlayoutRing: PlayoutRing {
    // The C ring's constants (tt_ring.h), not copies.
    static let hold = Int(TT_RING_HOLD_FRAMES), fadeIn = Int(TT_RING_FADE_IN_FRAMES)
    static let cutFade = Int(TT_RING_CUT_FADE_FRAMES), maxMarks = Int(TT_RING_MAX_MARKS)
    static let maxReportStarts = Int(TT_RING_REPORT_MAX_STARTS)

    let capacityFrames: Int
    let maxLead: Int
    var resumeFrames: Int

    enum State { case idle, playing, underrun, parked }
    private(set) var state: State = .idle

    private struct Mark { var pos: Int; var tag: UInt32; var isStart: Bool }
    private enum SegKind { case end, underrun, pause, cut }
    private struct Seg { var kind: SegKind; var start: Int; var end: Int; var len: Int }
    /// `marksAt`: mark_write at the request (marks are counted from the first one ever pushed).
    private struct JumpRequest { var kind: PlayoutJump; var writeAt: Int; var marksAt: Int }

    private var data: [Float] = []            // every frame ever written (tests are short)
    private var read = 0
    private var marks: [Mark] = []            // pushed and not yet retired by the reader
    private var markBase = 0                  // absolute index of marks[0] (mark_read)
    private var markWrite: Int { markBase + marks.count }
    private var pauseRequested = false
    private var request: JumpRequest?         // jump_req_seq != jump_ack_seq
    // reader state (tt_ring_reader)
    private var fadeInPos = 0, fadeInLen = 0
    private var seg: Seg?
    private var jumpTarget = 0
    private var jumpKind: PlayoutJump = .writeIndex
    private var jumpMarks = 0
    private var cutTag: UInt32 = 0
    private var readerTag: UInt32 = 0         // current_tag: tag of the last START played
    private(set) var underruns: UInt64 = 0
    private(set) var markOverflows: UInt64 = 0
    private var events: [PlayoutRingEvent] = []

    // test observations
    private(set) var refusedFrames = 0        // lead-limited (the caller retries), never overwritten
    private(set) var maxAvailable = 0
    private(set) var emptyStartMarks = 0      // START marks written with no frames (review C)
    private(set) var output: [Float] = []     // everything the consumer produced
    private(set) var currentTag: UInt32?      // from the events: first sample → tag, cut/flush/end → nil

    init(capacityFrames: Int = 96_000, maxLeadFrames: Int = 24_000, resumeFrames: Int = 3840) {
        var c = 1024
        while c < capacityFrames { c *= 2 }
        self.capacityFrames = c
        maxLead = maxLeadFrames == 0 || maxLeadFrames > c ? c : maxLeadFrames
        self.resumeFrames = resumeFrames
    }

    // MARK: producer

    var availableFrames: Int { data.count - read }
    var writtenFrames: UInt64 { UInt64(data.count) }
    var leadRoom: Int { max(0, maxLead - availableFrames) }
    var isParked: Bool { state == .parked }
    var jumpPending: Bool { request != nil }
    var playoutState: PlayoutState {
        switch state { case .idle: .idle; case .playing: .playing; case .underrun: .underrun; case .parked: .parked }
    }

    func writeClause(_ src: UnsafeBufferPointer<Float>?, frames: Int, marks flags: PlayoutMarks, tag: UInt32) -> Int {
        let n = min(frames, leadRoom)
        let pushStart = flags.contains(.start) && (n > 0 || frames == 0)
        let pushEnd = flags.contains(.end) && n == frames
        if pushStart || pushEnd {
            guard marks.count + (pushStart ? 1 : 0) + (pushEnd ? 1 : 0) <= Self.maxMarks else {
                markOverflows += 1
                refusedFrames += frames
                return 0
            }
            if pushStart {
                marks.append(Mark(pos: data.count, tag: tag, isStart: true))
                if frames == 0 { emptyStartMarks += 1 }
            }
            if pushEnd { marks.append(Mark(pos: data.count + n, tag: tag, isStart: false)) }
        }
        refusedFrames += frames - n
        if let src { data.append(contentsOf: src.prefix(n)) } else { data.append(contentsOf: repeatElement(0, count: n)) }
        maxAvailable = max(maxAvailable, availableFrames)
        return n
    }

    func setPause(_ paused: Bool) { pauseRequested = paused }

    @discardableResult
    func requestJump(_ kind: PlayoutJump) -> Bool {
        guard request == nil || kind == .writeIndex else { return false }
        request = JumpRequest(kind: kind, writeAt: data.count, marksAt: markWrite)
        if kind == .writeIndex, seg?.kind == .cut {
            jumpTarget = data.count; jumpKind = kind; jumpMarks = markWrite
        }
        return true
    }

    func reset() {
        read = data.count
        markBase = markWrite
        marks.removeAll()
        request = nil; pauseRequested = false
        state = .idle; fadeInPos = 0; fadeInLen = 0; seg = nil; readerTag = 0; cutTag = 0
        currentTag = nil
    }

    func drainEvents() -> [PlayoutRingEvent] { defer { events.removeAll() }; return events }

    // MARK: consumer (tt_ring_playout_read)

    private struct Report {
        var cut = false, flushed = false, parked = false, ended = false, underrun = false, resumed = false
        var zeroOffset = 0, resumedOffset = 0, endedOffset = 0, parkedOffset = 0, cutOffset = 0
        var cutTag: UInt32 = 0, cutDropped = 0
        var starts: [(tag: UInt32, offset: Int)] = []

        /// rep_event: each kind once per call, at the offset of its first occurrence.
        mutating func cut(at o: Int) { if !cut && !flushed { cutOffset = o }; cut = true }
        mutating func flushed(at o: Int) { if !cut && !flushed { cutOffset = o }; flushed = true }
        mutating func parked(at o: Int) { if !parked { parkedOffset = o }; parked = true }
        mutating func ended(at o: Int) { if !ended { endedOffset = o }; ended = true }
        mutating func underrun(at o: Int) { if !underrun { zeroOffset = o }; underrun = true }
        mutating func resumed(at o: Int) { if !resumed { resumedOffset = o }; resumed = true }
    }

    /// One read call of `frames` starting at `now` (arrival of frame k: now + k / 48 kHz).
    @discardableResult
    func consume(_ frames: Int, at now: HostTime = 0) -> [Float] {
        var dst = [Float](repeating: 0, count: frames)
        var rep = Report()
        let w = data.count
        let pause = pauseRequested
        var resume = max(resumeFrames, 1)
        resume = min(resume, maxLead > Self.hold ? maxLead - Self.hold : 1)

        // jump_req_seq != jump_ack_seq. A request taken with a fade stays pending until the
        // fade completes and the jump acknowledges it; it is not taken again (43ff2b5).
        var out = 0
        var guardCount = 0
        while out < frames, guardCount < 64 {
            guardCount += 1
            retireMarks()

            if let q = request, seg == nil {
                let target = jumpTarget(q, w: w)
                cutTag = readerTag
                if state == .playing, target > read {
                    let fadeEnd = min(read + Self.cutFade, target, w)
                    seg = Seg(kind: .cut, start: read, end: fadeEnd, len: fadeEnd - read)
                    jumpTarget = target
                    jumpKind = q.kind
                    jumpMarks = q.marksAt
                } else {
                    readerJump(to: target, kind: q.kind, marksAt: q.marksAt, at: out, &rep)
                }
                continue
            }

            if let s = seg {
                let n = min(max(s.end - read, 0), frames - out)
                copy(n, into: &dst, at: out, inSeg: s, reportStarts: s.kind != .cut, w: w, &rep)
                out += n
                if read >= s.end {
                    seg = nil
                    fadeInLen = 0
                    switch s.kind {
                    case .cut: readerJump(to: jumpTarget, kind: jumpKind, marksAt: jumpMarks, at: out, &rep); state = .idle
                    case .pause: state = .parked; rep.parked(at: out)
                    case .end: state = .idle; rep.ended(at: out)
                    case .underrun: state = .underrun; underruns += 1; rep.underrun(at: out)
                    }
                }
                continue
            }

            let avail = w - read
            var stop = false
            switch state {
            case .parked:
                if pause { stop = true } else { state = .idle }
            case .idle:
                if pause {
                    state = .parked; rep.parked(at: out); stop = true
                } else if avail > Self.hold || (avail > 0 && endAtWrite(w)) {
                    state = .playing; fadeInPos = 0; fadeInLen = Self.fadeIn
                } else {
                    stop = true
                }
            case .underrun:
                let end = endAtWrite(w)
                if avail == 0 && end {
                    state = .idle; rep.ended(at: out)
                } else if (avail > Self.hold && avail - Self.hold >= resume) || (avail > 0 && end) {
                    state = .playing; fadeInPos = 0; fadeInLen = Self.fadeIn; rep.resumed(at: out)
                } else {
                    stop = true
                }
            case .playing:
                let p = pause ? findStart(from: read, upto: w, w: w) : nil
                if let p, p == read {
                    state = .parked; fadeInLen = 0; rep.parked(at: out)
                    break
                }
                var lim = avail > Self.hold ? w - Self.hold : read
                if let p {
                    let fadeStart = p - read > Self.hold ? p - Self.hold : read
                    lim = min(lim, fadeStart)
                }
                if lim > read {
                    let n = min(lim - read, frames - out)
                    copy(n, into: &dst, at: out, inSeg: nil, reportStarts: true, w: w, &rep)
                    out += n
                    break
                }
                if let p {
                    seg = Seg(kind: .pause, start: read, end: p, len: p - read)
                    break
                }
                // Only the hold-back is left: fade it out.
                let end = endAtWrite(w)
                if avail == 0 {
                    if end { state = .idle; rep.ended(at: out) } else {
                        state = .underrun; underruns += 1; rep.underrun(at: out)
                    }
                    break
                }
                seg = Seg(kind: end ? .end : .underrun, start: read, end: w, len: avail)
            }
            if stop { break }
        }
        retireMarks()
        output += dst
        emit(rep, at: now)
        return dst
    }

    /// One cycle in which the feed plays something else (tt_ring_playout_suspend): it faded the
    /// ring to silence, so nothing here is audible and no samples are produced.
    func suspend(at now: HostTime = 0) {
        var rep = Report()
        let w = data.count
        let pause = pauseRequested
        retireMarks()
        if let s = seg {
            seg = nil
            fadeInLen = 0
            if s.kind == .cut {   // the jump is acknowledged: not taken again below
                readerJump(to: jumpTarget, kind: jumpKind, marksAt: jumpMarks, at: 0, &rep)
                state = .idle
            } else {
                // A hold-back fade that holds the next clause's START stops on it (the clause
                // before ended; the next plays from its first frame when read again).
                let onStart = (s.kind == .end || s.kind == .underrun) && s.end > read
                    ? findStart(from: read, upto: s.end - 1, w: w) : nil
                read = max(read, onStart ?? s.end)
                if onStart != nil {
                    state = .idle; rep.ended(at: 0)
                } else {
                    switch s.kind {
                    case .pause: state = .parked; rep.parked(at: 0)
                    case .end: state = .idle; rep.ended(at: 0)
                    default: state = .underrun; underruns += 1; rep.underrun(at: 0)
                    }
                }
            }
            retireMarks()
        }
        if let q = request {   // nothing is audible: a new jump happens at once, without a fade
            let target = jumpTarget(q, w: w)
            cutTag = readerTag
            readerJump(to: target, kind: q.kind, marksAt: q.marksAt, at: 0, &rep)
            retireMarks()
        }
        if state == .idle && pause {
            state = .parked; rep.parked(at: 0)
        } else if state == .parked && !pause {
            state = .idle
        }
        if state == .playing { fadeInPos = 0; fadeInLen = Self.fadeIn }
        emit(rep, at: now)
    }

    private func retireMarks() {
        while let m = marks.first, m.pos < read { marks.removeFirst(); markBase += 1 }
    }

    /// jump_target: the request's write index, or for a next-start jump the first START between
    /// the read index and it; never behind the read index.
    private func jumpTarget(_ q: JumpRequest, w: Int) -> Int {
        var target = q.writeAt
        if q.kind == .nextStart, let p = findStart(from: read, upto: q.writeAt, w: w) { target = p }
        return max(target, read)
    }

    private func findStart(from: Int, upto: Int, w: Int) -> Int? {
        for m in marks {
            if m.pos > upto || m.pos > w { break }
            if m.isStart, m.pos >= from { return m.pos }
        }
        return nil
    }

    private func endAtWrite(_ w: Int) -> Bool {
        for m in marks {
            if m.pos > w { break }
            if m.pos == w, !m.isStart { return true }
        }
        return false
    }

    private func copy(_ n: Int, into dst: inout [Float], at base: Int, inSeg s: Seg?, reportStarts: Bool, w: Int,
                      _ rep: inout Report) {
        for i in 0..<n {
            var g: Float = 1
            if fadeInLen != 0 {
                g *= fadeInGain(fadeInPos, fadeInLen)
                fadeInPos += 1
                if fadeInPos >= fadeInLen { fadeInLen = 0 }
            }
            if let s { g *= fadeOutGain(read + i - s.start, s.len) }
            dst[base + i] = data[read + i] * g
        }
        for m in marks {
            if m.pos >= read + n || m.pos > w { break }
            guard m.isStart, m.pos >= read else { continue }
            readerTag = m.tag
            if reportStarts, rep.starts.count < Self.maxReportStarts { rep.starts.append((m.tag, base + m.pos - read)) }
        }
        read += n
    }

    private func readerJump(to target: Int, kind: PlayoutJump, marksAt: Int, at out: Int, _ rep: inout Report) {
        let moved = target > read
        if moved {
            rep.cutDropped += target - read
            read = target
        }
        if (moved || state == .underrun) && state != .parked {
            state = .idle
            fadeInLen = 0
        }
        if kind == .writeIndex, marksAt > markBase {   // a flush drops the marks pushed before the request
            let drop = min(marksAt - markBase, marks.count)
            marks.removeFirst(drop)
            markBase += drop
        }
        if kind == .nextStart { rep.cut(at: out) } else { rep.flushed(at: out) }
        rep.cutTag = cutTag
        request = nil
    }

    /// feedIOProc's handle_o_report: ENDED, CUT, FLUSHED, UNDERRUN (rank 0), PARKED (1), RESUMED
    /// (2), then the first samples (3), stably sorted by (offset, rank), each at its own offset.
    private func emit(_ rep: Report, at now: HostTime) {
        func t(_ offset: Int) -> HostTime { now + HostTime(Double(offset) / 48_000 * 1e9) }
        var items: [(offset: Int, rank: Int, event: PlayoutRingEvent)] = []
        if rep.ended { items.append((rep.endedOffset, 0, .ended(at: t(rep.endedOffset)))) }
        if rep.cut { items.append((rep.cutOffset, 0, .clauseCut(tag: rep.cutTag, skipped: rep.cutDropped, at: t(rep.cutOffset)))) }
        if rep.flushed { items.append((rep.cutOffset, 0, .flushed(tag: rep.cutTag, skipped: rep.cutDropped, at: t(rep.cutOffset)))) }
        if rep.underrun { items.append((rep.zeroOffset, 0, .underrun(at: t(rep.zeroOffset)))) }
        if rep.parked { items.append((rep.parkedOffset, 1, .parked(at: t(rep.parkedOffset)))) }
        if rep.resumed { items.append((rep.resumedOffset, 2, .resumed(at: t(rep.resumedOffset)))) }
        for s in rep.starts { items.append((s.offset, 3, .firstSample(tag: s.tag, at: t(s.offset)))) }
        let evs = Self.handleOrder(items)
        for e in evs {
            switch e {
            case .firstSample(let tag, _): currentTag = tag
            case .clauseCut, .flushed, .ended: currentTag = nil
            default: break
            }
        }
        events += evs
    }

    /// Stable sort by (offset, rank), as handle_o_report's insertion sort.
    static func handleOrder(_ items: [(offset: Int, rank: Int, event: PlayoutRingEvent)]) -> [PlayoutRingEvent] {
        items.enumerated()
            .sorted { ($0.element.offset, $0.element.rank, $0.offset) < ($1.element.offset, $1.element.rank, $1.offset) }
            .map(\.element.event)
    }

    private func fadeInGain(_ i: Int, _ len: Int) -> Float { len == 0 || i >= len ? 1 : Float(i) / Float(len) }
    private func fadeOutGain(_ i: Int, _ len: Int) -> Float { len == 0 || i >= len ? 0 : Float(len - 1 - i) / Float(len) }
}
