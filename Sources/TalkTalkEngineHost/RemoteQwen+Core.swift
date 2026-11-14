import CryptoKit
import Darwin
import Foundation
import Synchronization
import TalkTalkCore

// §4.1 conformances: RemoteQwenASR is the LISTEN second pass (`ClipASREngine`, Engines+ASR.swift),
// RemoteQwenTTS is the SPEAK voice (`TTSEngine`, Engines+TTS.swift). Core types stay on the app
// side; this file maps them to the engine wire (§4.4: string job ids, `lang`, snake_case tail).

public enum RemoteEngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The caller's deadline passed; the engine job has been cancelled.
    case deadlineExceeded
    /// `/v1/tts` failed mid-stream (`tts_failed`, `voice_absent`, …).
    case tts(code: String, message: String)
    /// The stream ended without a tail frame (engine crash or a cut connection).
    case truncated
    case badReference
    case voiceNotReady
    /// SPEAK stall rule (§5.7, `TTSStall`): the oldest open stream had nothing drainable and no new
    /// chunk for 1.0 s outside a long step or a legal hold. The engine job has been cancelled. The
    /// caller always reports it to `ClauseQueue.streamFailed(job:)` and then
    /// `ClauseLedger.streamFailed(clause, reason: .stall)`; the ledger decides by
    /// `firstSampleEnqueued` whether it is `incomplete` or resent. `chunksYielded` is for
    /// logs only: yielded chunks may never have reached ringO (preroll, whole clause, holding).
    case stalled(chunksYielded: Int)

    public var description: String {
        switch self {
        case .deadlineExceeded: "deadline exceeded"
        case .tts(let c, let m): m.isEmpty ? c : "\(c): \(m)"
        case .truncated: "TTS stream ended without a tail"
        case .badReference: "reference audio is neither f32 PCM nor a PCM16 WAV"
        case .voiceNotReady: "voice did not become ready"
        case .stalled(let n): "TTS stalled after \(n) chunk(s) (no chunk for 1 s with nothing drainable)"
        }
    }
}

/// Engine job ids on the wire are strings; Core's JobID is a number. The prefix keeps TTS and
/// ASR jobs with the same number apart in `/v1/cancel`.
enum WireJob {
    static func tts(_ j: JobID) -> String { "tts-\(j)" }
    static func asr(_ j: JobID) -> String { "asr-\(j)" }
}

extension EngineProcess {
    nonisolated func engineID(role: String) -> EngineID {
        let key = role == "tts" ? config.tts : config.asr
        return EngineID(name: key ?? role, revision: config.record.roles[role]?.rev ?? "", placement: .engineGPU)
    }
}

// MARK: - ASR

extension RemoteQwenASR: ClipASREngine {
    public var id: EngineID { engine.engineID(role: "asr") }

