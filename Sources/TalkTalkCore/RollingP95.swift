import Foundation

/// Bounded latency history, in milliseconds. Each owner serializes access; no clock, task or
/// sampling loop is hidden here. Empty history lets the caller use its existing policy value.
public struct RollingP95: Sendable {
    public let capacity: Int
    private var samples: [Double] = []
    private var cursor = 0
    public init(capacity: Int = 64) {
        precondition(capacity > 0)
        self.capacity = capacity
    }
    public mutating func record(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        if samples.count < capacity { samples.append(milliseconds) }
        else { samples[cursor] = milliseconds }
        cursor = (cursor + 1) % capacity
    }
    public var count: Int { samples.count }
    /// Nearest-rank p95, including short histories (one measurement returns that value).
    public var value: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.sorted()[Int(ceil(Double(samples.count) * 0.95)) - 1]
    }
}
