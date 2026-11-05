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
    public var partialUpdateIntervalMs: Int { configuration.cadenceFrames / 16 }

    public init(engine: EngineProcess?, fallback: any StreamingASREngine,
                jobs: JobIDSequence = .init(), log: EventLog? = nil,
                onEngine: @escaping @Sendable (EngineID) -> Void = { _ in }) {
        self.engine = engine
        primary = engine.flatMap { $0.config.roles.contains("asr") ? RemoteQwenASR(engine: $0) : nil }
        self.fallback = fallback; self.jobs = jobs; self.log = log; self.onEngine = onEngine
        configuration = .init()
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
        if Task.isCancelled { await stream.close(); throw CancellationError() }
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
                    if try await client.health(timeout: 1).models["asr"]?.state == "ready" { break }
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
    private var blocks: [Block] = []
    private var count = 0
    private var generation: UInt64 = 0
    private var finalizedThrough: HostTime = 0
    private var lastRequestedThrough: HostTime = 0
    private var hypothesis: (text: String, through: HostTime)?
    private var finalThrough: HostTime?
    private var finalTimer: Task<Void, Never>?
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
                requestFinalLocked(through: boundaryLocked(after: configuration.segmentFrames))
            }
        }
        schedule()
    }

    public func finalize(through: HostTime) async {
        let apple: (any ASRStream)? = lock.withLock {
            guard !closed else { return nil }
            if let fallbackStream { return fallbackStream }
            guard let end = blocks.last?.end, through > finalizedThrough else { return nil }
            requestFinalLocked(through: min(through, end))
            return nil
        }
        if let apple { await apple.finalize(through: through) }
        else { schedule() }
    }

    private func requestFinalLocked(through: HostTime) {
        guard finalThrough == nil, through > finalizedThrough else { return }
        finalThrough = through
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
                requestFinalLocked(through: boundaryLocked(after: configuration.segmentFrames))
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
                else if hypothesis == nil { advanceLocked(through: clip.end) }
                return
            }
            let request = Request(job: jobs.next(), generation: generation, clip: clip, final: final)
            lastRequestedThrough = clip.end
            let backend = primary, language = language, limit = configuration.requestNs
            let task = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    let result = try await backend.transcribe(clip, hint: language, context: nil, job: request.job,
                        priority: .p2Listen, deadline: HostClock.now() + limit)
                    try Task.checkCancellation()
                    self?.completed(request, text: result.text, failed: false, cancelled: false)
                } catch {
                    self?.completed(request, text: nil, failed: true, cancelled: Task.isCancelled)
                }
            }
            active = (request, task)
        }
    }

    private func completed(_ request: Request, text: String?, failed: Bool, cancelled: Bool) {
        var useFallback = false
        lock.withLock {
            guard active?.request.job == request.job else { return }
            active = nil
            guard !closed, generation == request.generation else { return }
            if cancelled { return }
            if failed {
                if let cut = finalThrough { emitFinalLocked(hypothesisTextLocked(through: cut), through: cut) }
                switching = true; useFallback = true
                return
            }
            let clean = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if request.final {
                emitFinalLocked(clean, through: request.clip.end)
            } else {
                hypothesis = (clean, request.clip.end)
                if finalThrough == nil { vol.yield(.volatile(clean, through: request.clip.end)) }
            }
        }
        if useFallback { startFallback() }
        else { schedule() }
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
    private func emitFinalLocked(_ text: String, through: HostTime) {
        let start = min(blocks.first?.at ?? through, through)
        if case .dropped = fin.yield(.final(text, range: start...through)) {
            log?.event("asr.final_overflow")
        }
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
                    guard let self else { await stream.close(); return }
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
                    else { await stream.close() }
                } catch {
                    self?.log?.event("asr.unavailable", ["reason": .tag("fallbackFailed")])
                    await self?.close()
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
        let closing: ((any ASRStream)?, JobID?) = lock.withLock {
            guard !closed else { return (nil, nil) }
            closed = true
            active?.task.cancel(); finalTimer?.cancel(); fallbackTask?.cancel()
            fallbackReaders.forEach { $0.cancel() }; fallbackReaders.removeAll()
            blocks.removeAll(); count = 0
            vol.finish(); fin.finish()
            let old = fallbackStream; fallbackStream = nil
            return (old, active?.request.job)
        }
        if let job = closing.1 { Task { await primary.cancel(job) } }
        await closing.0?.close()
    }
}
