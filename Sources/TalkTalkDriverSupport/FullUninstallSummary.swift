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
    public var headline: String
    /// The blocker's or the failure's own text, unchanged (nil when the run did not stop on one).
    public var reason: String?
    /// What was removed or changed, in order (the default input comes first when it was restored).
    public var done: [String]
    /// What is still there or did not work, one entry each.
    public var notRemoved: [String]

    public init(outcome: Outcome, headline: String, reason: String? = nil, done: [String] = [], notRemoved: [String] = []) {
        self.outcome = outcome
        self.headline = headline
        self.reason = reason
        self.done = done
        self.notRemoved = notRemoved
    }

    /// nil while nothing has run or a run is in progress. `report` is `FullUninstaller.lastReport`.
    public init?(phase: FullUninstaller.Phase, report: FullUninstaller.Report) {
        let quit = "最后请退出 TalkTalk，把它拖进废纸篓。"
        let before = report.removed.isEmpty ? "什么都没删。" : "停下之前已经做了下面这些，其余什么都没删。"
        switch phase {
        case .idle, .running:
            return nil
        case .finished(let r):
            if r.problems.isEmpty {
                self.init(outcome: .complete, headline: "完全卸载完成。" + quit, done: r.removed)
            } else {
                self.init(outcome: .incomplete,
                          headline: "完全卸载做完了，但有 \(r.problems.count) 项没有删除或没有做成，见下面。" + quit,
                          done: r.removed, notRemoved: r.problems)
            }
        case .blocked(let why):
            self.init(outcome: .stopped, headline: "没有完全卸载，" + before, reason: why, done: report.removed)
        case .cancelled:
            self.init(outcome: .stopped, headline: "已取消，" + before, done: report.removed)
        case .failed(let step, let why):
            self.init(outcome: .stopped, headline: "完全卸载停在“\(step.title)”，" + before, reason: why,
                      done: report.removed)
        }
    }
}
