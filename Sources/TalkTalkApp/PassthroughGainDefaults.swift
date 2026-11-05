import Foundation
import TalkTalkVoice

/// Calibrations survive app/engine restarts. Only the existing UID hash and bounded gain are stored.
final class PassthroughGainDefaults: PassthroughGainStore, @unchecked Sendable {
    static let changed = Notification.Name("TalkTalk.passthroughGainChanged")
    private static let key = "speak.passthrough.gains"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func gainDb(micUIDHash: String) -> Double? {
        lock.withLock {
            guard let db = defaults.dictionary(forKey: Self.key)?[micUIDHash] as? Double, db.isFinite else { return nil }
            return min(VoiceGains.passthroughRange.upperBound, max(VoiceGains.passthroughRange.lowerBound, db))
        }
    }

    func setGainDb(_ db: Double, micUIDHash: String) {
        guard db.isFinite else { return }
        lock.withLock {
            var values = defaults.dictionary(forKey: Self.key) ?? [:]
            values[micUIDHash] = min(VoiceGains.passthroughRange.upperBound, max(VoiceGains.passthroughRange.lowerBound, db))
            defaults.set(values, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func removeAll() {
        lock.withLock { defaults.removeObject(forKey: Self.key) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
