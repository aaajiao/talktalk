import CoreAudio
import Foundation
import TalkTalkDriverSupport
import TalkTalkEngineHost

// m2 driver: `--bench driver <op> --out <file>` (dev build). The real product code paths of
// "设置 › 安装与维护 › 虚拟麦克风" without the window (§8.4, §11):
//
//   status                         DriverInstallation.check(), the three devices, 'ttdg' summary
//   install | uninstall | restart-audio
//                                  DriverInstaller: pre-check, staging + manifest check, ONE
//                                  administrator prompt (the user types the password; Claude
//                                  never does), wait for the devices, driver.json. install then
//                                  runs the driver self-test like the settings row does.
//   ttmm [0|1]                     read / write the meeting-mode switch as this app (an accepted
//                                  Feed client), with the Mic's CanBeDefaultDevice before / after
//
// install / uninstall / restart-audio restart coreaudiod (audio stops ~1–2 s): ask first. The
// self-test after install reads Test Mic (microphone access), so launch through LaunchServices:
//   open -W -n -a build/TalkTalk-Dev.app --args --bench driver install --out <file>

@MainActor func runBenchDriver() -> Never {
    #if TALKTALK_DEV
    let op = arguments.count > 2 ? arguments[2] : "status"
    let out = argumentValue("--out")
    Task { @MainActor in
        let result = await benchDriver(op: op)
        writeResult(result, to: out)
        exit(result["ok"] as? Bool == true ? 0 : 1)
    }
    dispatchMain()   // DriverInstaller and NSAppleScript need the main actor; nothing blocks it here
    #else
    fail("--bench driver exists only in the dev build")
    #endif
}

#if TALKTALK_DEV
@MainActor private func benchDriver(op: String) async -> [String: Any] {
    let resources = DriverResources.inBundle()
    let hal = CoreAudioDriverHAL()
    let installer = DriverInstaller(resources: resources, hal: hal,
                                    preflightInputs: { DriverPreflight.Inputs.current(meetingModeOn: false, hal: hal) })
    var r: [String: Any] = ["op": op, "before": driverStatus(installer)]
    let clock = ContinuousClock()
    let t0 = clock.now
    switch op {
    case "status":
        r["ok"] = true
    case "install", "uninstall", "restart-audio":
        let phase: DriverInstaller.Phase
        switch op {
        case "install": phase = await installer.install()
        case "uninstall": phase = await installer.uninstall()
        default: phase = await installer.restartAudio()
        }
        r["phase"] = "\(phase)"
        r["seconds"] = seconds(clock.now - t0)
        r["messages"] = installer.messages
        if case .blocked(let pre) = phase { r["blockers"] = pre.blockers.map(\.text) }
        let finished: Bool
        if case .finished = phase { finished = true } else { finished = false }
        if op == "install", case .finished(.installed) = phase {
            let st = await driverSelfTest(includeMeetingPath: true)   // the install path (§8.4)
            r["selfTest"] = (try? JSONSerialization.jsonObject(with: Data(st.jsonLine().utf8))) ?? st.jsonLine()
            r["ok"] = st.ok
        } else {
            r["ok"] = finished
        }
    case "ttmm":
        let want = arguments.count > 3 ? Int(arguments[3]) : nil
        r["micCanBeDefaultBefore"] = hal.device(uid: DriverIdentity.micUID)?.canBeDefault ?? NSNull()
        r["valueBefore"] = hal.meetingMode().map { $0 ? 1 : 0 } ?? NSNull()
        if let want {
            let st = hal.setMeetingMode(want != 0)
            r["setStatus"] = Int(st)
            try? await Task.sleep(for: .milliseconds(50))
        }
        r["value"] = hal.meetingMode().map { $0 ? 1 : 0 } ?? NSNull()
        r["micCanBeDefault"] = hal.device(uid: DriverIdentity.micUID)?.canBeDefault ?? NSNull()
        r["pid"] = Int(getpid())
        r["diagTtmmLastPID"] = hal.diagnostics()?.ttmmLastPID ?? NSNull()
        r["ok"] = want == nil || (r["setStatus"] as? Int) == 0
    default:
        return ["ok": false, "error": "usage: --bench driver status|install|uninstall|restart-audio|ttmm [0|1] --out f"]
    }
    r["after"] = driverStatus(installer)
    return r
}

@MainActor private func driverStatus(_ installer: DriverInstaller) -> [String: Any] {
    let (state, record) = installer.installation.check()
    let hal = installer.hal
    func dev(_ uid: String) -> Any {
        guard let d = hal.device(uid: uid) else { return NSNull() }
        return ["listed": d.inDeviceList, "hidden": d.isHidden, "canBeDefault": d.canBeDefault,
                "in": d.inputChannels, "out": d.outputChannels, "running": d.isRunningSomewhere] as [String: Any]
    }
    let diag = hal.diagnostics()
    return [
        "state": "\(state)",
        "bundled": (try? installer.resources?.manifest().version) ?? NSNull(),
        "loaded": hal.loadedVersion() ?? NSNull(),
        "record": record.map { ["version": $0.version, "selfTestPassed": $0.selfTest?.passed ?? NSNull()] as [String: Any] }
            ?? NSNull(),
        "feed": dev(DriverIdentity.feedUID), "mic": dev(DriverIdentity.micUID), "testMic": dev(DriverIdentity.testMicUID),
        "defaultInput": hal.defaultInputUID() ?? NSNull(),
        "meetingMode": hal.meetingMode().map { $0 ? 1 : 0 } ?? NSNull(),
        "micUsers": diag?.micUsers.map { $0.bundleID ?? "pid \($0.pid)" } ?? [],
        "feedClients": diag?.feedClients ?? NSNull(),
    ]
}

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
#endif