    public func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, job: JobID,
                           priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        try await transcribe(clip, hint: hint, context: context, pinnedText: nil, job: job, priority: priority, deadline: deadline)
    }

    public func transcribe(_ clip: PCMClip16k, hint: Lang, context: String?, pinnedText: String?, job: JobID,
                           priority: Priority, deadline: HostTime?) async throws -> ASRFinal {
        let received = HostClock.now()
        if let deadline, deadline <= received { throw RemoteEngineError.deadlineExceeded }
        let wire = WireJob.asr(job)
        let call: @Sendable () async throws -> ASRFinal = {
            try Task.checkCancellation()
            let client = try await readyClient(engine)
            try Task.checkCancellation()
            let started = HostClock.now()
            if let deadline, started >= deadline { throw RemoteEngineError.deadlineExceeded }
            let result = try await withTaskCancellationHandler {
                try await client.asr(samples16k: clip.samples, hint: hint.rawValue, priority: priority.rawValue,
                                     job: wire, context: context, pinnedText: pinnedText)
            } onCancel: {
                Task { try? await client.cancel(job: wire) }
            }
            try Task.checkCancellation()
            let finished = HostClock.now()
            return ASRFinal(text: result.text, language: Self.lang(result.language),
                timing: StageTiming(received: received, started: started, firstOutput: finished, finished: finished))
        }
        guard let deadline else { return try await call() }

        // Race the entire operation, including cold READY, without a task-group exit waiting
        // on the losing operation. Cancelling this observer never stops global engine warmup;
        // the post-READY cancellation check prevents a timed-out waiter from submitting ASR.
        let (results, continuation) = AsyncThrowingStream<ASRFinal, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let operation = Task {
            do { continuation.yield(try await call()); continuation.finish() }
            catch { continuation.finish(throwing: error) }
        }
        let timer = Task {
            do {
                let now = HostClock.now()
                if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
                try Task.checkCancellation()
                continuation.finish(throwing: RemoteEngineError.deadlineExceeded)
            } catch { }
        }
        defer { operation.cancel(); timer.cancel(); continuation.finish() }
        return try await withTaskCancellationHandler {
            var iterator = results.makeAsyncIterator()
            guard let result = try await iterator.next() else { throw CancellationError() }
            return result
        } onCancel: {
            operation.cancel(); timer.cancel()
            continuation.finish(throwing: CancellationError())
        }
    }

    public func cancel(_ job: JobID) async {
        try? await engine.client?.cancel(job: WireJob.asr(job))
    }

    /// The engine reports a code or Qwen3-ASR's language name.
    static func lang(_ s: String?) -> Lang? {
        guard let s = s?.lowercased() else { return nil }
        if let l = Lang(rawValue: s) { return l }
        switch s {
        case "english": return .en
        case "german", "deutsch": return .de
        case "french", "français": return .fr
        case "chinese", "mandarin": return .zh
        default: return nil
        }
    }
}

// MARK: - TTS

extension RemoteQwenTTS: TTSEngine {
    public var id: EngineID { engine.engineID(role: "tts") }
    public var outputRate: Double { 24_000 }

    public func buildConditioning(_ ref: VoiceReference, model: EngineID, mode: CloneMode) async throws -> Data {
        guard let pcm = Self.samples(ref.pcm24k), !pcm.isEmpty else { throw RemoteEngineError.badReference }
        let client = try await engine.readyTTSClient()
        return try await client.buildVoice(reference24k: pcm, refText: ref.text, model: model.name).blob
    }

