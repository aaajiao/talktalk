import TalkTalkAudio

extension MeetingMode {
    /// Phone belongs exclusively to its own scenario. These candidates also form the choice
    /// list when automatic selection is ambiguous, so a different scenario cannot offer Phone.
    func sourceCandidates(in candidates: [MeetingCandidate]) -> [MeetingCandidate] {
        candidates.filter { self == .phone ? $0.app.id == Self.phoneAppID : $0.app.id != Self.phoneAppID }
    }

    /// An idle Phone process is enough to prepare translation before dialing. The phone
    /// scenario never inherits another scenario's app choice or falls back to a different app.
    func source(in candidates: [MeetingCandidate], choice: String?, preferred: String?) -> MeetingCandidate? {
        let candidates = sourceCandidates(in: candidates)
        if self == .phone { return candidates.first }
        if let choice { return candidates.first { $0.app.id == choice } }
        if self == .captions {
            let playing = candidates.filter(\.isRunningOutput)
            return playing.first(where: { $0.app.id == preferred }) ?? (playing.count == 1 ? playing[0] : nil)
                ?? (candidates.count == 1 ? candidates[0] : nil)
        }
        return MeetingSourceResolver.defaultSource(candidates, preferred: preferred)
            ?? (candidates.count == 1 ? candidates[0] : nil)
    }
}
