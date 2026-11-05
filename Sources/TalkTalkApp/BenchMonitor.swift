import CoreAudio
import Foundation
import TalkTalkAudio
import TalkTalkCore

// rt-core phase 2: `--bench monitor [--seconds S] --out <file>` (dev build). MonitorOutput on the
// real default output, silent: attached with the `.cues` use and nothing played (ringO2 empty, no
// cue), S seconds (default 2), then detached. It shows on this machine's output what §3.4 asks:
//  - the input streams are off for our IOProc: `inputStreamsDisabled` (what MonitorOutput's read-back
//    confirmed) equals the device's input-stream count read here, independently;
//  - the device keeps its nominal rate during and after (a Bluetooth headset pulled into HFP drops
//    to 16/24 kHz), and the default output is unchanged;
//  - the IOProc runs at the wall clock; the route the classifier gives the device.
// Numbers and classes only: no device names or UIDs. No sound, no TCC, any build identity works:
//   open -W -n -a build/TalkTalk-Dev.app --args --bench monitor --out <file>

func runBenchMonitor() -> Never {
    #if TALKTALK_DEV
    let asked = Double(argumentValue("--seconds") ?? "") ?? 2
    let seconds = asked.isFinite ? min(max(asked, 0.5), 60) : 2
    let result = benchMonitor(seconds: seconds)
    writeResult(result, to: argumentValue("--out"))
    exit(result["ok"] as? Bool == true ? 0 : 1)
    #else
    fail("--bench monitor exists only in the dev build")
    #endif
}

#if TALKTALK_DEV
private final class MonitorChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ c: MonitorOutput.Change) { lock.withLock { items.append("\(c)") } }
    var all: [String] { lock.withLock { items } }
}

private func benchMonitor(seconds: Double) -> [String: Any] {
    var r: [String: Any] = ["seconds": seconds]
    guard let before = AudioDeviceCatalog.defaultOutput() else { r["ok"] = false; r["error"] = "no default output"; return r }
    r["rateBefore"] = before.nominalSampleRate
    r["inputChannels"] = before.inputChannels
    guard let inputStreams = defaultOutputInputStreams() else {
        r["ok"] = false; r["error"] = "input streams of the default output unreadable"; return r
    }
    r["inputStreams"] = inputStreams
    let profile: PolicyProfile
    do { profile = try PolicyProfile.loadDefault() } catch {
        r["ok"] = false; r["error"] = "PolicyProfile: \(error)"; return r
    }
    guard let ringO2 = RingO(maxLeadFrames: profile.speak.tts.ringOAheadMs * 48), let events = EventRing() else {
        r["ok"] = false; r["error"] = "rings"; return r
    }
    let changes = MonitorChanges()
    let monitor = MonitorOutput(ringO2: ringO2, events: events) { changes.add($0) }
    let t0 = HostClock.now()
    monitor.setUse(.cues, true)                      // queued: wait for the attach (or its failure)
    _ = waitFor(seconds: 5) { monitor.stats.callbacks > 0 }
    r["attachMs"] = HostClock.ms(t0, to: HostClock.now())
    let start = monitor.stats
    guard start.attached, let device = monitor.device else {
        r["ok"] = false; r["attachError"] = start.lastFailure ?? "not attached"; return r
    }
    r["transport"] = "\(device.transport)"
    r["route"] = "\(OutputRouteClassifier.classify(device, confirmedHeadphones: []))"
    r["cuesAudible"] = monitor.cuesAudible
    usleep(useconds_t(seconds * 1_000_000))
    let s = monitor.stats
    let during = AudioDeviceCatalog.defaultOutput()
    monitor.setUse(.cues, false)
    _ = waitFor(seconds: 5) { !monitor.isAttached }
    let after = AudioDeviceCatalog.defaultOutput()
    let frames = s.frames - start.frames, callbacks = s.callbacks - start.callbacks
    r["io"] = ["sampleRate": s.sampleRate, "bufferFrames": s.bufferFrames, "latencyFrames": s.latencyFrames,
               "inputStreamsDisabled": s.inputStreamsDisabled, "channelSlots": s.channelSlots, "cueGain": Double(s.cueGain),
               "callbacks": callbacks, "frames": frames,
               "framesVsWallClock": s.sampleRate > 0 ? Double(frames) / (seconds * s.sampleRate) : 0,
               "audioFrames": s.audioFrames, "cueFrames": s.cueFrames, "gain": Double(s.gain)] as [String: Any]
    r["rateDuring"] = during?.nominalSampleRate ?? 0
    r["rateAfter"] = after?.nominalSampleRate ?? 0
    r["defaultOutputUnchanged"] = during?.uid == before.uid && after?.uid == before.uid
    r["attachedAfterStop"] = monitor.isAttached
    r["changes"] = changes.all
    r["ok"] = callbacks > 0 && s.audioFrames == 0 && s.cueFrames == 0 && s.gain == 0
        && s.inputStreamsDisabled == inputStreams
        && during?.nominalSampleRate == before.nominalSampleRate && after?.nominalSampleRate == before.nominalSampleRate
        && r["defaultOutputUnchanged"] as? Bool == true && !monitor.isAttached
        && !changes.all.contains("serviceRestarted")
    return r
}

/// Polls `cond` every millisecond up to `seconds`.
private func waitFor(seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !cond() {
        if Date() > end { return false }
        usleep(1000)
    }
    return true
}

/// The default output's input streams (kAudioDevicePropertyStreams, input scope), read here and
/// not through MonitorOutput; nil when the HAL does not answer.
private func defaultOutputInputStreams() -> Int? {
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    var bytes: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr else { return nil }
    return Int(bytes) / MemoryLayout<AudioStreamID>.size
}
#endif
