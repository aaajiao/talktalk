import Foundation
import TalkTalkCore

/// Worker-confined 75 s Float32 ring. Capture anchors accompany each block so ordinary hardware
/// clock drift never accumulates into the privacy floor. All reads, including preview, clamp to it.
public final class SpeakMicRing {
    public static let sampleRate = 16_000
    public let capacity: Int
    private struct Span { var first, end: Int64; var host: HostTime }
    private var samples: [Float]
    private var spans: [Span] = []
    private var first: Int64 = 0
    private var written: Int64 = 0
    public private(set) var floor: HostTime = 0

    public init(seconds: Int = 75) {
        capacity = max(1, seconds) * Self.sampleRate
        samples = [Float](repeating: 0, count: capacity)
    }
    public var count: Int { Int(written - first) }
    public var endHostTime: HostTime? { spans.last.map { $0.host + UInt64($0.end - $0.first) * 62_500 } }
    public var oldestHostTime: HostTime? { spans.first.map { $0.host + UInt64(max(first, $0.first) - $0.first) * 62_500 } }
    public func beginPress(floor: HostTime) { self.floor = floor }

    public func append(_ input: [Float], at host: HostTime) {
        guard !input.isEmpty else { return }
        let begin = written
        for value in input {
            samples[Int(written % Int64(capacity))] = value
            written += 1
        }
        first = max(first, written - Int64(capacity))
        spans.append(Span(first: begin, end: written, host: host))
        spans.removeAll { $0.end <= first }
    }

    public func read(from requested: HostTime, to end: HostTime) -> PCMClip16k? {
        read(spans, from: requested, to: end)
    }

    /// Preview only consumes newly appended samples, even if clock jitter overlaps adjacent anchors.
    public func readLatestBlock() -> PCMClip16k? {
        guard let span = spans.last else { return nil }
        return read([span], from: floor, to: span.host + UInt64(span.end - span.first) * 62_500)
    }

    private func read(_ selected: [Span], from requested: HostTime, to end: HostTime) -> PCMClip16k? {
        let start = max(requested, floor)
        guard end > start else { return nil }
        var out: [Float] = [], clipStart: HostTime?, clipEnd: HostTime = 0
        for span in selected where end > span.host {
            let offset = start > span.host ? start - span.host : 0
            let lo = max(first, span.first + Int64(offset / 62_500 + (offset % 62_500 == 0 ? 0 : 1)))
            let hi = min(span.end, span.first + Int64((end - span.host) / 62_500))
            guard hi > lo else { continue }
            if clipStart == nil { clipStart = span.host + UInt64(lo - span.first) * 62_500 }
            for i in lo..<hi { out.append(samples[Int(i % Int64(capacity))]) }
            clipEnd = span.host + UInt64(hi - span.first) * 62_500
        }
        guard let clipStart, !out.isEmpty else { return nil }
        return PCMClip16k(samples: out, start: clipStart, end: clipEnd)
    }

    /// Erase actual sample memory, not only metadata. Idle capture retains at most one second.
    public func clearIdle(before host: HostTime) {
        for span in spans {
            guard host > span.host else { break }
            let offset = host - span.host
            let through = min(span.end, span.first + Int64(offset / 62_500 + (offset % 62_500 == 0 ? 0 : 1)))
            while first < through { samples[Int(first % Int64(capacity))] = 0; first += 1 }
            if through < span.end { break }
        }
        spans.removeAll { $0.end <= first }
    }
    public func reset() {
        samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        first = 0; written = 0; spans.removeAll()
    }
}
