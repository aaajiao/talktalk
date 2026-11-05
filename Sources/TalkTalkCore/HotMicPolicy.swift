/// A cold press or passthrough preparation may separately request capture; this controls idle capture only.
public enum HotMicPolicy {
    public static func shouldOpen(meetingActive: Bool, enabled: Bool, guardState: MeetingMicGuardPlan.State) -> Bool {
        meetingActive && enabled && guardState.verified
    }
}
