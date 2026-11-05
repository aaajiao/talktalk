import Foundation
import TalkTalkApple
import TalkTalkAudio
import TalkTalkCore

// `--bench tap` (M1-T9, LISTEN half), dev build only. Run it during a real call:
//   open -W -n -a build/TalkTalk-Dev.app --args --bench tap [--app <bundle id>] [--seconds 120] [--rebuilds 5] --out <file>
// Reports which process objects belong to which app (owner attribution), the TCC probe verdict,
// then taps the meeting app (include tap, `.unmuted`) and records per second: non-zero or not,
// peak level, IsRunningInput/Output — so lobby / mute / DTX zeros are counted without being
// read as a TCC verdict. Also the tap aggregate's drift (no sub-device) and rebuild times.
// Numbers and bundle ids only; no audio is written anywhere.

@MainActor func runBenchTap() -> Never {
    #if TALKTALK_DEV
    runAppleBench { records in
        let seconds = argumentValue("--seconds").flatMap { Int($0) } ?? 120
        let rebuilds = argumentValue("--rebuilds").flatMap { Int($0) } ?? 5
        return try await TapBench.run(app: argumentValue("--app"), seconds: seconds, rebuilds: rebuilds, records: records)
    }
    #else
    fail("--bench tap exists only in the dev build (TalkTalk-Dev.app)")
    #endif
}