    public func load(_ voice: VoiceHandle, blob: Data) async throws {
        let client = try await engine.readyTTSClient()
        try await client.loadVoice(blob: blob, model: voice.model.name, key: voice.conditioningKey)
        let expectedKey8 = SHA256.hash(data: Data(voice.conditioningKey.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        // A different load may finish while we wait. Ready alone does not identify this voice.
        let end = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < end {
            try Task.checkCancellation()
            if let h = try? await client.health(timeout: 2), h.voice.state == "ready" {
                guard h.voice.key8 == expectedKey8 else {
                    throw RemoteEngineError.tts(code: "voice_key_mismatch", message: "loaded voice does not match the requested voice")
                }
                try Task.checkCancellation()
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw RemoteEngineError.voiceNotReady
    }

    /// Chunks as the engine sends them; the isLast chunk carries no samples, only the summary
    /// (holding back the last PCM chunk to mark it would delay every chunk by one). A watchdog
    /// applies the SPEAK stall rule (`TTSStall`) while the stream is open.
    public func speak(_ r: TTSRequest) -> AsyncThrowingStream<TTSChunk, any Error> {
        let engine = self.engine
        let playout = self.playout
        let stall = self.stall
        let board = self.board
        return AsyncThrowingStream { cont in
            // Registered now, in speak() order; the head frame's engine seq then places it in the
            // engine's render order (the requests race over separate connections).
            let id = board.open(at: .now)
            let ended = Mutex(false)
            let stalled = Mutex(false)
            let gotTail = Mutex(false)
            let waitingForModel = Mutex(true)
            /// The first of stream end / stall wins; the loser does nothing.
            let end: @Sendable (Error?) -> Bool = { error in
                let first = ended.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first {
                    board.close(id, at: .now)
                    if let error { cont.finish(throwing: error) } else { cont.finish() }
                }
                return first
            }
            let task = Task {
                do {
                    let received = HostClock.now()
                    let client = try await engine.readyTTSClient()
                    try Task.checkCancellation()
                    board.hold(id, at: .now)
                    waitingForModel.withLock { $0 = false }
                    let started = HostClock.now()
                    let stream = client.tts(EngineTTSRequest(text: r.text, lang: r.language.rawValue,
                                                             job: WireJob.tts(r.job), seed: Int(r.seed),
                                                             wholeClause: r.wholeClause, voiceKey: r.voice.conditioningKey,
                                                             contextID: r.contextID, previousJob: r.previousJob.map(WireJob.tts)))
                    var seq = 0
                    var first: HostTime?
                    for try await ev in stream.events {
                        // After the tail, read on to the end of the HTTP stream: leaving early would
                        // terminate it as cancelled and send a needless /v1/cancel for a finished job.
                        if gotTail.withLock({ $0 }) { continue }
                        if ended.withLock({ $0 }) { return }
                        switch ev {
                        case .pcm(let p):
                            let t = HostClock.now()
                            board.chunk(id, at: .now)
                            if first == nil { first = t }
                            cont.yield(TTSChunk(job: r.job, seq: seq, samples24k: p, isLast: false, producedAt: t))
                            seq += 1
                        case .tail(let tail):
                            let t = HostClock.now()
                            let s = Self.summary(tail, timing: StageTiming(received: received, started: started,
                                                                           firstOutput: first, finished: t))
                            // Before the yield: a consumer that stops at isLast terminates the stream
                            // at once, and onTermination must already see the job as finished.
                            gotTail.withLock { $0 = true }
                            cont.yield(TTSChunk(job: r.job, seq: seq, samples24k: [], isLast: true, producedAt: t, summary: s))
                            _ = end(nil)
                        case .failed(let code, let message):
                            throw RemoteEngineError.tts(code: code, message: message)
                        case .progress:
                            // held audio (hold, whole clause, retry): the job is alive (§5.7)
                            board.progress(id, at: .now)
                        case .head(_, _, let engineSeq):
                            if let engineSeq { board.sequenced(id, engineSeq: engineSeq, at: .now) }
                        case .unknown:
                            break
                        }
                    }
                    if gotTail.withLock({ $0 }) { return }
                    if Task.isCancelled { throw CancellationError() }
                    throw RemoteEngineError.truncated
                } catch {
                    _ = end(error)
                }
            }
            let watchdog = Task {
                while !Task.isCancelled, !ended.withLock({ $0 }) {
                    try? await Task.sleep(for: stall.tick)
                    // A model preparing after READY is not a stalled /tts request.
                    if waitingForModel.withLock({ $0 }) { board.hold(id, at: .now); continue }
                    // Only the oldest open stream is judged, and nothing while a stall is unresolved.
                    guard board.isHead(id), board.unresolvedSince == nil, var w = board.window(id) else { continue }
                    // Paused, or parked at the render horizon: nothing drains on purpose (§5.7).
                    if playout.holdsEngine(at: .now, config: stall) { board.hold(id, at: .now); continue }
                    guard w.needsHealth(at: .now, aheadMs: playout.aheadMs(at: .now), config: stall) else { continue }
                    // Only now ask the engine whether it is in a long step (cold compile, weights).
                    let gpu = try? await engine.client?.health(timeout: stall.healthTimeout).gpu
                    if ended.withLock({ $0 }) { return }
                    // A chunk (or a new head) during the health call restarted the window: start over.
                    guard board.isHead(id), let fresh = board.window(id), fresh.start == w.start else { continue }
                    if playout.holdsEngine(at: .now, config: stall) { board.hold(id, at: .now); continue }
                    // A failed health call (nil) keeps the previous in_long_step answer.
                    let isStalled = w.observe(at: .now, inLongStep: gpu?.inLongStep,
                                              aheadMs: playout.aheadMs(at: .now), config: stall)
                    board.update(id, w)
                    guard isStalled else { continue }
                    let chunks = board.chunks(id)
                    let token = board.markStalled(since: w.start)
                    stalled.withLock { $0 = true }
                    // Cancel the engine job first: when the caller hears `.stalled` the job is gone.
                    try? await engine.client?.cancel(job: WireJob.tts(r.job))
                    task.cancel()
                    guard end(RemoteEngineError.stalled(chunksYielded: chunks)) else {
                        board.resolve(token, at: .now)
                        return
                    }
                    // Escalate to the §7.6 hang handling if the stall reaches hangAfter. Until then
                    // the streams behind this one are not judged (they are kept, not cut). Only this
                    // stall's own marker counts: a chunk may have resolved it and another stream
                    // stalled since, whose check runs on its own clock (compare-and-clear).
                    let remaining = stall.hangAfter - (ContinuousClock.now - w.start)
                    if remaining > .zero { try? await Task.sleep(for: remaining) }
                    if board.isUnresolved(token) {
                        let after = try? await engine.client?.health(timeout: stall.healthTimeout).gpu
                        if board.isUnresolved(token), TTSStall.isHung(after, config: stall) {
                            await engine.reportHang("SPEAK stall: no TTS chunk for \(stall.hangAfter) (job \(WireJob.tts(r.job)))")
                        }
                    }
                    board.resolve(token, at: .now)
                    return
                }
            }
            cont.onTermination = { _ in
                let first = ended.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { board.close(id, at: .now) }
                // A finished job (tail received) is left to drain its HTTP stream; see above.
                if !gotTail.withLock({ $0 }) { task.cancel() }
                // After a stall the watchdog keeps running: the hang check outlives the stream.
                if !stalled.withLock({ $0 }) { watchdog.cancel() }
            }
        }
    }

    /// The drainable amount (`PlayoutReporter` `onDrainable`): audio actually moving to the speaker,
    /// without what the ClauseQueue holds for preroll or whole-clause mode. Once set, the stall rule
    /// reads it instead of `PlayoutReport.bufferedMs`.
    public func noteDrainable(_ ms: Int) {
        playout.setDrainable(ms)
    }

    /// Sends the whole report (§4.4 body = PlayoutReport) and keeps it for the stall rule.
    public func report(_ p: PlayoutReport) async {
        playout.set(p, at: .now)
        try? await engine.client?.playout(p, job: p.job.map(WireJob.tts))
    }

    public func cancel(_ job: JobID) async {
        try? await engine.client?.cancel(job: WireJob.tts(job))
    }

    static func summary(_ t: EngineTTSTail, timing: StageTiming) -> TTSSummary {
        TTSSummary(audioS: t.audioS, frames: t.frames, runaway: t.runaway, short: t.short, slow: t.slow ?? false,
                   echoAborts: t.echoAborts ?? 0, attempts: t.attempts ?? 1, leadTrimMs: t.leadTrimMs ?? 0, timing: timing,
                   computeRTF: t.audioS > 0 ? (t.timing["gpu_ms_all_attempts"] ?? nil).map { $0 / 1000 / t.audioS } : nil,
                   contextUsed: t.contextUsed)
    }

    /// `VoiceReference.pcm24k` is "bytes, not a path" (§4.1). Accepted: a PCM16 mono RIFF/WAVE file
    /// (what `voice/reference.wav` holds) or raw little-endian Float32 samples (the engine's f32 frame).
    static func samples(_ d: Data) -> [Float]? {
        let b = [UInt8](d)
        if b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x41, 0x56, 0x45] {
            func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
            func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
            var off = 12, fmtOK = false
            while off + 8 <= b.count {
                let size = u32(off + 4), body = off + 8
                if b[off..<off + 4] == [0x66, 0x6D, 0x74, 0x20] {          // "fmt "
                    guard body + 16 <= b.count, u16(body) == 1, u16(body + 2) == 1, u16(body + 14) == 16,
                          u32(body + 4) == 24_000 else { return nil }
                    fmtOK = true
                } else if b[off..<off + 4] == [0x64, 0x61, 0x74, 0x61], fmtOK {   // "data"
                    let end = min(b.count, body + size)
                    var out = [Float]()
                    out.reserveCapacity((end - body) / 2)
                    var i = body
                    while i + 1 < end {
                        out.append(Float(Int16(bitPattern: UInt16(u16(i)))) / 32768)
                        i += 2
                    }
                    return out
                }
                off = body + size + (size & 1)
            }
            return nil
        }
        guard d.count % 4 == 0 else { return nil }
        return d.withUnsafeBytes { raw in
            (0..<(d.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}
