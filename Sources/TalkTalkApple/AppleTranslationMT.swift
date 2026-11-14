import Foundation
import TalkTalkCore
import Translation

/// Apple Translation as an `MTEngine` (§4.1, §4.2): LISTEN drafts and the final-MT fallback
/// (all twelve zh/en/de/fr directions), and all nine SPEAK fallback directions. `.highFidelity` (26.4+; the
/// installed packs on this Mac, M0-T11). One warm session per direction. Language packs are
/// system-managed and never downloaded from here: a missing pack throws `.notInstalled`.
/// Glossary and history are not supported by the framework; `setContext` is a no-op and the
/// app's TargetTextGate / NumberGuard check the output as for every MT backend (§5.4).
@available(macOS 26.4, *)
public actor AppleTranslationMT: MTEngine {
    public enum Failure: Error, Sendable, Equatable { case notInstalled(String), empty }

    public nonisolated let id = EngineID(name: "apple-translation", revision: "highFidelity", placement: .systemService)

    /// TranslationSession is not Sendable; it is only ever used from tasks this actor starts.
    final class Box: @unchecked Sendable { let session: TranslationSession; init(_ s: TranslationSession) { session = s } }

    private var sessions: [MTSession: Box] = [:]
    private var inFlight: [JobID: Task<String, Error>] = [:]

    public init() {}

    static func language(_ l: Lang) -> Locale.Language {
        switch l {
        case .zh: Locale.Language(identifier: "zh-Hans")
        case .en: Locale.Language(identifier: "en")
        case .de: Locale.Language(identifier: "de")
        case .fr: Locale.Language(identifier: "fr")
        }
    }

    /// `installed`, `supported` (pack not downloaded) or `unsupported`.
    public static func availability(_ s: MTSession) async -> String {
        let d = s.direction
        switch await LanguageAvailability(preferredStrategy: .highFidelity).status(from: language(d.source), to: language(d.target)) {
        case .installed: return "installed"
        case .supported: return "supported"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }

    /// Creates and warms the direction's session (call at meeting start, off the hot path).
    public func prepare(_ s: MTSession) async throws {
        let box = try await session(for: s)
        try await Task { try await box.session.prepareTranslation() }.value
    }

    private func session(for s: MTSession) async throws -> Box {
        if let existing = sessions[s] { return existing }
        guard await Self.availability(s) == "installed" else { throw Failure.notInstalled(s.rawValue) }
        let d = s.direction
        let session = TranslationSession(installedSource: Self.language(d.source), target: Self.language(d.target),
                                         preferredStrategy: .highFidelity)
        let box = Box(session)
        sessions[s] = box
        return box
    }

    public func translate(_ r: MTRequest) async throws -> MTResult {
        let received = HostClock.now()
        let box = try await session(for: r.session)
        let text = r.text
        let task = Task { try await box.session.translate(text).targetText }
        inFlight[r.job] = task
        let started = HostClock.now()
        defer { inFlight[r.job] = nil }
        let out = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        let finished = HostClock.now()
        let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Failure.empty }
        return MTResult(text: clean, tokens: 0, reasoningTokens: 0, engine: id,
                        hedge: HedgeOutcome(fired: false, winner: .apple, reason: nil, ms: HostClock.ms(received, to: finished)),
                        timing: StageTiming(received: received, started: started, firstOutput: finished, finished: finished))
    }

    public func setContext(_ s: MTSession, glossary: [GlossaryEntry]) async throws {}

    public func cancel(_ job: JobID) async {
        inFlight[job]?.cancel()
        inFlight[job] = nil
    }
}
