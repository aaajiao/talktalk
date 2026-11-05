import Foundation
import TalkTalkApple
import TalkTalkCore

/// One SPEAK preview slot. Capture continues while Apple final ASR borrows the slot; reopening
/// replays only the current uncommitted audio, never an earlier segment or another press.
public actor SpeakPreview {
    public struct Snapshot: Sendable {
        public var level: Float
        public var text: String
        /// Only this prefix participates in commit decisions; `text` remains fully revisable UI.
        public var stableText: String
        public var from, through: HostTime
        public var isFinal: Bool
    }
    private let engine: any StreamingASREngine
    private var stream: (any ASRStream)?
    private var frameReader: Task<Void, Never>?
    private var readers: [Task<Void, Never>] = []
    private var transition: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var active = false, paused = false, borrowed = false
    private var floor: HostTime = 0
    private var frames: [SpeakPreviewFrame] = []
    private var level: Float = 0
    private var recognizedThrough: HostTime = 0
    private var stable = LCPCommitter(unit: .character)
    private var finals = ""
    private var hypothesis = ""
    private var finalizedThrough: HostTime = 0
    private var update: @Sendable (Snapshot) -> Void = { _ in }
    public init(engine: any StreamingASREngine) { self.engine = engine }

    public func start(frames: AsyncStream<SpeakPreviewFrame>,
                      update: @escaping @Sendable (Snapshot) -> Void) async {
        guard !Task.isCancelled else { return }
        await stop()
        guard !Task.isCancelled else { return }
        active = true; paused = borrowed; floor = 0; recognizedThrough = 0; finalizedThrough = 0; self.update = update
        frameReader = Task { [weak self] in
            for await frame in frames {
                guard !Task.isCancelled else { break }
                await self?.feed(frame)
            }
        }
        await change(open: !paused)
    }

    /// A committed cut discards old preview context and opens a recognizer for its successor.
    public func advance(to host: HostTime) async {
        guard active, host > floor else { return }
        floor = host; recognizedThrough = host; finalizedThrough = host
        trimFrames(); stable.reset(); finals = ""; hypothesis = ""
        await change(open: !paused)
    }

    public func pauseForFinalASR() async {
        borrowed = true; paused = true
        await change(open: false)
    }
    public func resumeAfterFinalASR() async {
        borrowed = false
        guard active else { return }
        paused = false
        await change(open: true)
    }
    public func stop() async {
        active = false; paused = true
        frameReader?.cancel(); frameReader = nil
        frames.removeAll(); stable.reset(); finals = ""; hypothesis = ""
        await change(open: false)
    }

    private func feed(_ input: SpeakPreviewFrame) {
        guard active else { return }
        if floor == 0 { floor = input.at }
        frames.append(input); level = input.level; trimFrames()
        if let stream, let frame = clipped(input) {
            frame.samples.withUnsafeBufferPointer { stream.feed($0, at: frame.at) }
        }
        update(.init(level: level, text: finals + hypothesis, stableText: finals + stable.committedText, from: floor,
                     through: recognizedThrough, isFinal: false))
    }
    private func clipped(_ frame: SpeakPreviewFrame) -> SpeakPreviewFrame? {
        let offset = floor > frame.at ? floor - frame.at : 0
        let skipped = min(frame.samples.count, Int(offset / 62_500 + (offset % 62_500 == 0 ? 0 : 1)))
        guard skipped < frame.samples.count else { return nil }
        return .init(samples: Array(frame.samples.dropFirst(skipped)), at: frame.at + UInt64(skipped) * 62_500, level: frame.level)
    }
    private func trimFrames() {
        frames = frames.compactMap(clipped)
        // The segment hard cap is 4.5 s; this spare second covers callback delivery and tail.
        if let last = frames.last, last.at > 6_000_000_000 {
            frames.removeAll { $0.at + UInt64($0.samples.count) * 62_500 < last.at - 6_000_000_000 }
        }
    }

    private func change(open: Bool) async {
        generation &+= 1
        let token = generation, previous = transition
        previous?.cancel()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.closeCurrent()
            guard open, !Task.isCancelled else { return }
            await self.open(token: token)
        }
        transition = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func open(token: UInt64) async {
        guard token == generation, active, !paused, !Task.isCancelled else { return }
        guard let opened = try? await engine.open(.zh, highPriority: true) else { return }
        guard token == generation, active, !paused, !Task.isCancelled else { await Self.cancel(opened); return }
        stream = opened; stable.reset(); finals = ""; hypothesis = ""
        recognizedThrough = floor; finalizedThrough = floor
        for frame in frames { frame.samples.withUnsafeBufferPointer { opened.feed($0, at: frame.at) } }
        readers = [Task { [weak self] in
            for await event in opened.volatileEvents {
                guard !Task.isCancelled else { break }
                await self?.result(event, token: token)
            }
        }, Task { [weak self] in
            for await event in opened.finalEvents {
                guard !Task.isCancelled else { break }
                await self?.result(event, token: token)
            }
        }]
    }
    private func result(_ event: ASREvent, token: UInt64) {
        guard token == generation, active, !paused else { return }
        let through: HostTime, final: Bool
        switch event {
        case .volatile(let text, let end):
            guard end > max(floor, finalizedThrough), end >= recognizedThrough else { return }
            hypothesis = text
            _ = stable.update(hypothesis: text); through = end; final = false
        case .final(let text, let range):
            guard range.upperBound > max(floor, finalizedThrough) else { return }
            finals += text; stable.reset(); hypothesis = ""
            through = range.upperBound; finalizedThrough = through; final = true
        }
        recognizedThrough = through
        update(.init(level: level, text: finals + hypothesis, stableText: finals + stable.committedText,
                     from: floor, through: through, isFinal: final))
    }
    private func closeCurrent() async {
        readers.forEach { $0.cancel() }; readers.removeAll()
        let old = stream; stream = nil
        if let old { await Self.cancel(old) }
    }
    private static func cancel(_ stream: any ASRStream) async {
        if let apple = stream as? AppleSpeechStream { await apple.cancel() }
        else { await stream.close() }
    }
}
