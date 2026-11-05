import Foundation

/// The enrollment flow of ARCHITECTURE.md §9.2 as a pure state machine. The controller
/// (`EnrollmentController`) performs the side effects each phase implies; this type only decides
/// which transitions are legal, so the flow can be tested without audio.
///
///     idle ──start──▶ measuringNoise ──noiseMeasured──▶ countdown(3) ─tick▶ countdown(2) ─tick▶
///     countdown(1) ─tick▶ recording ──stopped──▶ analyzing ──analyzed──▶ review
///     review ──save (canSave)──▶ saving ──saved──▶ saved                     (no engine)
///     review ──audition (canSave)──▶ auditioning ──auditioned──▶ auditionReview  (engine, §9.2 steps 6–7)
///     auditioning ──auditionSkipped──▶ saving    (engine error: saved with "pending_engine", §9.3)
///     auditionReview ──save (passed)──▶ saving;  auditionReview ──retake──▶ measuringNoise
///     review ──retake──▶ measuringNoise          (failed / saved ──start──▶ measuringNoise)
///     any active phase ──interrupted / failed──▶ failed;  any ──cancel──▶ idle
public struct VoiceEnrollment: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case measuringNoise
        case countdown(Int)
        case recording
        case analyzing
        case review(EnrollmentReport)
        case auditioning
        case auditionReview(AuditionResult.Summary)
        case saving
        case saved
        case failed(String)

        /// Phases in which the microphone is open.
        public var capturing: Bool {
            switch self {
            case .measuringNoise, .countdown, .recording: true
            default: false
            }
        }

        public var name: String {
            switch self {
            case .idle: "idle"
            case .measuringNoise: "measuring_noise"
            case .countdown: "countdown"
            case .recording: "recording"
            case .analyzing: "analyzing"
            case .review: "review"
            case .auditioning: "auditioning"
            case .auditionReview: "audition_review"
            case .saving: "saving"
            case .saved: "saved"
            case .failed: "failed"
            }
        }
    }

    public enum Event: Sendable, Equatable {
        case start
        case noiseMeasured
        case tick
        case stopped
        case analyzed(EnrollmentReport)
        case retake
        case save
        case audition
        case auditioned(AuditionResult.Summary)
        case auditionSkipped
        case saved
        case failed(String)
        case cancel
    }

    public static let countdownFrom = 3
    public static let noiseSeconds = 1.5
    public static let maxRecordingSeconds = 15.0
    public static let autoStopSilenceSeconds = 1.2

    public private(set) var phase: Phase = .idle
    /// Takes recorded in this session (shown as "第 n 次").
    public private(set) var takes = 0

    public init() {}

    /// Applies `event`; returns false (and leaves the phase unchanged) if it is not legal now.
    @discardableResult
    public mutating func send(_ event: Event) -> Bool {
        guard let next = transition(phase, event) else { return false }
        if case .recording = next, phase != .recording { takes += 1 }
        phase = next
        return true
    }

    private func transition(_ p: Phase, _ e: Event) -> Phase? {
        switch (p, e) {
        case (.idle, .start), (.failed, .start), (.saved, .start), (.review, .retake), (.auditionReview, .retake):
            return .measuringNoise
        case (.measuringNoise, .noiseMeasured):
            return .countdown(Self.countdownFrom)
        case let (.countdown(n), .tick):
            return n > 1 ? .countdown(n - 1) : .recording
        case (.recording, .stopped):
            return .analyzing
        case let (.analyzing, .analyzed(report)):
            return .review(report)
        case let (.review(report), .save):
            return report.canSave ? .saving : nil
        case let (.review(report), .audition):
            return report.canSave ? .auditioning : nil
        case let (.auditioning, .auditioned(summary)):
            return .auditionReview(summary)
        case (.auditioning, .auditionSkipped):
            return .saving
        case let (.auditionReview(summary), .save):
            return summary.passed ? .saving : nil
        case (.saving, .saved):
            return .saved
        case let (.measuringNoise, .failed(m)), let (.countdown, .failed(m)), let (.recording, .failed(m)),
             let (.analyzing, .failed(m)), let (.saving, .failed(m)), let (.idle, .failed(m)),
             let (.auditioning, .failed(m)):
            return .failed(m)
        case (_, .cancel):
            return .idle
        default:
            return nil
        }
    }
}
