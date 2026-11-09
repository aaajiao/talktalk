import Foundation
import TalkTalkCore

/// LISTEN's Qwen-first adapter. The installed clip recognizer reads bounded cumulative
/// segments; Apple is opened only when Qwen is unavailable or a request fails.
public struct QwenStreamingASR: StreamingASREngine {
    private let engine: EngineProcess?
    private let primary: (any ClipASREngine)?
    private let fallback: any StreamingASREngine
    private let jobs: JobIDSequence
    private let log: EventLog?
    private let onEngine: @Sendable (EngineID) -> Void
    private let configuration: QwenStreamConfiguration
    public var id: EngineID { primary?.id ?? fallback.id }
    /// LISTEN's sentence-pause rules allow for this gap between text updates. A faster cadence
    /// only shows words sooner: a short batch can be wordless mid-speech, so it keeps 1 s here.
    public var partialUpdateIntervalMs: Int { max(1000, configuration.cadenceFrames / 16) }

    public init(engine: EngineProcess?, fallback: any StreamingASREngine,
                jobs: JobIDSequence = .init(), log: EventLog? = nil, cadenceMs: Int = 1000,
                windowSeconds: Int = 8, earlySentences: Bool = false,
                onEngine: @escaping @Sendable (EngineID) -> Void = { _ in }) {
        self.engine = engine
        primary = engine.flatMap { $0.config.roles.contains("asr") ? RemoteQwenASR(engine: $0) : nil }
        self.fallback = fallback; self.jobs = jobs; self.log = log; self.onEngine = onEngine
        configuration = .init(cadenceFrames: cadenceMs * 16, segmentFrames: windowSeconds * 16_000,
                              bufferFrames: windowSeconds * 2 * 16_000, earlySentences: earlySentences)
    }

    // Fake clip backends exercise the adapter without launching an engine or accessing audio.
    init(primary: any ClipASREngine, fallback: any StreamingASREngine,
         jobs: JobIDSequence = .init(), configuration: QwenStreamConfiguration = .init(),
         log: EventLog? = nil, onEngine: @escaping @Sendable (EngineID) -> Void = { _ in }) {
        engine = nil; self.primary = primary; self.fallback = fallback; self.jobs = jobs
        self.configuration = configuration; self.log = log; self.onEngine = onEngine
    }

    public func open(_ lang: Lang, highPriority: Bool) async throws -> any ASRStream {
        try Task.checkCancellation()
        if let primary {
            do {
                if let engine { try await Self.prepare(engine) }
                try Task.checkCancellation()
                onEngine(primary.id)
                return QwenASRStream(primary: primary, fallback: fallback, language: lang,
                    highPriority: highPriority, jobs: jobs, configuration: configuration, log: log, onEngine: onEngine)
            } catch is CancellationError { throw CancellationError() }
            catch { log?.event("asr.fallback", ["reason": .tag("qwenNotReady")]) }
        } else { log?.event("asr.fallback", ["reason": .tag("qwenNotInstalled")]) }
        let stream = try await fallback.open(lang, highPriority: highPriority)
        if Task.isCancelled { await stream.cancel(); throw CancellationError() }
        onEngine(fallback.id)
        return stream
    }