#if TALKTALK_DEV
enum TapBench {
    final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var nonZero = false, peak: Float = 0, chunks = 0
        private var first: (frame: Int64, host: HostTime)?
        private var last: (frame: Int64, host: HostTime)?
        func add(_ c: MeetingTap.Chunk) {
            var p: Float = 0
            for s in c.samples { p = max(p, abs(s)) }
            lock.withLock {
                chunks += 1
                if p > 0 { nonZero = true }
                peak = max(peak, p)
                if first == nil { first = (c.startFrame, c.hostTime) }
                last = (c.startFrame + Int64(c.samples.count), c.hostTime &+ HostTime(Double(c.samples.count) / 16_000 * 1e9))
            }
        }
        /// Per-second snapshot, then reset the level fields.
        func take() -> (nonZero: Bool, peakDbfs: Double, chunks: Int) {
            lock.withLock {
                defer { nonZero = false; peak = 0; chunks = 0 }
                return (nonZero, peak > 0 ? (20 * log10(Double(peak)) * 10).rounded() / 10 : -200, chunks)
            }
        }
        /// (16 kHz frames / host seconds − 1) in ppm over the whole run.
        var driftPPM: Double? {
            lock.withLock {
                guard let a = first, let b = last, b.host > a.host else { return nil }
                let hostS = Double(b.host - a.host) / 1e9
                guard hostS > 10 else { return nil }
                return ((Double(b.frame - a.frame) / 16_000) / hostS - 1) * 1e6
            }
        }
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var gaps = 0, restarts = 0, dropped = 0
        func add(_ e: MeetingTap.Event) {
            lock.withLock {
                switch e {
                case .gapFilled: gaps += 1
                case .restartNeeded: restarts += 1
                case let .droppedStamps(n): dropped += n
                }
            }
        }
        var summary: [String: Int] { lock.withLock { ["gaps_filled": gaps, "restarts": restarts, "dropped_stamps": dropped] } }
    }

    static func run(app: String?, seconds: Int, rebuilds: Int, records: JSONLWriter) async throws -> [String: Any] {
        var out: [String: Any] = ["op": "bench-tap", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                  "responsibility_spi": MeetingSourceResolver.responsibilityAvailable]
        let resolver = MeetingSourceResolver()
        let procs = try AudioProcessList.current()
        out["processes"] = procs.map { p -> [String: Any] in
            let owner = resolver.ownerBundleID(p)
            return ["pid": p.pid, "bundle_id": p.bundleID ?? NSNull(), "owner": owner ?? NSNull(),
                    "meeting_app": owner.flatMap(MeetingApp.named)?.name ?? NSNull(),
                    "in": p.isRunningInput, "out": p.isRunningOutput]
        }
        let candidates = resolver.candidates(procs)
        out["candidates"] = candidates.map { ["app": $0.app.id, "objects": $0.objectIDs.count, "in": $0.isRunningInput, "out": $0.isRunningOutput] as [String: Any] }
        let pick = app.flatMap { id in candidates.first { $0.app.id == id } }
            ?? MeetingSourceResolver.defaultSource(candidates) ?? (candidates.count == 1 ? candidates[0] : nil)
        guard let source = pick else {
            out["error"] = candidates.isEmpty ? "no meeting app has a process object" : "several meeting apps: pass --app <bundle id>"
            return out
        }
        out["app"] = source.app.id

        let probe = TCCProbe.run()
        out["tcc_probe"] = ["verdict": probe.verdict.rawValue, "reason": probe.reason,
                            "tap_start_ms": probe.tapStartMs.map { $0 as Any } ?? NSNull(),
                            "process_object_ms": probe.processObjectMs.map { $0 as Any } ?? NSNull(),
                            "chunks": probe.chunks] as [String: Any]

        // Main run.
        let stats = Stats(), events = Events()
        var tap = MeetingTap(processes: source.objectIDs, muteBehavior: .unmuted)
        let t0 = HostClock.now()
        try tap.start(onChunk: { stats.add($0) }, onEvent: { events.add($0) })
        out["tap_start_ms"] = HostClock.ms(t0, to: HostClock.now())
        out["tap_format"] = ["rate": tap.tapSampleRate, "channels": Int(tap.tapChannels)]
        var nonZeroS = 0, zeroWhileOutS = 0, runs: [Int] = [], run = 0, outS = 0, inS = 0
        var watchdog = TapWatchdog()
        var wouldRebuild = 0
        var processes = source.objectIDs
        for s in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            let snap = stats.take()
            let now = (try? resolver.currentCandidates())?.first { $0.app.id == source.app.id }
            let running = now?.isRunningOutput ?? false, input = now?.isRunningInput ?? false
            if let now, Set(now.objectIDs) != Set(processes) {
                processes = now.objectIDs
                try? tap.update(processes: processes)
                records.write("t9.processes", ["s": s, "objects": processes.count])
            }
            if running { outS += 1 }
            if input { inS += 1 }
            if snap.nonZero { nonZeroS += 1 }
            if running && !snap.nonZero { zeroWhileOutS += 1; run += 1 } else if run > 0 { runs.append(run); run = 0 }
            let nz = tap.lastNonZeroHostTime.map { HostClock.ms(t0, to: $0) }
            if case .rebuild = watchdog.observe(nowMs: HostClock.ms(t0, to: HostClock.now()), runningOutput: running, lastNonZeroMs: nz) {
                wouldRebuild += 1
            }
            records.write("t9.second", ["s": s, "nonzero": snap.nonZero, "peak_dbfs": snap.peakDbfs, "chunks": snap.chunks,
                                        "running_output": running, "running_input": input])
        }
        if run > 0 { runs.append(run) }
        out["seconds"] = seconds
        out["seconds_running_output"] = outS
        out["seconds_running_input"] = inS
        out["seconds_nonzero"] = nonZeroS
        out["seconds_zero_while_output"] = zeroWhileOutS
        out["zero_runs_while_output_s"] = benchDist(runs)
        out["watchdog_would_rebuild"] = wouldRebuild
        out["drift_ppm"] = stats.driftPPM.map { ($0 * 10).rounded() / 10 } ?? NSNull()
        out["tap_events"] = events.summary
        tap.stop()

        // Rebuild: stop, start a new tap, time to the first chunk (§14 T9: ≤ 300 ms).
        var ms: [Int] = []
        for _ in 0..<rebuilds {
            let first = Stats()
            let r0 = HostClock.now()
            tap = MeetingTap(processes: processes, muteBehavior: .unmuted)
            do { try tap.start(onChunk: { first.add($0) }) } catch { continue }
            var waited = 0
            while first.take().chunks == 0, waited < 2000 { try? await Task.sleep(for: .milliseconds(5)); waited += 5 }
            ms.append(HostClock.ms(r0, to: HostClock.now()))
            tap.stop()
            try? await Task.sleep(for: .milliseconds(300))
        }
        out["rebuild_to_first_chunk_ms"] = benchDist(ms)
        return out
    }
}
#endif
