import CAudioCore
import CoreAudio
import Foundation
import TalkTalkAudio
import TalkTalkCore

// rt-core phase 2: `--bench feed [--seconds S] --out <file>` (dev build). FeedOutput on the real
// TalkTalk Feed as this app:
//  1. how long after this process's first Core Audio call TalkTalk Mic is in the device list (the
//     driver lists the Mic while an accepted Feed client exists, and the HAL adds this process as
//     a client when it first uses Core Audio, not when an IOProc starts: §8.3);
//  2. attach, S seconds (default 2) of IO with nothing written to ringO (zeros on channel 1), the
//     IOProc counters (the IO buffer must read back 480 frames), detach.
// The Feed accepts only talktalk's bundle ids, so launch it through LaunchServices:
//   open -W -n -a build/TalkTalk-Dev.app --args --bench feed --out <file>
// It never writes 'ttmm' or the default input (`--bench driver ttmm` does 'ttmm'). Numbers only.

func runBenchFeed() -> Never {
    #if TALKTALK_DEV
    let asked = Double(argumentValue("--seconds") ?? "") ?? 2
    let seconds = asked.isFinite ? min(max(asked, 0.5), 60) : 2
    Task {
        let result = await benchFeed(seconds: seconds)
        writeResult(result, to: argumentValue("--out"))
        exit(result["ok"] as? Bool == true ? 0 : 1)
    }
    dispatchMain()
    #else
    fail("--bench feed exists only in the dev build")
    #endif
}

#if TALKTALK_DEV
private final class Interruptions: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ i: PassthroughSystemEvent) { lock.withLock { items.append("\(i)") } }
    var all: [String] { lock.withLock { items } }
}

private func benchFeed(seconds: Double) async -> [String: Any] {
    var r: [String: Any] = ["seconds": seconds]
    let micListed = { InputDeviceCatalog.device(uid: DriverPins.micUID) != nil }

    // 1. The first Core Audio call of this process is the first poll below.
    let t0 = HostClock.now()
    let listedAtFirstCall = micListed()
    r["firstCoreAudioCallMs"] = HostClock.ms(t0, to: HostClock.now())
    var micMs: Int? = listedAtFirstCall ? 0 : nil
    while micMs == nil && HostClock.ms(t0, to: HostClock.now()) < 2000 {
        usleep(5_000)
        if micListed() { micMs = HostClock.ms(t0, to: HostClock.now()) }
    }
    r["micListedAtFirstCall"] = listedAtFirstCall
    r["micListedAfterFirstCoreAudioCallMs"] = micMs ?? NSNull()

    // 2. Attach and run.
    let profile: PolicyProfile
    do { profile = try PolicyProfile.loadDefault() } catch {
        r["ok"] = false; r["error"] = "PolicyProfile: \(error)"; return r
    }
    let output: SpeakOutput
    do { output = try SpeakOutput(profile: profile) } catch {
        r["ok"] = false; r["error"] = "\(error)"; return r
    }
    let feed = output.feed
    let interruptions = Interruptions()
    output.setSystemEventSink { event, _ in if event != .meetingModeEnded { interruptions.add(event) } }
    let t1 = HostClock.now()
    do { _ = try await output.beginSession(config: .init(profile)) } catch {
        r["ok"] = false; r["attachError"] = "\(error)"; await output.close(); return r
    }
    guard output.isFeedAttached else {
        r["ok"] = false; r["attachError"] = output.lastFailure ?? "not attached"
        await output.close(); return r
    }
    r["attachMs"] = HostClock.ms(t1, to: HostClock.now())

    let runStart = feed.stats
    usleep(useconds_t(seconds * 1_000_000))
    let s = feed.stats
    let frames = s.frames - runStart.frames, callbacks = s.callbacks - runStart.callbacks
    r["io"] = ["callbacks": callbacks, "frames": frames, "bufferFrames": s.bufferFrames,
               "framesPerCallback": callbacks > 0 ? Double(frames) / Double(callbacks) : 0,
               "framesVsWallClock": Double(frames) / (seconds * FeedOutput.sampleRate),
               "missingBuffers": s.missingBuffers, "mixedCycles": s.mixedCycles, "outUnderruns": s.outUnderruns,
               "ringOAudioFrames": s.ringOAudioFrames, "ringPAudioFrames": s.ringPAudioFrames,
               "mode": "\(s.mode)", "resumeFrames": s.resumeFrames, "isChannel1Busy": feed.isChannel1Busy] as [String: Any]
    r["events"] = ["count": output.events.pushed, "dropped": output.events.dropped] as [String: Any]
    r["micListedWhileAttached"] = micListed()

    await output.endSession()
    await output.close()
    r["attachedAfterDetach"] = feed.isAttached
    r["interruptions"] = interruptions.all
    r["ok"] = micMs != nil && callbacks > 0 && s.bufferFrames == TT_FEED_IO_BUFFER_FRAMES && s.missingBuffers == 0
        && s.mixedCycles == 0 && !feed.isAttached && interruptions.all.isEmpty
    return r
}
#endif