    /// READY is emitted before background ASR loading finishes. This preparation allowance is
    /// separate from per-segment deadlines, and abandoning it never stops shared warmup.
    private static func prepare(_ engine: EngineProcess) async throws {
        let (ready, continuation) = AsyncThrowingStream<Bool, any Error>.makeStream()
        let work = Task {
            do {
                let client = try await readyClient(engine)
                while true {
                    try Task.checkCancellation()
                    let state = try await client.health(timeout: 1).models["asr"]?.state
                    if state == "ready" { break }
                    if state == "failed" {
                        throw EngineAPIError.http(status: 409, code: "asr_not_ready", message: "ASR model failed to load")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                continuation.yield(true); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                continuation.finish(throwing: RemoteEngineError.deadlineExceeded)
            } catch { }
        }
        defer { work.cancel(); timeout.cancel(); continuation.finish() }
        try await withTaskCancellationHandler {
            var iterator = ready.makeAsyncIterator()
            guard try await iterator.next() == true else { throw CancellationError() }
        } onCancel: { work.cancel(); timeout.cancel(); continuation.finish(throwing: CancellationError()) }
    }
}

struct QwenStreamConfiguration: Sendable {
    var cadenceFrames = 16_000                 // one new second, never re-run an unchanged window
    var segmentFrames = 8 * 16_000
    var bufferFrames = 16 * 16_000
    var requestNs: UInt64 = 900_000_000
    var finalizeNs: UInt64 = 1_000_000_000    // LISTEN waits 1500 ms; old results cannot outlive this cut
    var maxExpiredInARow = 3                  // a restarted window is short, so repeats mean real overload
    var earlySentences = false                // release sentences from inside the window (RollingSentenceCommitter)
    var longRunWords = 30                     // with earlySentences: a run this long with no release cuts the window
}

private final class QwenASRStream: ASRStream, @unchecked Sendable {
    private struct Block { var samples: [Int16]; var at: HostTime; var end: HostTime { at + UInt64(samples.count) * 62_500 } }
    private struct Request {
        var job: JobID; var generation: UInt64; var clip: PCMClip16k; var final: Bool
    }
    private let primary: any ClipASREngine
    private let fallback: any StreamingASREngine
    private let language: Lang
    private let highPriority: Bool
    private let jobs: JobIDSequence
    private let configuration: QwenStreamConfiguration
    private let log: EventLog?
    private let onEngine: @Sendable (EngineID) -> Void
    private let lock = NSLock()
    private var closed = false
    private var shutdownTask: Task<Void, Never>?
    private var discarding = false
    private var blocks: [Block] = []
    private var count = 0
    private var generation: UInt64 = 0
    private var finalizedThrough: HostTime = 0
    private var lastRequestedThrough: HostTime = 0
    private var hypothesis: (text: String, through: HostTime)?
    private var finalThrough: HostTime?
    private var finalTimer: Task<Void, Never>?
    private var expiredInARow = 0
    private var sentences: RollingSentenceCommitter?
    private var earlyThrough: HostTime = 0
    private var cutIsForced = true            // only an explicit finalize is a cut the speaker made
    private var active: (request: Request, task: Task<Void, Never>)?
    private var switching = false
    private var fallbackTask: Task<Void, Never>?
    private var fallbackStream: (any ASRStream)?
    private var fallbackReaders: [Task<Void, Never>] = []
    public let volatileEvents: AsyncStream<ASREvent>
    public let finalEvents: AsyncStream<ASREvent>
    private let vol: AsyncStream<ASREvent>.Continuation
    private let fin: AsyncStream<ASREvent>.Continuation

    init(primary: any ClipASREngine, fallback: any StreamingASREngine, language: Lang,
         highPriority: Bool, jobs: JobIDSequence, configuration: QwenStreamConfiguration,
         log: EventLog?, onEngine: @escaping @Sendable (EngineID) -> Void) {
        self.primary = primary; self.fallback = fallback; self.language = language
        self.highPriority = highPriority; self.jobs = jobs; self.configuration = configuration
        self.log = log; self.onEngine = onEngine
        sentences = configuration.earlySentences ? RollingSentenceCommitter(lang: language) : nil
        (volatileEvents, vol) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (finalEvents, fin) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }

    public func feed(_ frames: UnsafeBufferPointer<Int16>, at: HostTime) {
        guard !frames.isEmpty else { return }
        lock.withLock {
            guard !closed else { return }
            if let fallbackStream { fallbackStream.feed(frames, at: at); return }
            let floor = max(finalizedThrough, blocks.last?.end ?? 0)
            let skip = at < floor ? min(frames.count, Self.ceilSamples(floor - at)) : 0
            guard skip < frames.count else { return }
            blocks.append(Block(samples: Array(frames.dropFirst(skip)), at: at + UInt64(skip) * 62_500))
            count += frames.count - skip
            if count > configuration.bufferFrames {
                let dropped = count - configuration.bufferFrames
                let cut = boundaryLocked(after: dropped)
                log?.event("asr.buffer_overflow", ["frames": .int(dropped)])
                advanceLocked(through: cut)
                cancelActiveLocked()
            }
            if !switching, finalThrough == nil, count >= configuration.segmentFrames {
                requestFinalLocked(through: boundaryLocked(after: configuration.segmentFrames), forced: true)
            }
        }
        schedule()
    }

    public func finalize(through: HostTime) async {
        let apple: (any ASRStream)? = lock.withLock {
            guard !closed else { return nil }
            if let fallbackStream { return fallbackStream }
            guard let end = blocks.last?.end, through > finalizedThrough else { return nil }
            requestFinalLocked(through: min(through, end), forced: false)
            return nil
        }
        if let apple { await apple.finalize(through: through) }
        else { schedule() }
    }

    private func requestFinalLocked(through: HostTime, forced: Bool) {
        if !forced, finalThrough != nil { cutIsForced = false }   // LISTEN will close on this final
        guard finalThrough == nil, through > finalizedThrough else { return }
        finalThrough = through
        cutIsForced = forced
        let token = generation, delay = configuration.finalizeNs
        cancelActiveLocked() // prioritize the exact final range over a volatile snapshot
        finalTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            self?.finalTimedOut(generation: token)
        }
    }

    private func schedule() {
        lock.withLock {
            guard !closed, !switching, fallbackStream == nil, active == nil,
                  let end = blocks.last?.end else { return }
            if finalThrough == nil, count >= configuration.segmentFrames {
                requestFinalLocked(through: boundaryLocked(after: configuration.segmentFrames), forced: true)
            }
            let final = finalThrough != nil
            guard final || (count >= configuration.cadenceFrames &&
                (lastRequestedThrough == 0 || end >= lastRequestedThrough + UInt64(configuration.cadenceFrames) * 62_500)) else { return }
            guard let clip = clipLocked(through: finalThrough ?? end) else {
                if let cut = finalThrough { emitFinalLocked("", through: cut) }
                return
            }
            // Avoid decoding digital/near-digital silence. Actual sentence boundaries still
            // come from LISTEN's VAD/FinalizeTrigger, not from a second segmentation policy.
            let energy = clip.samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, clip.samples.count))
            if energy < 0.000001 {
                if final { emitFinalLocked("", through: clip.end) }
                else if hypothesis == nil { sentences?.speechStopped(); advanceLocked(through: clip.end) }
                return
            }
            let request = Request(job: jobs.next(), generation: generation, clip: clip, final: final)
            lastRequestedThrough = clip.end
            let backend = primary, language = language, limit = configuration.requestNs
            let pinned = sentences.flatMap { $0.releasedReading.isEmpty ? nil : $0.releasedReading }
            let task = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    let result = try await backend.transcribe(clip, hint: language, context: nil, pinnedText: pinned,
                        job: request.job, priority: .p2Listen, deadline: HostClock.now() + limit)
                    try Task.checkCancellation()
                    self?.completed(request, text: result.text, failed: false, cancelled: false)
                } catch {
                    self?.completed(request, text: nil, failed: true, cancelled: Task.isCancelled,
                                    expired: Self.isExpired(error))
                }
            }
            active = (request, task)
        }
    }

    private static func isExpired(_ error: any Error) -> Bool {
        if case .http(status: 409, code: "expired", message: _)? = error as? EngineAPIError { return true }
        return false
    }

    private func completed(_ request: Request, text: String?, failed: Bool, cancelled: Bool, expired: Bool = false) {
        var useFallback = false
        lock.withLock {
            guard active?.request.job == request.job else { return }
            active = nil
            guard !closed, generation == request.generation else { return }
            if cancelled { return }
            if expired, expiredInARow + 1 < configuration.maxExpiredInARow {
                expiredInARow += 1
                log?.event("asr.expired", ["final": .bool(request.final), "in_a_row": .int(expiredInARow)])
                restartWindowAfterExpiryLocked()
                return
            }
            if failed {
                if let cut = finalThrough { emitFinalLocked(hypothesisTextLocked(through: cut), through: cut) }
                else if sentences?.hasReleased == true, let hypothesis, hypothesis.through > finalizedThrough {
                    // Apple replays all audio not yet finalized, which would repeat released sentences.
                    emitFinalLocked(hypothesis.text, through: hypothesis.through)
                }
                switching = true; useFallback = true
                return
            }
            expiredInARow = 0
            let clean = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if request.final {
                emitFinalLocked(clean, through: request.clip.end)
            } else {
                hypothesis = (clean, request.clip.end)
                if finalThrough == nil { publishHypothesisLocked(clean, through: request.clip.end) }
            }
        }
        if useFallback { startFallback() }
        else { schedule() }
    }

    /// The engine drops a listen decode that runs past its deadline, which happens as a
    /// cumulative window nears the segment cap. That says this window is too long, not that
    /// Qwen is unusable: commit what the last decode read and restart the window after it, so
    /// the next decode is short and the audio it did not reach is still recognized.
    private func restartWindowAfterExpiryLocked() {
        if let hypothesis, !hypothesis.text.isEmpty, hypothesis.through > finalizedThrough {
            emitFinalLocked(hypothesis.text, through: hypothesis.through)
        } else if let cut = finalThrough {
            emitFinalLocked("", through: cut)
        } else if sentences != nil, let hypothesis, hypothesis.through > finalizedThrough {
            // A wordless reading commits nothing, yet a long window must still restart.
            advanceLocked(through: hypothesis.through)
        }
    }

    private func finalTimedOut(generation token: UInt64) {
        lock.withLock {
            guard !closed, generation == token, let cut = finalThrough else { return }
            log?.event("asr.final_timeout", ["has_hypothesis": .bool(!hypothesisTextLocked(through: cut).isEmpty)])
            emitFinalLocked(hypothesisTextLocked(through: cut), through: cut)
            cancelActiveLocked()
        }
        schedule()
    }

    private func hypothesisTextLocked(through: HostTime) -> String {
        guard let hypothesis, hypothesis.through <= through else { return "" }
        return hypothesis.text
    }
    private func cancelActiveLocked() {
        guard let active else { return }
        active.task.cancel()
        let backend = primary, job = active.request.job
        Task { await backend.cancel(job) }
    }
    private func publishHypothesisLocked(_ text: String, through: HostTime) {
        guard var reader = sentences else { vol.yield(.volatile(text, through: through)); return }
        let reading = reader.observe(text)
        sentences = reader
        if let sentence = reading.sentence {
            log?.event("asr.sentence_early")
            yieldEarlyFinalLocked(sentence, before: through)
        }
        vol.yield(.volatile(reading.remainder, through: through))
        // Speech that never reaches a period would otherwise wait for the window's cap, past
        // LISTEN's hard cap, whose cut keeps the fake period. A forced cut drops it.
        if reading.sentence == nil, reader.isLong(reading.remainder, fromWords: configuration.longRunWords),
           let end = blocks.last?.end {
            log?.event("asr.long_run_cut")
            requestFinalLocked(through: end, forced: true)
        }
    }
    /// LISTEN ignores a final that does not extend past the last one, and drops readings it
    /// already covers. An early sentence has no audio end of its own, so it takes a stamp just
    /// under the reading it came from: that fences older readings and leaves the window's cut valid.
    private func yieldEarlyFinalLocked(_ text: String, before limit: HostTime) {
        earlyThrough = max(earlyThrough &+ 1, limit &- 1)
        yieldFinalLocked(text, through: earlyThrough)
    }
    private func yieldFinalLocked(_ text: String, through: HostTime) {
        let start = min(blocks.first?.at ?? through, through)
        if case .dropped = fin.yield(.final(text, range: start...through)) {
            log?.event("asr.final_overflow")
        }
    }
    private func emitFinalLocked(_ text: String, through: HostTime) {
        var tail = text, upper = through
        if var reader = sentences {
            let closing = reader.finish(text, forced: cutIsForced)
            sentences = reader
            for (index, sentence) in closing.sentences.enumerated() {
                yieldEarlyFinalLocked(sentence, before: through &- UInt64(closing.sentences.count - 1 - index))
            }
            tail = closing.tail
            upper = max(through, earlyThrough &+ 1)
        }
        yieldFinalLocked(tail, through: upper)
        advanceLocked(through: through)
    }
    private func advanceLocked(through: HostTime) {
        finalizedThrough = max(finalizedThrough, through)
        blocks = blocks.compactMap { block in
            let skip = through > block.at ? min(block.samples.count, Self.ceilSamples(through - block.at)) : 0
            guard skip < block.samples.count else { return nil }
            return Block(samples: Array(block.samples.dropFirst(skip)), at: block.at + UInt64(skip) * 62_500)
        }
        count = blocks.reduce(0) { $0 + $1.samples.count }
        generation &+= 1; finalThrough = nil; hypothesis = nil; lastRequestedThrough = 0
        sentences?.windowMoved(); cutIsForced = true
        finalTimer?.cancel(); finalTimer = nil
    }
    private static func ceilSamples(_ ns: UInt64) -> Int { Int(ns / 62_500 + (ns % 62_500 == 0 ? 0 : 1)) }
    private func boundaryLocked(after samples: Int) -> HostTime {
        var remaining = samples
        for block in blocks {
            if remaining <= block.samples.count { return block.at + UInt64(remaining) * 62_500 }
            remaining -= block.samples.count
        }
        return blocks.last?.end ?? finalizedThrough
    }
    private func clipLocked(through: HostTime) -> PCMClip16k? {
        var samples: [Float] = [], start: HostTime?, end: HostTime = 0
        for block in blocks where block.at < through {
            let n = min(block.samples.count, Int((through - block.at) / 62_500))
            guard n > 0 else { continue }
            if start == nil { start = block.at }
            samples += block.samples.prefix(n).map { Float($0) / 32768 }
            end = block.at + UInt64(n) * 62_500
        }
        guard let start, !samples.isEmpty else { return nil }
        return PCMClip16k(samples: samples, start: start, end: end)
    }

    private func startFallback() {
        lock.withLock {
            guard !closed, fallbackTask == nil else { return }
            log?.event("asr.fallback", ["reason": .tag("qwenRequestFailed")])
            fallbackTask = Task { [weak self, fallback, language, highPriority] in
                do {
                    let stream = try await fallback.open(language, highPriority: highPriority)
                    guard let self else { await stream.cancel(); return }
                    let accepted = self.lock.withLock { () -> Bool in
                        guard !self.closed, !Task.isCancelled else { return false }
                        // A finalize may have arrived while Apple was opening. Close that
                        // Qwen range now; replaying it could produce a final after LISTEN's timeout.
                        if let cut = self.finalThrough {
                            self.emitFinalLocked(self.hypothesisTextLocked(through: cut), through: cut)
                        }
                        for block in self.blocks {
                            block.samples.withUnsafeBufferPointer { stream.feed($0, at: block.at) }
                        }
                        self.blocks.removeAll(); self.count = 0
                        self.finalTimer?.cancel(); self.finalTimer = nil; self.finalThrough = nil
                        self.fallbackStream = stream; self.switching = false
                        self.fallbackReaders = [Task { [weak self] in
                            for await event in stream.volatileEvents { self?.forward(event) }
                        }, Task { [weak self] in
                            for await event in stream.finalEvents { self?.forward(event) }
                        }]
                        return true
                    }
                    if accepted { self.onEngine(fallback.id) }
                    else { await stream.cancel() }
                } catch {
                    self?.log?.event("asr.unavailable", ["reason": .tag("fallbackFailed")])
                    // shutdown waits for this opening task; never await it from itself.
                    Task { await self?.cancel() }
                }
            }
        }
    }
    private func forward(_ event: ASREvent) {
        lock.withLock {
            guard !closed else { return }
            switch event {
            case .volatile(_, let through) where through > finalizedThrough: vol.yield(event)
            case .final(_, let range) where range.upperBound > finalizedThrough:
                finalizedThrough = range.upperBound
                if case .dropped = fin.yield(event) { log?.event("asr.final_overflow") }
            default: break
            }
        }
    }

    public func close() async {
        await shutdown(discard: false)
    }

    public func cancel() async {
        await shutdown(discard: true)
    }

    private func shutdown(discard: Bool) async {
        let (task, interrupt): (Task<Void, Never>, (any ASRStream)?) = lock.withLock {
            if let shutdownTask {
                let interrupt = discard && !discarding
                if interrupt { discarding = true; shutdownTask.cancel() }
                return (shutdownTask, interrupt ? fallbackStream : nil)
            }
            closed = true
            discarding = discard
            active?.task.cancel(); finalTimer?.cancel(); fallbackTask?.cancel()
            fallbackReaders.forEach { $0.cancel() }; fallbackReaders.removeAll()
            blocks.removeAll(); count = 0
            vol.finish(); fin.finish()
            let old = fallbackStream, opening = fallbackTask, job = active?.request.job
            let task = Task {
                if let job { Task { await primary.cancel(job) } }
                if discard || Task.isCancelled { await old?.cancel() }
                else { await old?.close() }
                // A late Apple open must be cancelled before another session can open one.
                await opening?.value
            }
            shutdownTask = task
            return (task, nil)
        }
        await interrupt?.cancel()
        await task.value
    }
}
