// l10n: zh-Hans (scripts/check-strings.sh)
import TalkTalkCore
import Foundation

/// What the 完全卸载 row shows once a run has ended (§8.4). It shows the facts as they are:
///  - what was not removed (or not done) is listed one entry per line;
///  - a refusal's or a failure's reason is shown exactly as it came;
///  - what was already done before a run stopped is named. Step 1 may have restored the default
///    input before the driver step refuses.
public struct FullUninstallSummary: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Every step ran and nothing is left over.
        case complete
        /// Every step ran; `notRemoved` lists what is still there or failed.
        case incomplete
        /// The run stopped before the end (blocked, cancelled, failed).
        case stopped
    }

    public var outcome: Outcome
    /// The full sentence (with what to do next): the result row's help and VoiceOver hint.
    public var headline: String
    /// The result row's shortest words (settings visual system §7.5): "已删除 N 项" when every step
    /// ran, else what stopped the run ("已取消", "停在“<步骤>”", or the blocker's first clause).
    public var short: String
    /// The run stopped on a failure, not on a refusal or a cancel.
    public var failed: Bool
    /// The blocker's or the failure's own text, unchanged (nil when the run did not stop on one).
    public var reason: String?
    /// What was removed or changed, in order (the default input comes first when it was restored).
    public var done: [String]
    /// What is still there or did not work, one entry each.
    public var notRemoved: [String]

    public init(outcome: Outcome, headline: String, short: String? = nil, failed: Bool = false, reason: String? = nil,
                done: [String] = [], notRemoved: [String] = []) {
        self.outcome = outcome
        self.headline = headline
        self.short = short ?? headline
        self.failed = failed
        self.reason = reason
        self.done = done
        self.notRemoved = notRemoved
    }

    /// nil while nothing has run or a run is in progress. `report` is `FullUninstaller.lastReport`.
    public init?(phase: FullUninstaller.Phase, report: FullUninstaller.Report) {
        let quit = String(appLocalized: "最后请退出 TalkTalk，把它拖进废纸篓。")
        let before = report.removed.isEmpty ? String(appLocalized: "什么都没删。")
            : String(appLocalized: "停下之前已经做了下面这些，其余什么都没删。")
        switch phase {
        case .idle, .running:
            return nil
        case .finished(let r):
            let removed = String(appLocalized: "已删除 \(r.removed.count) 项")
            if r.problems.isEmpty {
                self.init(outcome: .complete, headline: String(appLocalized: "完全卸载完成。") + quit, short: removed, done: r.removed)
            } else {
                self.init(outcome: .incomplete,
                          headline: String(appLocalized: "完全卸载做完了，但有 \(r.problems.count) 项没有删除或没有做成，见下面。") + quit,
                          short: removed, done: r.removed, notRemoved: r.problems)
            }
        case .blocked(let why):
            self.init(outcome: .stopped, headline: String(appLocalized: "没有完全卸载，") + before,
                      short: Self.firstClause(why) ?? String(appLocalized: "未卸载"),
                      reason: why, done: report.removed)
        case .cancelled:
            self.init(outcome: .stopped, headline: String(appLocalized: "已取消，") + before, short: String(appLocalized: "已取消"),
                      done: report.removed)
        case .failed(let step, let why):
            self.init(outcome: .stopped, headline: String(appLocalized: "完全卸载停在“\(step.title)”，") + before,
                      short: String(appLocalized: "停在“\(step.title)”"), failed: true, reason: why, done: report.removed)
        }
    }

    /// A blocker's cause before its advice ("通话还在进行：先离开会议…" → "通话还在进行").
    static func firstClause(_ text: String) -> String? {
        let head = text.split(whereSeparator: { "：。；".contains($0) }).first.map(String.init)? // l10n-ignore
            .trimmingCharacters(in: .whitespaces)
        return head?.isEmpty == false ? head : nil
    }
}
