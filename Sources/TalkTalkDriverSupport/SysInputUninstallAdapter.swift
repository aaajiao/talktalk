import TalkTalkAudio

/// "完全卸载" step 1 through the running app's `SystemInputSwitcher` (m2-driver wiring (b)–(d)).
///
///     DriverComponentModel.forCurrentApp(
///         isMeetingModeOn: { switcher.isMeetingModeOn },
///         ..., restoreWithSwitcher: SysInputRestore.withSwitcher(switcher))
extension SysInputRestore {
    @MainActor
    public static func withSwitcher(_ switcher: SystemInputSwitcher)
        -> @MainActor @Sendable () -> FullUninstaller.RestoreOutcome? {
        { [weak switcher] in
            guard let switcher else { return nil }
            return outcome(switcher.restoreForUninstall())
        }
    }

    /// `.notOwner` is nil: not this app's record, `restoreStale` decides (another TalkTalk, a
    /// stale record, none). Never `.noRecord`, which would skip that check (wiring (c)).
    public static func outcome(_ r: SystemInputSwitcher.UninstallRestore) -> FullUninstaller.RestoreOutcome? {
        switch r {
        case .notOwner: nil
        case .nothingToRestore: .noRecord
        case .callOngoing: .callOngoing
        case let .restored(device): .restored(device)
        case let .failed(why): .failed(why)
        }
    }
}
