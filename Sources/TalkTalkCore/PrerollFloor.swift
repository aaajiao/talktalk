/// Privacy floor shared by every SPEAK clip and preview read (§3.2).
public enum PrerollFloor {
    public static func compute(keyDown: HostTime, prerollMs: Int, previousClipEnd: HostTime?, passthroughClosedAt: HostTime?) -> HostTime {
        let back = UInt64(max(0, prerollMs)) * 1_000_000
        return max(keyDown > back ? keyDown - back : 0, previousClipEnd ?? 0, passthroughClosedAt ?? 0)
    }
}
