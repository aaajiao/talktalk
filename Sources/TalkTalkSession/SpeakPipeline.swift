import Foundation
import TalkTalkAudio
import TalkTalkCore

/// One SPEAK session. Capture and playout workers never await this actor; they yield values.
/// Recognition stays serial while held commits translate concurrently and play in source order.
public actor SpeakPipeline: PassthroughPlayoutYielding {
    private struct Press {
        var audio: any SpeakPressAudio
        var released = false
        var releasedAt: HostTime?
        var releasing = false
        var captureFinished = false
        var held: [SpeakClip] = []
        var reader: Task<Void, Never>?
        var previewFloor: HostTime = 0
    }
    private struct Clause {
        var press: UInt64
        var mtJob: JobID
        var sourceOrder: UInt64
        var committedAt: HostTime
        var releasedAt: HostTime?
        var source = ""
        var target: String?
        var backend: HUDModel.MTSource = .openAI
        var ttsJob: JobID?
        var voice: HUDModel.Voice = .mine
        var speechS: Double
        var readyAt: HostTime = 0
        var mode: MTMode = .normal
        var summary = false
    }

    // Only the most recent press is retained for the HUD. Played clauses leave the audio
    // ledger, but their text must remain while later clauses of this same press finish.
    private struct DisplayClause {
        var order: UInt64
        var end: HostTime
        var provisional = ""
        var source: String?
        var target = ""
        var settled = false
    }
    private struct DisplayPress {
        var id: UInt64
        var clauses: [UInt64: DisplayClause] = [:]
        var preview = ""
        var captureFinished = false
        var warnedUnsubmitted = false
    }
    private var displayPress: DisplayPress?
    private var lastTranscript: SpeakTranscript?

    public nonisolated let queue: ClauseQueue
    private nonisolated let host: any SpeakPlayoutHost
    private let profile: PolicyProfile
    private let mic: any SpeakMicSource
    private let primaryASR: (any ClipASREngine)?
    private let fallbackASR: any ClipASREngine
    private let translator: any SpeakTranslator
    private let voice: @Sendable () -> SpeakVoiceSnapshot
    private let engine: any SpeakEngineControl
    private let echo: any SpeakEchoSink
    private let preview: SpeakPreview?
    private let speakerMode: @Sendable () -> Bool
    private let passthroughClosedAt: @Sendable () -> HostTime?
    private let captureFromKeyDown: Bool
    private let ttsFailureReason: @Sendable (any Error) -> ClauseLedger.Reason
    private let ui: @Sendable (SpeakUIEvent) -> Void
    private let log: EventLog
    private let jobs: JobIDSequence
    private let clock: @Sendable () -> HostTime
    private let acceptedChunk: @Sendable (TTSChunk) -> Void
    private let onSpoken: @Sendable (String, String, HostTime) -> Void
    private var heard: Set<UInt64> = []
    private var heardPresses: Set<UInt64> = []
    private let onCommit: @Sendable () -> Void
    private let onWorkChange: @Sendable (Bool) -> Void
    private let onDegradation: @Sendable (DegradationLadder.Tier) -> Void
    private let asrContext: @Sendable () -> String?
    private let source: Lang
    private let target: Lang
    private let session: MTSession
    private let gate: SpeakLanguageGate
    private var ledger: ClauseLedger
    private var ttsQueue: TTSQueue
    private var history = MTHistory()
    private var firstChunk = RollingP95()
    private var calibration = DurationCalibration()
    private var backlog: BacklogController
    private var backlogDecision: BacklogController.Decision
    private var degradation = DegradationLadder()
    private var latestRTF: Double?
    private var thermalSerious = false, lowPower = false
    /// Recognition context belongs to one recording turn; glossary hints may span turns.
    private var lastSource: (press: UInt64, text: String)?
    private var lastClipEnd: (press: UInt64, end: HostTime)?
    private var renderMembers: [UInt64: [UInt64]] = [:]
    private var renderVoice: [JobID: VoiceHandle] = [:]
    private var renderText: [JobID: String] = [:]
    private struct AnnouncementCache {
        var handle: VoiceHandle
        var gainDb: Double
        var chunks: [TTSChunk]
    }
    private var announcementText: String?
    private var announcementEnabled = false, announced = false, wantsAnnouncement = false
    private var announcementRequestedAt: HostTime?
    private var announcementCache: AnnouncementCache?
    private var announcementTask: Task<Void, Never>?
    private var announcementEngine: (any TTSEngine)?
    private var announcementJob: JobID?
    private var announcementClause: UInt64?
    private var announcementOutputJob: JobID?
    private var presses: [UInt64: Press] = [:]
    private var currentPress: UInt64?
    private var previewStart: Task<Void, Never>?
    private var clauses: [UInt64: Clause] = [:]
    private var order: [UInt64] = []
    private var processing: [UInt64: Task<Void, Never>] = [:]
    // Only recognition is serialized. Its successor can run while the previous clause is in MT.
    private var asrTasks: [UInt64: Task<ASRFinal, Error>] = [:]
    private var asrTail: Task<Void, Never>?
    private var renders: [JobID: Task<Void, Never>] = [:]
    private var renderEngines: [JobID: any TTSEngine] = [:]
    private var services: [Task<Void, Never>] = []
    private var eventContinuation: AsyncStream<[ClauseQueue.Event]>.Continuation?
    private var yielded: @Sendable (HostTime) -> Void = { _ in }
    private var epoch: UInt32
    private let voiceContextSession = UUID().uuidString
    private var previousClone: (context: String, key: String, job: JobID)?
    private var suspended = false
    private var ended = false
    private var waitingForEngine = false
    private var workBarriers = 0
    private var cancellingJobs: Set<JobID> = []
    private var reportedBusy = false
    private var playingOutput: [UInt64: JobID] = [:]
    private var reportedOutputPlaying = false
    private var reportedOutputPresses: Set<UInt64> = []
    public var commitWhileHeld = true
    public var isIdle: Bool {
        workBarriers == 0 && cancellingJobs.isEmpty && presses.isEmpty && asrTasks.isEmpty
            && processing.isEmpty && renders.isEmpty && order.isEmpty
            && !wantsAnnouncement && queue.clauseCount == 0 && queue.isAtBoundary
    }

    public init(profile: PolicyProfile, mic: any SpeakMicSource, playout: any SpeakPlayoutHost,
                queue: ClauseQueue, primaryASR: (any ClipASREngine)?, fallbackASR: any ClipASREngine,
                translator: any SpeakTranslator, voice: @escaping @Sendable () -> SpeakVoiceSnapshot,
                engine: any SpeakEngineControl, echo: any SpeakEchoSink,
                previewASR: (any StreamingASREngine)? = nil, source: Lang = .zh, target: Lang,
                jobs: JobIDSequence, log: EventLog,
                speakerMode: @escaping @Sendable () -> Bool,
                passthroughClosedAt: @escaping @Sendable () -> HostTime? = { nil },
                captureFromKeyDown: Bool = false,
                ttsFailureReason: @escaping @Sendable (any Error) -> ClauseLedger.Reason = { _ in .streamBroken },
                ui: @escaping @Sendable (SpeakUIEvent) -> Void,
                onCommit: @escaping @Sendable () -> Void = {},
                onWorkChange: @escaping @Sendable (Bool) -> Void = { _ in },
                onTTSChunk: @escaping @Sendable (TTSChunk) -> Void = { _ in },
                onSpoken: @escaping @Sendable (String, String, HostTime) -> Void = { _, _, _ in },
                onDegradation: @escaping @Sendable (DegradationLadder.Tier) -> Void = { _ in },
                asrContext: @escaping @Sendable () -> String? = { nil },
                commitWhileHeld: Bool = true,
                clock: @escaping @Sendable () -> HostTime = HostClock.now) {
        guard let session = MTSession.speak(source: source, target: target) else {
            preconditionFailure("Unsupported SPEAK language direction")
        }
        self.profile = profile; self.mic = mic; host = playout; self.queue = queue
        self.primaryASR = primaryASR; self.fallbackASR = fallbackASR; self.translator = translator
        self.voice = voice; self.engine = engine; self.echo = echo
        preview = previewASR.map { SpeakPreview(engine: $0, source: source) }
        self.source = source; self.target = target; self.session = session
        self.jobs = jobs; self.log = log; self.speakerMode = speakerMode
        self.passthroughClosedAt = passthroughClosedAt; self.ttsFailureReason = ttsFailureReason
        self.captureFromKeyDown = captureFromKeyDown
        self.commitWhileHeld = commitWhileHeld
        self.acceptedChunk = onTTSChunk; self.onSpoken = onSpoken
        self.ui = ui; self.onCommit = onCommit; self.onDegradation = onDegradation; self.asrContext = asrContext
        self.onWorkChange = onWorkChange
        var initialBacklog = BacklogController(config: profile.speak.backlog, language: target)
        backlogDecision = initialBacklog.update(renderedS: 0, unrenderedS: 0, inFlightSourceS: 0)
        backlog = initialBacklog
        self.clock = clock; gate = SpeakLanguageGate(profile.speak)
        ledger = ClauseLedger(sink: log); ttsQueue = TTSQueue(config: .init(profile.speak.tts))
        epoch = queue.currentEpoch
    }

    public func start() async {
        guard services.isEmpty, !ended else { return }
        reportedBusy = !isIdle
        onWorkChange(reportedBusy)
        let (events, continuation) = AsyncStream<[ClauseQueue.Event]>.makeStream()
        eventContinuation = continuation
        host.setEventSink { continuation.yield($0) }
        services = [Task { [weak self] in
            for await batch in events {
                guard !Task.isCancelled else { break }
                await self?.receive(batch)
            }
        }, Task { [weak self, engine] in
            for await status in engine.status {
                guard !Task.isCancelled else { break }
                await self?.engineChanged(status)
            }
        }, Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                await self?.tick()
            }
        }]
        services.append(Task { [translator, source, target] in await translator.prepare(source: source, targets: [target]) })
    }

    public func setYieldHandler(_ handler: @escaping @Sendable (HostTime) -> Void) { yielded = handler }

    private func reportWorkState() {
        let busy = !isIdle
        guard reportedBusy != busy else { return }
        reportedBusy = busy
        onWorkChange(busy)
    }

    private func reportOutputActivity() {
        // Announcements belong to no press; a clause's press is read before it is released.
        let presses = Set(playingOutput.keys.compactMap { clauses[$0]?.press })
        if presses != reportedOutputPresses {
            reportedOutputPresses = presses
            ui(.outputPresses(presses))
        }
        let playing = !playingOutput.isEmpty
        guard reportedOutputPlaying != playing else { return }
        reportedOutputPlaying = playing
        ui(.outputActivity(playing))
    }

    private func publishTranscript() {
        guard var display = displayPress else { return }
        let ordered = display.clauses.sorted { $0.value.order < $1.value.order }
        let entries = ordered.enumerated().map { index, entry in
            let row = entry.value
            return SubtitleRetentionPolicy.Entry(at: row.end,
                characters: (row.source ?? row.provisional).count + row.target.count
                    + (index == ordered.count - 1 ? display.preview.count : 0))
        }
        let retainedStart = SubtitleRetentionPolicy.meeting.retainedStartIndex(in: entries)
        if retainedStart > 0 {
            // Trim only reading history. Audio, pending recognition and MT keep their own ledger.
            for entry in ordered.prefix(retainedStart) { display.clauses[entry.key] = nil }
            displayPress = display
        }
        let rows = ordered.dropFirst(retainedStart).map { $0.value }
        let final = display.captureFinished && rows.allSatisfy(\.settled)
        var source: [String] = []
        if final {
            source = rows.compactMap(\.source)
        } else {
            var pendingSource = false
            for row in rows {
                if let text = row.source { source.append(text) }
                else if row.settled { continue }
                else {
                    // No word timestamps exist for the preview. Keep its complete provisional
                    // phrase until final ASR replaces it, rather than slicing text at an audio cut
                    // or duplicating it alongside the next segment's overlapping preview.
                    source.append(row.provisional); pendingSource = true; break
                }
            }
            if !pendingSource { source.append(display.preview) }
        }
        // A discarded clause has no final source, but is no longer waiting for ASR. Keep its
        // preview explicitly unsent without blocking later accepted text or the live preview.
        let unsubmitted = (rows.filter { $0.source == nil && $0.settled }.map(\.provisional)
            + (final ? [display.preview] : [])).filter { !$0.isEmpty }.joined(separator: "\n")
        let snapshot = SpeakTranscript(press: display.id,
            source: source.filter { !$0.isEmpty }.joined(separator: "\n"),
            target: rows.map(\.target).filter { !$0.isEmpty }.joined(separator: target == .zh ? "" : " "),
            isFinal: final, unsubmittedSource: unsubmitted)
        guard snapshot != lastTranscript else { return }
        lastTranscript = snapshot
        ui(.transcript(snapshot))
        if !unsubmitted.isEmpty, !display.warnedUnsubmitted {
            displayPress?.warnedUnsubmitted = true
            ui(.post(.segmentNotSent))
        }
    }

    private func finishDisplayCapture(_ id: UInt64) {
        guard displayPress?.id == id else { return }
        displayPress?.captureFinished = true
        publishTranscript()
    }

    public func handle(_ action: PushToTalkMachine.Action,
                       onHandled: @Sendable (Bool) -> Void = { _ in }) async {
        guard !ended, !suspended else { onHandled(!isIdle); return }
        workBarriers += 1; reportWorkState()
        defer {
            workBarriers -= 1; reportWorkState()
            // Acknowledge on this actor, so an idle read cannot arrive after newer work starts.
            onHandled(!isIdle)
        }
        switch action {
        case .began(let at): await begin(at: at)
        case .released(let at, let reason):
            guard let id = currentPress, var press = presses[id] else { return }
            if reason == .keyUp {
                press.releasedAt = at
                for clause in clauses.keys where clauses[clause]?.press == id { clauses[clause]?.releasedAt = at }
            }
            currentPress = nil; press.releasing = true; presses[id] = press
            // Capture receives the original key time immediately, even if stopping an opening
            // preview takes time. Clips arriving meanwhile stay held in this press.
            press.audio.release(at: at, reason: reason)
            await finishRelease(id)
        case .cancelled, .tapped:
            await cancelCurrentPress()
        case .doubleTapped:
            await cancelPending()
        }
    }

    private func begin(at: HostTime) async {
        if currentPress != nil { await cancelCurrentPress() }
        let earlierCaptures = presses.values.compactMap(\.reader)
        let id = jobs.next()
        displayPress = DisplayPress(id: id)
        publishTranscript()
        let closedAt = passthroughClosedAt()
        let captureFloor = captureFromKeyDown ? max(at, closedAt ?? at) : closedAt
        guard let audio = mic.beginPress(id: id, keyDownAt: at, passthroughClosedAt: captureFloor) else {
            finishDisplayCapture(id)
            ui(.post(.segmentNotSent)); return
        }
        currentPress = id; presses[id] = Press(audio: audio)
        queue.resumeNow(at: at)
        ui(.pushToTalk(.holding(level: 0, preview: "", committed: [], queued: queue.clauseCount)))
        presses[id]?.reader = Task { [weak self] in
            for await clip in audio.clips {
                guard !Task.isCancelled else { break }
                await self?.captured(clip, press: id)
            }
            await self?.captureEnded(id)
        }
        if let preview {
            previewStart = Task { [weak self] in
                // A previous press may still be capturing its 250 ms tail. Let its final ASR
                // finish before opening this press's preview (capture itself already runs).
                for reader in earlierCaptures { await reader.value }
                await self?.waitForASR()
                guard !Task.isCancelled else { return }
                await preview.start(frames: audio.preview) { [weak self] snapshot in
                    Task { await self?.previewChanged(press: id, snapshot: snapshot) }
                }
            }
        }
        await engine.pressActive(true)
        await translator.pressBegan()
    }

    private func previewChanged(press id: UInt64, snapshot: SpeakPreview.Snapshot) {
        guard currentPress == id, let press = presses[id], snapshot.from >= press.previewFloor,
              !suspended, !ended else { return }
        let boundary = SpeakPreviewBoundary(from: snapshot.from,
            fullyStable: snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == snapshot.stableText.trimmingCharacters(in: .whitespacesAndNewlines))
        press.audio.updatePreview(stableText: snapshot.stableText, through: snapshot.through, at: clock(),
                                  isFinal: snapshot.isFinal, boundary: boundary)
        if displayPress?.id == id, !snapshot.text.isEmpty {
            displayPress?.preview = snapshot.text
            publishTranscript()
        }
        ui(.pushToTalk(.holding(level: snapshot.level, preview: snapshot.text, committed: [], queued: queue.clauseCount)))
    }

    private func captured(_ clip: SpeakClip, press id: UInt64) async {
        guard let press = presses[id], !suspended, !ended else { return }
        if press.released || (commitWhileHeld && !press.releasing) {
            let held = currentPress == id
            if held { onCommit(); presses[id]?.previewFloor = clip.pcm.end }
            // Recognition does not wait for Apple's next preview to open.
            submit(clip, press: id, releasedAt: press.releasedAt)
            if held { await preview?.advance(to: clip.pcm.end) }
        } else { presses[id]?.held.append(clip) }
    }

    private func captureEnded(_ id: UInt64) async {
        workBarriers += 1
        defer { workBarriers -= 1; reportWorkState() }
        guard var press = presses[id] else { return }
        press.captureFinished = true
        presses[id] = press
        if press.released { presses[id] = nil; finishDisplayCapture(id); return }
        if press.releasing { return } // release is waiting for the preview to close
        // A format/device change ended capture while held. Finish at the last valid clip,
        // with the same preview-before-final-ASR ordering as a physical key release.
        presses[id]?.releasing = true
        if currentPress == id { currentPress = nil }
        await finishRelease(id)
    }

    private func finishRelease(_ id: UInt64) async {
        let token = epoch
        previewStart?.cancel(); previewStart = nil
        await preview?.stop()
        guard !ended, !suspended, token == epoch, var press = presses[id] else { return }
        press.released = true
        let held = press.held; press.held.removeAll()
        presses[id] = press.captureFinished ? nil : press
        for clip in held { submit(clip, press: id, releasedAt: press.releasedAt) }
        if press.captureFinished { finishDisplayCapture(id) }
        if currentPress == nil { await engine.pressActive(false) }
    }

    private func waitForASR() async { await asrTail?.value }

    private func cancelCurrentPress() async {
        guard let id = currentPress, let press = presses.removeValue(forKey: id) else { return }
        currentPress = nil; press.reader?.cancel(); press.audio.cancel()
        previewStart?.cancel(); previewStart = nil
        await preview?.stop()
        await engine.pressActive(false)
        finishDisplayCapture(id)
        ui(.pushToTalk(.idle))
    }

    private func submit(_ clip: SpeakClip, press: UInt64, releasedAt: HostTime? = nil) {
        guard clip.speechMs >= Int(profile.speak.release.commitRemainderMinSpeechS * 1000) else { return }
        if announcementEnabled, !announced { announced = true; requestAnnouncement() }
        let id = jobs.next(), mtJob = jobs.next(), token = epoch, committedAt = clock()
        clauses[id] = Clause(press: press, mtJob: mtJob, sourceOrder: id, committedAt: committedAt,
                             releasedAt: releasedAt,
                             speechS: Double(clip.speechMs) / 1000); order.append(id)
        if displayPress?.id == press {
            let provisional = displayPress?.preview ?? ""
            displayPress?.clauses[id] = DisplayClause(order: id, end: clip.pcm.end, provisional: provisional)
            displayPress?.preview = ""
            publishTranscript()
        }
        ledger.commit(id, press: press, at: committedAt)
        let overlapMs = lastClipEnd.flatMap { previous -> Int? in
            guard previous.press == press, previous.end > clip.pcm.start else { return nil }
            return HostClock.ms(clip.pcm.start, to: previous.end)
        } ?? 0
        lastClipEnd = (press, clip.pcm.end)
        log.event("speak.clip_committed", ["clause": .int(Int(id)), "press": .int(Int(press)),
            "clip_ms": .int(HostClock.ms(clip.pcm.start, to: clip.pcm.end)), "speech_ms": .int(clip.speechMs),
            "clip_overlap_ms": .int(overlapMs),
            "boundary_wait_ms": .int(max(0, HostClock.ms(clip.pcm.end, to: committedAt))),
            "cut_reason": .tag(clip.cutReason.rawValue)], at: committedAt)
        let previous = asrTail
        let recognition = Task<ASRFinal, Error> { [weak self] in
            await previous?.value
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            return try await self.recognize(clip, clause: id, job: mtJob, token: token)
        }
        asrTasks[id] = recognition
        asrTail = Task { _ = try? await recognition.value }
        processing[id] = Task { [weak self] in
            await self?.process(clip, clause: id, token: token, recognition: recognition)
        }
    }

    private func active(_ id: UInt64, token: UInt32) -> Bool {
        !ended && !suspended && epoch == token && clauses[id] != nil && ledger.state(id)?.isTerminal == false
    }

    private func recognize(_ clip: SpeakClip, clause id: UInt64, job: JobID, token: UInt32) async throws -> ASRFinal {
        guard active(id, token: token), let row = clauses[id] else { throw CancellationError() }
        if let primaryASR {
            // Release tails and early short replies can contain little speech: keep glossary hints, but not a full
            // preceding sentence that the recognizer could repeat in place of the remaining audio.
            let previous = (clip.isFinal || clip.cutReason == .release || clip.cutReason == .shortReply) ? nil
                : lastSource.flatMap { $0.press == row.press ? $0.text : nil }
            let context = [previous, asrContext()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            do {
                // The 600 ms budget begins when this clip actually reaches the recognizer,
                // not while it waits behind preceding clips from the same long press.
                return try await primaryASR.transcribe(clip.pcm, hint: source,
                    context: context.isEmpty ? nil : context,
                    job: job, priority: .p1Speak, deadline: clock() + 600_000_000)
            } catch {
                try Task.checkCancellation()
                guard active(id, token: token) else { throw CancellationError() }
            }
        }
        await preview?.pauseForFinalASR()
        do {
            try Task.checkCancellation()
            let result = try await fallbackASR.transcribe(clip.pcm, hint: source, context: nil, job: job,
                priority: .p1Speak, deadline: nil)
            await preview?.resumeAfterFinalASR()
            return result
        } catch {
            await preview?.resumeAfterFinalASR()
            throw error
        }
    }

    private func process(_ clip: SpeakClip, clause id: UInt64, token: UInt32,
                         recognition: Task<ASRFinal, Error>) async {
        guard let row = clauses[id] else { return }
        defer {
            if clauses[id] == nil || clauses[id]?.mtJob == row.mtJob { processing[id] = nil }
            asrTasks[id] = nil
            reportWorkState()
        }
        do {
            let result = try await recognition.value
            asrTasks[id] = nil
            try Task.checkCancellation()
            guard active(id, token: token) else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let samePrevious = lastSource.map { $0.press == row.press && $0.text == text && !text.isEmpty } ?? false
            log.event("speak.asr_result", ["clause": .int(Int(id)), "press": .int(Int(row.press)),
                "source_characters": .int(text.count), "same_previous": .bool(samePrevious),
                "cut_reason": .tag(clip.cutReason.rawValue)])
            if gate.isFiller(text) { log.event("seg.filler"); discard(id, warning: nil); return }
            let external = speakerMode()
            let overlap = external ? await echo.remoteVADOverlap(from: clip.pcm.start, to: clip.pcm.end) : nil
            let remote = external ? await echo.recentRemoteText(withinS: Double(profile.speak.gate.speakerMode.latinMatchWindowS)) : []
            guard active(id, token: token) else { return }
            if let rejection = gate.check(text, speakerMode: external, remoteOverlap: overlap, recentRemoteText: remote) {
                log.event("gate.drop", ["reason": .tag(rejection.rawValue)])
                discard(id, warning: rejection == .unsupportedText ? .unsupportedTextNotSent : .segmentNotSent)
                return
            }
            clauses[id]?.source = text; lastSource = (press: row.press, text: text)
            displayPress?.clauses[id]?.source = text
            displayPress?.clauses[id]?.provisional = ""
            publishTranscript()
            _ = ledger.advance(id, to: .asrDone, at: clock())
            let following = order.drop(while: { $0 != id }).dropFirst().compactMap { clauses[$0]?.mtJob }
            let existing = Set((history.entries[session] ?? []).map(\.job))
            let context = history.submit(row.mtJob, session: session, source: text, before: following.first(where: existing.contains))
            await translateClause(id, token: token, context: context)
        } catch is CancellationError { return }
        catch { if active(id, token: token) { discard(id, warning: .segmentNotSent) } }
    }

    private func translateClause(_ id: UInt64, token: UInt32, context: [MTTurn]) async {
        guard let row = clauses[id], active(id, token: token) else { return }
        defer {
            if clauses[id] == nil || clauses[id]?.mtJob == row.mtJob { processing[id] = nil }
            reportWorkState()
        }
        do {
            let drain = queue.drainEstimate()
            let preceding = profile.speakHedgePolicy.precedingAudioMs(renderedMs: drain.renderedMs,
                unrenderedExpectedMs: drain.unrenderedExpectedMs + waitingSeconds(before: id) * 1000, inFlightSourceMs: 0)
            let mode: MTMode = row.summary ? .summarize : backlogDecision.mtMode
            clauses[id]?.mode = mode
            let outcome = try await translator.translate(.init(clause: id, press: row.press, job: row.mtJob,
                text: row.source, source: source, target: target, history: context, precedingAudioMs: preceding,
                maskedMs: max(queue.drainableMs, preceding), ttsFirstChunkP95Ms: Int(firstChunk.value ?? 400),
                mode: mode, appleLate: degradation.tier.appleStartsAtDeadline))
            try Task.checkCancellation()
            guard active(id, token: token), clauses[id]?.mtJob == row.mtJob else { return }
            switch outcome {
            case .blocked: discard(id, warning: .segmentNotSent)
            case .text(let translated, let backend, let warning, _):
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { discard(id, warning: nil); return }
                let normalized = TextNormalizer.normalize(translated, lang: target)
                guard target == .zh || !normalized.unicodeScalars.contains(where: TextScript.isCJK) else { discard(id, warning: .segmentNotSent); return }
                if let warning { ui(.post(.numberMaybeWrong(warning))) }
                clauses[id]?.target = normalized; clauses[id]?.backend = backend; clauses[id]?.readyAt = clock()
                displayPress?.clauses[id]?.target = normalized
                displayPress?.clauses[id]?.settled = true
                publishTranscript()
                _ = ledger.advance(id, to: .mtDone, at: clock())
                history.receive(row.mtJob, session: session, target: translated)
                refreshBacklog()
                drainReady()
            }
        } catch is CancellationError { }
        catch { if active(id, token: token), clauses[id]?.mtJob == row.mtJob { discard(id, warning: .segmentNotSent) } }
        logHistoryEvents()
    }

    private func expectedSeconds(_ row: Clause) -> Double {
        guard let text = row.target else { return row.speechS }
        let snapshot = voice()
        let handle: VoiceHandle
        if case .ready(let h) = snapshot.cloneAvailability { handle = h } else { handle = snapshot.systemHandle }
        return calibration.expectedSeconds(text: text, voice: handle, language: target) / max(1, queue.nextTempo)
    }
    private func waitingSeconds(before id: UInt64) -> Double {
        order.prefix(while: { $0 != id }).compactMap { clauses[$0] }.reduce(0) { $0 + expectedSeconds($1) }
    }
    private func leadsByJob() -> [JobID: Int] {
        let drain = queue.drainEstimate()
        let ahead = drain.renderedMs + drain.unrenderedExpectedMs
        return Dictionary(uniqueKeysWithValues: order.compactMap { id -> (JobID, Int)? in
            guard let row = clauses[id] else { return nil }
            return (row.mtJob, Int(ahead + waitingSeconds(before: id) * 1000))
        })
    }
    private func rollback(_ job: JobID) { rollbackJobs([job]) }
    private func rollbackJobs(_ jobs: [JobID]) {
        let leads = leadsByJob()
        var retries: [MTHistory.Retranslation] = []
        for job in jobs { retries += history.rollback(from: job, session: session, msUntilSynthesis: { leads[$0] }) }
        var seen: Set<JobID> = []
        retranslate(retries.filter { seen.insert($0.job).inserted && !jobs.contains($0.job) })
    }
    private func retranslate(_ retry: [MTHistory.Retranslation]) {
        for item in retry {
            guard let id = order.first(where: { clauses[$0]?.mtJob == item.job }), let row = clauses[id] else { continue }
            processing[id]?.cancel()
            let old = row.mtJob, replacement = jobs.next()
            clauses[id]?.mtJob = replacement; clauses[id]?.target = nil
            displayPress?.clauses[id]?.target = ""
            displayPress?.clauses[id]?.settled = false
            publishTranscript()
            let context = history.replaceJob(old, with: replacement, session: session)
            let token = epoch, translator = translator
            processing[id] = Task { [weak self] in
                await translator.cancel(old)
                guard !Task.isCancelled else { return }
                await self?.translateClause(id, token: token, context: context)
            }
        }
        logHistoryEvents()
    }
    private func logHistoryEvents() {
        for event in history.drainEvents() {
            switch event {
            case .ctxGap(let job, let missing): log.event("mt.ctx_gap", ["job": .int(Int(job)), "missing": .int(missing.count)])
            case .ctxStale(let job): log.event("mt.ctx_stale", ["job": .int(Int(job))])
            }
        }
    }
    private func discard(_ id: UInt64, warning: HUDModel.Warning?) {
        displayPress?.clauses[id]?.settled = true
        publishTranscript()
        ledger.gate(id, at: clock())
        order.removeAll { $0 == id }
        if let row = clauses[id] { rollback(row.mtJob) }
        clauses[id] = nil
        if let warning { ui(.post(warning)) }
        drainReady()
    }

    /// Only untranslated/unsynthesized clauses remain in `order`. Starting TTS is bounded by
    /// the render horizon so there are real waiting clauses on which backlog policy can act.
    private func rebuildWaitingQueue() {
        ttsQueue = TTSQueue(config: .init(profile.speak.tts))
        var press: UInt64?
        for id in order {
            guard ledger.state(id)?.isTerminal == false, let row = clauses[id], let text = row.target else { break }
            if let press, press != row.press { break }
            press = row.press
            ttsQueue.enqueue(clause: id, text: text, lang: target, at: row.readyAt)
        }
    }
    private func drainReady() {
        defer { reportWorkState() }
        guard !suspended, !ended, !waitingForEngine else { return }
        if wantsAnnouncement {
            enqueueAnnouncement()
            if wantsAnnouncement { return }
        }
        while true {
            // The engine needs the completed predecessor, not whichever HTTP request arrives
            // first. GPU synthesis was already serial; keep its submission order explicit too.
            guard !renders.keys.contains(where: { renderVoice[$0].map { $0.mode != .system } ?? false }) else { return }
            order.removeAll { ledger.state($0)?.isTerminal != false }
            let drain = queue.drainEstimate()
            guard !queue.report(at: clock()).paused,
                  queue.clauseCount == 0 || drain.renderedMs + drain.unrenderedExpectedMs < Double(profile.speak.tts.renderHorizonMs) else { return }
            rebuildWaitingQueue()
            guard let item = ttsQueue.items.first, let id = item.clauses.first, let row = clauses[id] else { return }
            let snapshot = voice(), job = jobs.next()
            let availability: ClauseLedger.CloneAvailability = degradation.tier == .cloneUnavailable && snapshot.cloneAvailability != .noProfile
                ? .down : snapshot.cloneAvailability
            let choice = ledger.requestTTS(id, job: job, clone: availability, at: clock())
            let selected: any TTSEngine, handle: VoiceHandle, gain: Double, label: HUDModel.Voice
            switch choice {
            case .wait: return
            case .refuse:
                order.removeAll { $0 == id }; rollback(row.mtJob); clauses[id] = nil
                ui(.post(.segmentNotSent)); continue
            case .send(.system): selected = snapshot.system; handle = snapshot.systemHandle; gain = 0; label = .system
            case .send(.clone(let h)):
                guard let clone = snapshot.clone else { return }
                selected = clone; handle = h; gain = snapshot.playoutGainDb; label = snapshot.hudVoice
            }
            for member in item.clauses.dropFirst() { _ = ledger.requestTTS(member, job: job, clone: availability, at: clock()) }
            guard var next = ttsQueue.next(job: job, voice: handle) else { return }
            if handle.mode == .icl {
                let context = "\(voiceContextSession):\(epoch):\(row.press):\(target.rawValue)"
                next.request.contextID = context
                if let previousClone, previousClone.context == context, previousClone.key == handle.conditioningKey {
                    next.request.previousJob = previousClone.job
                }
                previousClone = (context, handle.conditioningKey, job)
            }
            if degradation.tier.usesWholeClauses { next.request.wholeClause = true }
            let members = item.clauses
            order.removeAll { members.contains($0) }
            renderMembers[id] = members; renderVoice[job] = handle; renderText[job] = item.text
            for member in members {
                clauses[member]?.ttsJob = job; clauses[member]?.voice = label
                if let mtJob = clauses[member]?.mtJob { history.markSynthesisStarted(mtJob, session: session) }
            }
            queue.open(clause: id, job: job, epoch: epoch, text: item.text, lang: target,
                       wholeClause: next.request.wholeClause, gainDb: gain,
                       predictedDurationS: calibration.expectedSeconds(text: item.text, voice: handle, language: target))
            let token = epoch, sent = clock(), request = next.request
            // The actual TTS boundary can differ from the source clip (translation/short-clause merging).
            // This is the uncalibrated estimate shared with the engine's output guards, not measured audio.
            log.event("speak.tts_requested", ["clause": .int(Int(id)), "press": .int(Int(row.press)),
                "job": .int(Int(job)), "members": .int(members.count),
                "target_words": .int(item.words), "target_characters": .int(item.text.count),
                "expected_audio_ms": .int(Int((item.expectedS * 1000).rounded()))], at: sent)
            renderEngines[job] = selected
            renders[job] = Task { [weak self] in
                var first = true
                do {
                    for try await chunk in selected.speak(request) {
                        try Task.checkCancellation()
                        await self?.ingest(chunk, clause: id, token: token,
                                           firstAt: first && !chunk.samples24k.isEmpty ? sent : nil)
                        if !chunk.samples24k.isEmpty { first = false }
                    }
                    await self?.renderEnded(id, job: job)
                } catch is CancellationError {
                    await self?.renderCancelled(id, job: job, token: token)
                }
                catch { await self?.renderFailed(id, job: job, error: error) }
            }
        }
    }

    private func ingest(_ chunk: TTSChunk, clause: UInt64, token: UInt32, firstAt: HostTime?) {
        guard token == epoch, !suspended, !ended, ledger.accepts(clause, job: chunk.job) else { return }
        guard queue.ingest(chunk, at: clock()) else { return }
        if let firstAt { firstChunk.record(Double(HostClock.ms(firstAt, to: clock()))) }
        acceptedChunk(chunk)
        if chunk.isLast {
            for id in renderMembers[clause] ?? [clause] { ledger.streamFinished(id, job: chunk.job) }
            if let summary = chunk.summary {
                var fields: [String: EventLog.Value] = ["clause": .int(Int(clause)), "job": .int(Int(chunk.job))]
                fields["attempts"] = .int(summary.attempts)
                fields["echo_aborts"] = .int(summary.echoAborts)
                if let used = summary.contextUsed { fields["context_used"] = .bool(used) }
                if let rtf = summary.computeRTF, rtf.isFinite, rtf >= 0 { fields["compute_rtf"] = .double(rtf) }
                // Engine/system TTS summary: generated duration, not elapsed or heard duration.
                if summary.audioS.isFinite, summary.audioS >= 0, summary.audioS < Double(Int.max) / 1000 {
                    fields["audio_ms"] = .int(Int((summary.audioS * 1000).rounded()))
                }
                log.event("speak.tts_complete", fields)
            }
            if let summary = chunk.summary, let handle = renderVoice[chunk.job], let text = renderText[chunk.job] {
                calibration.record(voice: handle, language: target, text: text, summary: summary, completed: true)
                if handle.mode != .system, let rtf = summary.computeRTF, rtf.isFinite, rtf >= 0 { latestRTF = rtf }
            }
        }
    }

    private func renderEnded(_ id: UInt64, job: JobID) {
        defer { reportWorkState() }
        renders[job] = nil; renderEngines[job] = nil; renderVoice[job] = nil; renderText[job] = nil
        if ledger.row(id)?.job == job, ledger.row(id)?.rendered == false {
            renderFailed(id, job: job, error: PipelineError.truncated)
        } else { drainReady() }
    }

    private func renderCancelled(_ id: UInt64, job: JobID, token: UInt32) {
        // Owner-initiated cancellation removed the task already. A backend cancelling itself
        // must settle the clause as a failed stream instead of leaving busy latched forever.
        guard token == epoch, renders[job] != nil else { return }
        renderFailed(id, job: job, error: CancellationError())
    }

    private enum PipelineError: Error { case truncated }
    private func renderFailed(_ id: UInt64, job: JobID, error: any Error) {
        defer { reportWorkState() }
        if previousClone?.job == job { previousClone = nil }
        renders[job] = nil; renderEngines[job] = nil; renderVoice[job] = nil; renderText[job] = nil
        guard !ended, !suspended, clauses[id]?.ttsJob == job else { return }
        let now = clock(), reason = ttsFailureReason(error)
        let failure = queue.streamFailed(job: job, at: now)
        let members = renderMembers[id] ?? [id]
        for member in members {
            if case .playsOut = failure { ledger.firstSampleEnqueued(member, job: job, at: now) }
            ledger.streamFailed(member, job: job, reason: reason, at: now)
        }
        if case .discarded(let leaders) = failure {
            let ids = leaders.flatMap { renderMembers[$0] ?? [$0] }
            for clause in ids where !members.contains(clause) { _ = ledger.resend(clause, at: now) }
            // A failed HTTP stream (or system voice) need not restart the engine. Waiting for
            // an absent ready event would stall every later clause forever. Retry once while
            // available; a genuinely down clone follows the ledger's bounded recovery window.
            if clauses[id]?.voice != .system, voice().cloneAvailability == .down {
                ledger.engineLost(at: now)
                waitingForEngine = true
            } else if (ledger.row(id)?.attempts ?? 0) >= 2 {
                for member in members { ledger.renderFailed(member, job: job, reason: reason, at: now) }
                rollbackJobs(members.compactMap { clauses[$0]?.mtJob })
            }
            for leader in leaders { renderMembers[leader] = nil }
            restoreOrder(ids)
        }
        ui(.post(.sentenceMaybeIncomplete))
        drainReady()
    }

    public func receive(_ events: [ClauseQueue.Event]) async {
        guard !ended, !suspended else { return }
        workBarriers += 1
        defer { workBarriers -= 1; reportWorkState() }
        let token = epoch
        for event in events {
            guard !ended, !suspended, epoch == token else { return }
            switch event {
            case .firstSampleEnqueued(let id, let job, let at):
                guard let row = clauses[id], row.ttsJob == job else { continue }
                for member in renderMembers[id] ?? [id] {
                    ledger.firstSampleEnqueued(member, job: job, at: at)
                }
            case .firstSamplePlayed(let id, let job, let at):
                if id == announcementClause, job == announcementOutputJob {
                    playingOutput[id] = job
                    reportOutputActivity()
                    continue
                }
                guard let row = clauses[id], row.ttsJob == job, ledger.accepts(id, job: job) else { continue }
                playingOutput[id] = job
                reportOutputActivity()
                let members = renderMembers[id] ?? [id]
                if members.contains(where: { !heard.contains($0) }) {
                    log.event("speak.voice_played", ["voice": .tag(row.voice == .system ? "system" : "clone"),
                        "lang": .tag(target.rawValue), "clause": .int(Int(id)), "job": .int(Int(job))], at: at)
                }
                for member in members where !heard.contains(member) {
                    heard.insert(member)
                    if let part = clauses[member], let text = part.target {
                        var fields: [String: EventLog.Value] = ["clause": .int(Int(member)), "press": .int(Int(part.press)),
                            "job": .int(Int(job)), "commit_to_audio_ms": .int(max(0, HostClock.ms(part.committedAt, to: at))),
                            "underruns_total": .int(queue.report(at: clock()).underruns)]
                        if heardPresses.insert(part.press).inserted, let released = part.releasedAt, at >= released {
                            fields["release_to_audio_ms"] = .int(HostClock.ms(released, to: at))
                        }
                        log.event("speak.first_audio", fields, at: at)
                        history.markSpoken(part.mtJob, session: session)
                        onSpoken(part.source, text, at)
                    }
                }
                ui(.pushToTalk(.playing(lang: target, voice: row.voice, source: row.backend, queued: queue.clauseCount)))
            case .played(let played):
                playingOutput[played.clause] = nil
                reportOutputActivity()
                if announcementClause == played.clause { announcementClause = nil; announcementOutputJob = nil }
                let members = renderMembers.removeValue(forKey: played.clause) ?? [played.clause]
                for member in members { ledger.played(member, at: played.end); clauses[member] = nil }
                await echo.recordPlayed(text: played.text, startHost: played.start, endHost: played.end)
                if queue.clauseCount == 0, currentPress == nil { ui(.pushToTalk(.idle)) }
            case .cut(let id, let reason, let at):
                if id == announcementClause { announcementOutputJob = nil }
                playingOutput[id] = nil
                reportOutputActivity()
                if let job = clauses[id]?.ttsJob, previousClone?.job == job { previousClone = nil }
                let members = renderMembers[id] ?? [id]
                for member in members { ledger.cut(member, reason: reason, at: at) }
                rollbackJobs(members.compactMap { clauses[$0]?.mtJob })
                if reason == .passthroughCut { log.event("pt.clause_cut", at: at) }
            case .cancelJob(let job):
                if announcementOutputJob == job { announcementOutputJob = nil }
                playingOutput = playingOutput.filter { $0.value != job }
                reportOutputActivity()
                if previousClone?.job == job { previousClone = nil }
                renderVoice[job] = nil; renderText[job] = nil
                renders.removeValue(forKey: job)?.cancel()
                if let e = renderEngines.removeValue(forKey: job) { await e.cancel(job) }
            case .rerender(let id, let job):
                if playingOutput[id] == job { playingOutput[id] = nil; reportOutputActivity() }
                if previousClone?.job == job { previousClone = nil }
                if id == announcementClause { announcementClause = nil; announcementOutputJob = nil; requestAnnouncement(); continue }
                let members = renderMembers.removeValue(forKey: id) ?? [id]
                let resends = members.filter { ledger.resend($0, at: clock()) }
                restoreOrder(resends)
            case .renderFailed(let id, let job, let reason):
                if id == announcementClause, announcementOutputJob == job { announcementOutputJob = nil }
                if playingOutput[id] == job { playingOutput[id] = nil; reportOutputActivity() }
                if previousClone?.job == job { previousClone = nil }
                let members = renderMembers.removeValue(forKey: id) ?? [id]
                for member in members { ledger.renderFailed(member, job: job, reason: reason, at: clock()) }
                rollbackJobs(members.compactMap { clauses[$0]?.mtJob })
                for member in members { clauses[member] = nil }
                ui(.post(.segmentNotSent))
            case .yielded(let at): yielded(at); host.setFastPump(false)
            case .resumed: host.setFastPump(false)
            case .clauseStarted, .underrun, .staleChunk: break
            }
        }
        drainReady()
    }

    private func engineChanged(_ status: SpeakEngineStatus) {
        guard !ended else { return }
        switch status {
        case .lost: ledger.engineLost(at: clock())
        case .ready:
            prepareAnnouncement()
            waitingForEngine = false
            let retries = ledger.engineReady(at: clock()).filter { id in
                guard let job = clauses[id]?.ttsJob else { return true }
                // An old stream must finish/discard its physical entry before a new job opens it.
                return renders[job] == nil
            }
            restoreOrder(retries); drainReady()
        }
    }

    private func restoreOrder(_ ids: [UInt64]) {
        for id in ids where clauses[id] != nil && !order.contains(id) { order.append(id) }
        // A summary has a new ID but retains its first source clause's position.
        order.sort { (clauses[$0]?.sourceOrder ?? $0) < (clauses[$1]?.sourceOrder ?? $1) }
    }

    private func refreshBacklog() {
        let drain = queue.drainEstimate(excludingAnnouncements: true)
        let pending = order.compactMap { clauses[$0] }
        let translated = pending.filter { $0.target != nil }.reduce(0) { $0 + expectedSeconds($1) }
        let untranslated = pending.filter { $0.target == nil }.reduce(0) { $0 + $1.speechS }
        backlogDecision = backlog.update(renderedS: drain.renderedMs / 1000,
            unrenderedS: drain.unrenderedExpectedMs / 1000 + translated, inFlightSourceS: untranslated)
        queue.nextTempo = backlogDecision.tempo; queue.dropGaps = backlogDecision.dropGaps
        // While yielding/paused, preserve submitted speech; compression/drop resumes with playback.
        guard !queue.report(at: clock()).paused else { return }
        if backlogDecision.dropOldestWaiting, let id = order.first, let row = clauses[id] {
            cancelWork(id, row: row)
            ledger.drop(id, reason: .backlogDrop, at: clock())
            order.removeAll { $0 == id }; rollback(row.mtJob); clauses[id] = nil
            displayPress?.clauses[id]?.settled = true
            publishTranscript()
            ui(.post(.skipped(segments: 1)))
        } else if backlogDecision.summarizeWaiting,
                  !order.contains(where: { clauses[$0]?.summary == true }) {
            var ids: [UInt64] = [], press: UInt64?
            for id in order {
                guard let row = clauses[id], !row.source.isEmpty else { break }
                if let press, press != row.press { break }
                press = row.press; ids.append(id)
            }
            if ids.count >= 2 { summarize(ids) }
        }
    }

    private func cancelWork(_ id: UInt64, row: Clause) {
        processing.removeValue(forKey: id)?.cancel(); asrTasks.removeValue(forKey: id)?.cancel()
        let translator = translator, primary = primaryASR, fallback = fallbackASR
        cancellingJobs.insert(row.mtJob)
        Task { [weak self] in
            await translator.cancel(row.mtJob); await primary?.cancel(row.mtJob); await fallback.cancel(row.mtJob)
            await self?.cancelledWork(row.mtJob)
        }
    }
    private func cancelledWork(_ job: JobID) {
        cancellingJobs.remove(job)
        reportWorkState()
    }
    private func summarize(_ ids: [UInt64]) {
        guard let first = ids.first, let row = clauses[first], let position = order.firstIndex(of: first) else { return }
        let rows = ids.compactMap { clauses[$0] }
        let source = rows.map(\.source).joined(separator: "\n")
        let id = jobs.next(), job = jobs.next(), token = epoch
        let context = history.merge(rows.map(\.mtJob), into: job, session: session, source: source)
        for old in ids {
            if let row = clauses[old] { cancelWork(old, row: row) }
            ledger.drop(old, reason: .backlogDrop, at: clock()); clauses[old] = nil
        }
        order.removeAll { ids.contains($0) }; order.insert(id, at: min(position, order.count))
        clauses[id] = Clause(press: row.press, mtJob: job, sourceOrder: row.sourceOrder,
                             committedAt: row.committedAt, releasedAt: row.releasedAt, source: source,
                             speechS: rows.reduce(0) { $0 + $1.speechS }, summary: true)
        if displayPress?.id == row.press {
            let end = ids.compactMap { displayPress?.clauses[$0]?.end }.max()
            for old in ids { displayPress?.clauses[old] = nil }
            // Audio may summarize work that has already left the reading window. Do not
            // resurrect that history; a visible summary inherits its latest visible audio end.
            if let end { displayPress?.clauses[id] = DisplayClause(order: row.sourceOrder, end: end, source: source) }
            publishTranscript()
        }
        ledger.commit(id, press: row.press, at: clock()); _ = ledger.advance(id, to: .asrDone, at: clock())
        processing[id] = Task { [weak self] in await self?.translateClause(id, token: token, context: context) }
        let leads = leadsByJob()
        retranslate(history.invalidateAfter(job, session: session, msUntilSynthesis: { leads[$0] }))
        log.event("backlog.summarize", ["segments": .int(ids.count)])
    }

    /// The switch controls automatic first-press playback. Updating it preserves this
    /// meeting's disclosure state and an already requested (including manual) playback.
    public func configureAnnouncement(text: String, enabled: Bool) {
        if announcementText != text {
            announcementTask?.cancel(); announcementTask = nil; announcementJob = nil
            announcementCache = nil
        }
        announcementText = text; announcementEnabled = enabled
        if !enabled, !wantsAnnouncement {
            announcementTask?.cancel(); announcementTask = nil; announcementJob = nil
        }
        if enabled || wantsAnnouncement { prepareAnnouncement() }
    }
    public func playAnnouncement() {
        guard !ended, !suspended, let text = announcementText, !text.isEmpty else { return }
        announced = true
        requestAnnouncement(); drainReady()
    }
    private func requestAnnouncement() {
        wantsAnnouncement = true; announcementRequestedAt = clock()
        reportWorkState() // closes original audio before a cached announcement can enter ringO
        prepareAnnouncement()
    }
    private func announcementVoice() -> (any TTSEngine, VoiceHandle, Double)? {
        let snapshot = voice()
        switch snapshot.cloneAvailability {
        case .noProfile: return (snapshot.system, snapshot.systemHandle, 0)
        case .ready(let handle):
            guard let clone = snapshot.clone, degradation.tier != .cloneUnavailable else { return nil }
            return (clone, handle, snapshot.playoutGainDb)
        case .down: return nil
        }
    }
    private func prepareAnnouncement() {
        guard announcementEnabled || wantsAnnouncement, !ended, !suspended, announcementTask == nil,
              let text = announcementText, !text.isEmpty, let (selected, handle, gain) = announcementVoice() else { return }
        if announcementCache?.handle == handle { return }
        announcementCache = nil
        let job = jobs.next(), token = epoch
        let normalized = TextNormalizer.normalize(text, lang: target)
        guard target == .zh || !normalized.unicodeScalars.contains(where: TextScript.isCJK) else { return }
        let request = TTSRequest(job: job, clause: job, text: normalized, language: target, voice: handle,
                                 seed: TTSSeed.make(voice: handle, language: target), wholeClause: true)
        announcementEngine = selected; announcementJob = job
        announcementTask = Task { [weak self] in
            do {
                let chunks = try await withThrowingTaskGroup(of: [TTSChunk].self) { group in
                    group.addTask {
                        var chunks: [TTSChunk] = [], frames = 0
                        for try await chunk in selected.speak(request) {
                            try Task.checkCancellation()
                            frames += chunk.samples24k.count
                            guard frames <= 30 * 24_000 else { throw PipelineError.truncated }
                            chunks.append(chunk)
                        }
                        guard chunks.last?.isLast == true, frames > 0 else { throw PipelineError.truncated }
                        return chunks
                    }
                    group.addTask { try await Task.sleep(for: .seconds(5)); throw PipelineError.truncated }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation()
                await self?.announcementPrepared(.init(handle: handle, gainDb: gain, chunks: chunks), job: job, token: token)
            } catch {
                await selected.cancel(job)
                await self?.announcementFailed(job: job, token: token)
            }
        }
    }
    private func announcementPrepared(_ cache: AnnouncementCache, job: JobID, token: UInt32) {
        guard token == epoch, !ended, announcementJob == job else { return }
        announcementTask = nil; announcementJob = nil; announcementCache = cache
        drainReady()
    }
    private func announcementFailed(job: JobID, token: UInt32) {
        guard token == epoch, !ended, announcementJob == job else { return }
        announcementTask = nil; announcementJob = nil; announcementCache = nil
        if announcementEnabled || wantsAnnouncement { ui(.post(.segmentNotSent)) }
        if wantsAnnouncement { wantsAnnouncement = false; drainReady() }
    }
    private func enqueueAnnouncement() {
        guard wantsAnnouncement, let cache = announcementCache,
              let (_, handle, _) = announcementVoice(), cache.handle == handle,
              let text = announcementText else { prepareAnnouncement(); return }
        let id = jobs.next(), job = jobs.next()
        announcementClause = id; announcementOutputJob = job; wantsAnnouncement = false
        queue.open(clause: id, job: job, epoch: epoch, text: text, lang: target,
                   wholeClause: true, gainDb: cache.gainDb, excludeFromMetrics: true)
        for var chunk in cache.chunks {
            chunk.job = job
            if queue.ingest(chunk, at: clock()) { acceptedChunk(chunk) }
        }
    }

    public func updateLoad(rtf: Double? = nil, thermalSerious: Bool, lowPower: Bool, at time: HostTime? = nil) {
        self.thermalSerious = thermalSerious; self.lowPower = lowPower
        if let rtf, rtf.isFinite, rtf >= 0 { latestRTF = rtf }
        applyDegradation(at: time ?? clock())
    }
    private func applyDegradation(at now: HostTime) {
        let report = queue.report(at: now)
        let recentRTF = latestRTF.flatMap { !renders.isEmpty || !order.isEmpty || $0 <= 0.35 ? $0 : nil }
        let change = degradation.observe(rtf: recentRTF, underrunCount: UInt64(max(0, report.underruns)),
                                         thermalSerious: thermalSerious, lowPower: lowPower, at: now)
        var floors = queue.prerollFloors
        floors.degraded = degradation.tier >= .buffered
        floors.lowPowerOrHot = lowPower || thermalSerious
        queue.prerollFloors = floors
        guard let change else { return }
        // The terminal tier refuses NEW clone requests through requestTTS(.down). Already
        // submitted audio may finish; do not mislabel healthy/system-voice streams as crashed.
        if change.from == .cloneUnavailable, case .ready = voice().cloneAvailability {
            _ = ledger.engineReady(at: now); waitingForEngine = false
        }
        onDegradation(change.to)
        log.event("speak.degradation", ["tier": .int(change.to.rawValue)])
    }

    private func tick() {
        guard !ended, !suspended else { return }
        defer { reportWorkState() }
        let dropped = ledger.tick(at: clock())
        if !dropped.isEmpty { ui(.post(.segmentNotSent)) }
        for id in dropped {
            order.removeAll { $0 == id }
            if let row = clauses[id] { rollback(row.mtJob); clauses[id] = nil }
        }
        if !ledger.rows.values.contains(where: { !$0.state.isTerminal && $0.waitingSince != nil }) { waitingForEngine = false }
        if wantsAnnouncement, let since = announcementRequestedAt, HostClock.ms(since, to: clock()) >= 5000 {
            announcementTask?.cancel(); announcementTask = nil
            wantsAnnouncement = false; ui(.post(.segmentNotSent))
        }
        applyDegradation(at: clock()); refreshBacklog()
        log.event("speak.backlog", ["seconds": .double(backlogDecision.backlogS)])
        drainReady()
    }

    public nonisolated func setFloorPaused(_ paused: Bool) { queue.setFloorPaused(paused) }
    public nonisolated func cutForFloor(at now: HostTime) { queue.cutForFloor(at: now) }
    public var queuedSegments: Int { order.count + queue.clauseCount }
    public var degradationTier: DegradationLadder.Tier { degradation.tier }

    public nonisolated func yieldForPassthrough(requestedAt: HostTime, cutAt: HostTime) {
        queue.requestYield(at: requestedAt); host.setFastPump(true)
    }
    public nonisolated func passthroughEnded(at: HostTime) { queue.passthroughClosed(at: at) }

    public func suspend() async {
        guard !suspended, !ended else { return }
        suspended = true
        await cancelPending()
    }

    /// A Phone input-reader boundary may be hangup, mute, hold or a route change. Keep the
    /// prepared session, but discard all old speech before any subsequent reader can hear it.
    /// The owner serializes this with resume() and revokes the physical-key gate immediately.
    public func phoneInputLost() async {
        guard !ended else { return }
        suspended = true
        displayPress = nil
        let empty = SpeakTranscript(press: jobs.next(), source: "", target: "", isFinal: true)
        lastTranscript = empty
        ui(.transcript(empty))
        await cancelPending()
        history.reset(); heard.removeAll(); heardPresses.removeAll()
        lastSource = nil; lastClipEnd = nil; previousClone = nil
        announced = false; announcementRequestedAt = nil; announcementEngine = nil
    }

    public func resume() { if !ended { suspended = false; waitingForEngine = false } }
    public func stop() async {
        guard !ended else { return }
        ended = true
        services.forEach { $0.cancel() }; services.removeAll()
        host.setEventSink(nil); eventContinuation?.finish(); eventContinuation = nil
        await cancelPending()
        history.reset(); heard.removeAll(); heardPresses.removeAll()
    }

    private func cancelPending() async {
        workBarriers += 1; reportWorkState()
        defer { workBarriers -= 1; reportWorkState() }
        epoch &+= 1
        previousClone = nil
        for press in presses.values { press.reader?.cancel(); press.audio.cancel() }
        presses.removeAll(); currentPress = nil
        previewStart?.cancel(); previewStart = nil
        processing.values.forEach { $0.cancel() }; processing.removeAll()
        asrTasks.values.forEach { $0.cancel() }; asrTasks.removeAll()
        let oldASRTail = asrTail
        asrTail = nil
        renders.values.forEach { $0.cancel() }; renders.removeAll()
        let oldClauses = clauses, oldEngines = renderEngines
        let oldAnnouncementJob = announcementJob, oldAnnouncementEngine = announcementEngine
        announcementTask?.cancel(); announcementTask = nil; announcementJob = nil
        wantsAnnouncement = false; announcementClause = nil; announcementOutputJob = nil
        clauses.removeAll(); order.removeAll(); renderEngines.removeAll()
        renderMembers.removeAll(); renderVoice.removeAll(); renderText.removeAll()
        waitingForEngine = false
        _ = ledger.cancelAll(at: clock()); _ = ttsQueue.removeAll()
        history.cancelAll(session: session)
        _ = queue.hardInterrupt(newEpoch: epoch, at: clock())
        playingOutput.removeAll()
        reportOutputActivity()
        host.setFastPump(false)
        await preview?.stop()
        for row in oldClauses.values {
            await translator.cancel(row.mtJob)
            await primaryASR?.cancel(row.mtJob); await fallbackASR.cancel(row.mtJob)
        }
        for (job, selected) in oldEngines { await selected.cancel(job) }
        if let job = oldAnnouncementJob { await oldAnnouncementEngine?.cancel(job) }
        // All queued recognitions are cancelled, including those still waiting for their turn.
        // Wait for the active backend's cancellation before a resumed session opens a preview.
        await oldASRTail?.value
        await engine.cancelSpeak(); await engine.pressActive(false)
        if let display = displayPress {
            for id in display.clauses.keys { displayPress?.clauses[id]?.settled = true }
            finishDisplayCapture(display.id)
        }
        ui(.pushToTalk(.idle))
    }
}
