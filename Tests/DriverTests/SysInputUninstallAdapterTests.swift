import Testing
import TalkTalkAudio
@testable import TalkTalkDriverSupport

/// 完全卸载 step 1 through the app's SystemInputSwitcher (m2-driver wiring (c)).
@Suite struct SysInputUninstallAdapterTests {
    @Test func mapping() {
        #expect(SysInputRestore.outcome(.notOwner) == nil)   // restoreStale decides, never .noRecord
        #expect(SysInputRestore.outcome(.nothingToRestore) == .noRecord)
        #expect(SysInputRestore.outcome(.callOngoing) == .callOngoing)
        #expect(SysInputRestore.outcome(.restored(device: "Shure MV7")) == .restored("Shure MV7"))
        #expect(SysInputRestore.outcome(.failed("x")) == .failed("x"))
    }
}
