/// Pure presentation mapping. Audio requests stay separate and can only reach MonitorOutput.
public extension PassthroughNotice {
    var hudEvent: HUDModel.PassthroughEvent? {
        switch self {
        case .startMic, .playOpenCue, .playCloseCue: nil
        case .waitingForClause: .waitingForClause
        case .opened: .opened
        case let .countdown(seconds): .countdown(secondsLeft: seconds)
        case let .closed(_, reason, _): .closed(reason: reason.hudText)
        case let .refused(reason): .refused(reason: reason.hudText)
        case .cancelled: .cancelled
        }
    }
}
