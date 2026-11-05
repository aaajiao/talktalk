import Foundation
import NaturalLanguage
import TalkTalkCore

/// What the subtitle panel shows (§11 字幕面板). Sentence ids increase; finals can resolve out of
/// order (a slow cloud reply), so the panel orders them by id.
public enum SubtitleUpdate: Sendable, Equatable {
    /// The gray source line: the current sentence as heard so far.
    case source(String)
    /// Gray draft translation of an open sentence (only the newest matters).
    case draft(sentence: UInt64, text: String)
    /// Frozen translation. `approx` = the Apple fallback (“≈”, §5.1); `numberWarning` = the
    /// numbers in the subtitle do not all occur in what was said (NumberGuard, §5.4).
    case final(sentence: UInt64, text: String, source: String = "", approx: Bool, numberWarning: Bool)
    /// The sentence was dropped (echo of our own TTS, §3.5): remove its draft.
    case dropped(sentence: UInt64)
}

/// In-memory observations for an explicitly enabled subtitle analysis. EventLog remains
/// text-free; the caller decides whether to retain these observations for this session.
public struct ListenAnalysisEvent: Sendable {
    public enum Stage: String, Sendable { case asrUpdate, sentenceFinal, mtCompleted }
    public let stage: Stage
    public let sentence: UInt64
    public let at: HostTime
    public let source: String?
    public let translation: String?
    /// ASR's configured adapter ID; MT's accepted result engine. An adapter may fall back, so
    /// the app records its separately reported actual ASR status alongside this field.
    public let engine: String?
    public let numberWarning: Bool?
    /// The recognizer's audio boundary, when supplied; distinct from the result arrival time.
    public let audioThrough: HostTime?
    public let audioFrom: HostTime?

    public init(stage: Stage, sentence: UInt64, at: HostTime, source: String? = nil,
                translation: String? = nil, engine: String? = nil, numberWarning: Bool? = nil,
                audioThrough: HostTime? = nil, audioFrom: HostTime? = nil) {
        self.stage = stage; self.sentence = sentence; self.at = at; self.source = source
        self.translation = translation; self.engine = engine; self.numberWarning = numberWarning
        self.audioThrough = audioThrough
        self.audioFrom = audioFrom
    }
}

/// Which engine the finals actually come from (menu line and icon, §11): the configured primary
/// is not enough — offline, deadline, breaker and pause all fall back to Apple per sentence.
public enum ListenTranslation: Sendable, Equatable {
    case openAI
    /// The primary exists but the last final came from Apple. `reason`: the cloud's reason
    /// ("offline", "breakerOpen", "paused:401", …), "deadline" or "empty".
    case appleFallback(reason: String)
    /// No primary, cloud disabled, or the user chose Apple for this meeting.
    case appleOnly

    public var isDegraded: Bool { self != .openAI }

    /// The menu's status line. `offline`: NetworkHealth says so now (before any final fails).
    public func menuText(offline: Bool) -> String {
        switch self {
        case .appleOnly: return "字幕翻译：Apple 翻译（本场未使用 OpenAI）"
        case .openAI where offline: return "⚠︎ 字幕翻译：Apple 翻译（离线）"
        case .openAI: return "字幕翻译：OpenAI"
        case let .appleFallback(r):
            if offline || r == "offline" { return "⚠︎ 字幕翻译：Apple 翻译（离线）" }
            if r.hasPrefix("paused") { return "⚠︎ 字幕翻译：Apple 翻译（OpenAI 已暂停：key 或额度）" }
            if r == "deadline" { return "⚠︎ 字幕翻译：Apple 翻译（超时）" }
            return "⚠︎ 字幕翻译：Apple 翻译（OpenAI 暂时不可用）"
        }
    }
}

/// LISTEN (§1.2, §5.1): ASR events → ListenSegmenter → Apple draft MT (newest only) and, per
/// sentence, the final MT with deadline = finalize trigger + `finalMT.deadlineMs`. When the
/// primary (OpenAIMT) has no result by then — or there is no primary (no key, cloud off) — the
/// Apple translation becomes the final with “≈”, the cloud job is cancelled and `mt.late` logged.
/// The event log gets times, counts and tags only, never text (§16 决定 13).
public actor ListenPipeline {
    public struct Engines: Sendable {
        public var asr: any StreamingASREngine
        /// Apple Translation (drafts and the fallback). nil: drafts off, fallback = source text.
        public var apple: (any MTEngine)?
        /// OpenAIMT. nil: every final is the Apple translation (“≈”).
        public var primary: (any MTEngine)?
        /// Second pass (RemoteQwenASR, talktalk-m0); used only when `listen.secondPassASR` is on.
        public var secondPass: (any ClipASREngine)?
        public init(asr: any StreamingASREngine, apple: (any MTEngine)?, primary: (any MTEngine)?, secondPass: (any ClipASREngine)? = nil) {
            self.asr = asr; self.apple = apple; self.primary = primary; self.secondPass = secondPass
        }
    }

    public let lang: Lang
    public let profile: PolicyProfile.Listen
    public nonisolated let ingest: AudioIngest
    private let engines: Engines
    private let log: EventLog
    private let onTranscript: @Sendable (String, String, HostTime) -> Void
    private let onAnalysis: (@Sendable (ListenAnalysisEvent) -> Void)?
    private let glossary: @Sendable () -> [GlossaryEntry]
    private let clock: @Sendable () -> HostTime
    private let onUpdate: @Sendable (SubtitleUpdate) -> Void
    private let onTranslation: @Sendable (ListenTranslation) -> Void
    private var translation: ListenTranslation?
    private let tickMs: Int

    private var segmenter: ListenSegmenter
    private var echo: EchoFilter
    private var stream: (any ASRStream)?
    private var tasks: [Task<Void, Never>] = []
    private var streamTasks: [Task<Void, Never>] = []
    private var streamEpoch: UInt64 = 0
    private var lastFinalThrough: HostTime?
    private var draftsPaused = false
    private var appleForThisMeeting = false
    private var appleJobs: Set<JobID> = []
    private var secondPassJobs: Set<JobID> = []
    private var primaryWaits: [JobID: Task<Race.Outcome<MTResult>, Never>] = [:]
    private var lookbackRevisions = 0
    private var acousticEcho: (score: Double, at: HostTime)?
    /// 100 ms observations, aligned with capture time rather than ASR callback arrival.
    private var echoObservations: [(at: HostTime, score: Double?)] = []
    private var sourceAudioThrough: HostTime?
    /// Evidence belongs to one sentence, including its late final after the raw gate closes.
    private var rejectedEcho: (sentence: UInt64, decision: EchoFilter.Decision)?
    private var previousFinal: (id: UInt64, source: String, at: HostTime, revised: Bool)?
    private var startHost: HostTime = 0
    private let jobs: JobIDSequence
    private var draftJob: (job: JobID, task: Task<Void, Never>)?
    private var drafts: [UInt64: (source: String, target: String)] = [:]
    private var history: [(sentence: UInt64, turn: MTTurn)] = []
    private var lastSource = ""
    private var finalsInFlight = 0
    private var running = false
    private var finalTasks: [UInt64: Task<Void, Never>] = [:]
    private var remoteText: [(host: HostTime, text: String)] = []

    public init(lang: Lang, profile: PolicyProfile.Listen, engines: Engines, log: EventLog,
                ingest: AudioIngest = AudioIngest(), tickMs: Int = 50, jobs: JobIDSequence = JobIDSequence(),
                onTranscript: @escaping @Sendable (String, String, HostTime) -> Void = { _, _, _ in },
                onAnalysis: (@Sendable (ListenAnalysisEvent) -> Void)? = nil,
                glossary: @escaping @Sendable () -> [GlossaryEntry] = { [] },
                clock: @escaping @Sendable () -> HostTime = HostClock.now,
                onUpdate: @escaping @Sendable (SubtitleUpdate) -> Void,
                onTranslation: @escaping @Sendable (ListenTranslation) -> Void = { _ in }) {
        var profile = profile
        let partialInterval = engines.asr.partialUpdateIntervalMs
        if partialInterval > 0 {
            // Text can remain unchanged between regular ASR batches while audio continues.
            // Stable punctuation is also recognizer output, so it needs the same allowance.
            // Real VAD silence, ASR finals and audio hard caps remain independent and unchanged.
            let minimumTextPause = partialInterval + 250
            profile.finalize.punctPauseMs = max(profile.finalize.punctPauseMs, minimumTextPause)
            profile.finalize.force.pauseMs = max(profile.finalize.force.pauseMs, minimumTextPause)
            profile.finalize.force.pauseMsAfter8s = max(profile.finalize.force.pauseMsAfter8s, minimumTextPause)
            profile.finalize.stallMs = max(profile.finalize.stallMs, minimumTextPause)
            profile.finalize.stallMsAfter8s = max(profile.finalize.stallMsAfter8s, minimumTextPause)
        }
        self.lang = lang
        self.glossary = glossary
        self.onTranscript = onTranscript
        self.onAnalysis = onAnalysis
        self.onTranslation = onTranslation
        self.profile = profile
        self.engines = engines
        self.log = log
        self.ingest = ingest
        self.tickMs = tickMs
        self.jobs = jobs
        self.clock = clock
        self.onUpdate = onUpdate
        self.segmenter = ListenSegmenter(lang: lang, profile: profile)
        self.echo = EchoFilter(config: .init(profile.echoFilter))
    }

    var session: MTSession { lang == .de ? .listenDeZh : .listenEnZh }

    // MARK: - lifecycle

    public func start() async throws {
        streamEpoch &+= 1
        let epoch = streamEpoch
        startHost = clock()
        lastFinalThrough = nil
        sourceAudioThrough = nil; rejectedEcho = nil; echoObservations.removeAll()
        let s = try await engines.asr.open(lang, highPriority: false)
        guard epoch == streamEpoch, !Task.isCancelled else {
            await s.close(); throw CancellationError()
        }
        stream = s
        running = true
        ingest.attach(s)
        log.event("listen.start", ["lang": .tag(lang.rawValue), "primary": .bool(engines.primary != nil),
                                   "apple": .bool(engines.apple != nil), "second_pass": .bool(profile.secondPassASR)])
        report(engines.primary == nil ? .appleOnly : .openAI)
        observeStream(s)
        let period = tickMs
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(period))
                await self?.tick()
            }
        })
    }

    public func stop() async {
        running = false
        streamEpoch &+= 1
        for t in streamTasks { t.cancel() }; streamTasks.removeAll()
        acousticEcho = nil
        sourceAudioThrough = nil; rejectedEcho = nil; echoObservations.removeAll()
        ingest.detach()
        for t in finalTasks.values { t.cancel() }
        finalTasks.removeAll()
        remoteText.removeAll()
        for t in tasks { t.cancel() }
        tasks.removeAll()
        draftJob?.task.cancel(); draftJob = nil
        let oldStream = stream; stream = nil
        let pendingApple = appleJobs, pendingCloud = Array(primaryWaits.keys), pendingSecondPass = secondPassJobs
        appleJobs.removeAll(); secondPassJobs.removeAll()
        primaryWaits.values.forEach { $0.cancel() }; primaryWaits.removeAll()
        for job in pendingApple { await engines.apple?.cancel(job) }
        for job in pendingCloud { await engines.primary?.cancel(job) }
        for job in pendingSecondPass { await engines.secondPass?.cancel(job) }
        await oldStream?.close()
        log.event("listen.stop", ["sentences": .int(Int(segmenter.sentence) - 1), "revisions": .int(segmenter.revisions + lookbackRevisions)])
    }

    private func observeStream(_ s: any ASRStream) {
        streamEpoch &+= 1
        let epoch = streamEpoch, vol = s.volatileEvents, fin = s.finalEvents
        streamTasks = [Task { [weak self] in
            for await e in vol {
                guard !Task.isCancelled else { break }
                if case let .volatile(t, through) = e { await self?.receiveVolatile(t, through: through, epoch: epoch) }
            }
        }, Task { [weak self] in
            for await e in fin {
                guard !Task.isCancelled else { break }
                if case let .final(t, range) = e { await self?.receiveFinal(t, range: range, epoch: epoch) }
            }
        }]
    }

    private func receiveVolatile(_ text: String, through: HostTime, epoch: UInt64) async {
        guard running, streamEpoch == epoch else { return }; await onVolatile(text, through: through)
    }
    private func receiveFinal(_ text: String, range: ClosedRange<HostTime>, epoch: UInt64) async {
        guard running, streamEpoch == epoch else { return }; await onFinal(text, range: range)
    }

    /// New analyzer origin after a long capture hole. Stale callbacks cannot cross the boundary.
    public func restartAnalyzer(afterGapMs gapMs: Int) async throws {
        guard running else { return }
        streamEpoch &+= 1
        let epoch = streamEpoch
        ingest.detach()
        for t in streamTasks { t.cancel() }; streamTasks.removeAll()
        let old = stream; stream = nil
        await perform(segmenter.audioGap(nowMs: nowMs))
        sourceAudioThrough = nil; rejectedEcho = nil; echoObservations.removeAll(); acousticEcho = nil
        await old?.close()
        guard running, streamEpoch == epoch else { return }
        let next = try await engines.asr.open(lang, highPriority: false)
        guard running, streamEpoch == epoch else { await next.close(); return }
        ingest.attach(next); stream = next
        observeStream(next)
        log.event("listen.analyzer_restart", ["gap_ms": .int(gapMs)])
    }

    public func setDraftsPaused(_ paused: Bool) {
        draftsPaused = paused
        if paused, let d = draftJob {
            d.task.cancel(); draftJob = nil
            if let apple = engines.apple { Task { await apple.cancel(d.job) } }
            onUpdate(.dropped(sentence: segmenter.sentence))
        }
    }

    /// Applies only to this LISTEN pipeline; SPEAK may share the same cloud engine.
    public func useAppleForThisMeeting() async {
        appleForThisMeeting = true
        report(.appleOnly)
        let waits = primaryWaits
        for wait in waits.values { wait.cancel() }
        for job in waits.keys { await engines.primary?.cancel(job) }
    }

    public func setEchoScore(_ score: Double?, at: HostTime) {
        let normalized = score.flatMap { $0.isFinite ? max(0, min(1, $0)) : nil }
        acousticEcho = normalized.map { ($0, at) }
        echoObservations.append((at, normalized))
        let window = UInt64(profile.echoFilter.windowS + profile.echoFilter.afterPlayS) * 1_000_000_000
        echoObservations.removeAll { at >= $0.at && at - $0.at > window }
        if echoObservations.count > 256 { echoObservations.removeFirst(echoObservations.count - 256) }
        rejectPassthroughEcho(text: segmenter.sourceLine, through: sourceAudioThrough, at: at)
    }
    public func echoScore(at now: HostTime) -> Double? {
        guard let e = acousticEcho, now >= e.at, now - e.at <= 500_000_000 else { return nil }
        return e.score
    }
    public var volatileText: String { segmenter.sourceLine }

    /// A TTS clause we played into the meeting (SPEAK, M2) — for EchoFilter.
    public func recordPlayed(text: String, startHost: HostTime, endHost: HostTime) {
        echo.recordPlayed(text: text, startMs: ms(startHost), endMs: ms(endHost))
    }

    public func recordPassthrough(startHost: HostTime, endHost: HostTime) {
        echo.recordPassthrough(startMs: ms(startHost), endMs: ms(endHost))
        rejectPassthroughEcho(text: segmenter.sourceLine, through: sourceAudioThrough, at: clock())
    }

    /// Only confirmed acoustic return of our original audio suppresses a live sentence.
    /// Raw-open alone must never mute remote LISTEN. Keep segmenting so this sentence can
    /// finish, but stop its draft work now and retain the evidence for its eventual final.
    private func rejectPassthroughEcho(text: String, through: HostTime?, at now: HostTime) {
        guard running, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rejectedEcho?.sentence != segmenter.sentence,
              let through,
              case let .drop(reason, overlap) = echo.decide(text: text, startMs: ms(through), echoScore: echoScore(forAudioThrough: through, at: now)),
              reason == .passthroughEcho else { return }
        rejectedEcho = (segmenter.sentence, .drop(reason: reason, overlap: overlap))
        if let draft = draftJob {
            draft.task.cancel(); draftJob = nil
            if let apple = engines.apple { Task { await apple.cancel(draft.job) } }
        }
        drafts[segmenter.sentence] = nil
        onUpdate(.dropped(sentence: segmenter.sentence))
        if !lastSource.isEmpty { lastSource = ""; onUpdate(.source("")) }
    }

    private func echoScore(forAudioThrough through: HostTime?, at now: HostTime) -> Double? {
        // Qwen's through is clip.end, not result delivery time. Preserve unknown points too:
        // missing evidence must not reuse an earlier positive score or silence observation.
        let window = UInt64(profile.echoFilter.windowS + profile.echoFilter.afterPlayS) * 1_000_000_000
        guard let through, now >= through, now - through <= window else { return nil }
        func distance(_ at: HostTime) -> HostTime { at >= through ? at - through : through - at }
        guard let nearest = echoObservations.min(by: { distance($0.at) < distance($1.at) }),
              distance(nearest.at) <= 200_000_000 else { return nil }
        return nearest.score
    }

    /// Source text from the last five seconds, kept in memory for SPEAK's echo language gate.
    public func recentRemoteText(withinS seconds: Double) -> [String] {
        let now = clock()
        let age = UInt64(max(0, min(5, seconds.isFinite ? seconds : 0)) * 1e9)
        remoteText.removeAll { now >= $0.host && now - $0.host > 5_000_000_000 }
        return remoteText.filter { now >= $0.host && now - $0.host <= age }.map(\.text)
    }

    // MARK: - inputs (also called directly by tests)

    func ms(_ h: HostTime) -> Int { h >= startHost ? Int((h - startHost) / 1_000_000) : -Int((startHost - h) / 1_000_000) }
    func host(_ ms: Int) -> HostTime { startHost &+ HostTime(max(0, ms)) * 1_000_000 }
    var nowMs: Int { ms(clock()) }

    func onVolatile(_ text: String, through: HostTime? = nil) async {
        // Volatile and final streams have independent consumers. An already queued hypothesis
        // may arrive after its final, but must not repopulate the next sentence.
        if let through, let lastFinalThrough, through <= lastFinalThrough { return }
        let now = clock()
        sourceAudioThrough = through
        rejectPassthroughEcho(text: text, through: through, at: now)
        onAnalysis?(.init(stage: .asrUpdate, sentence: segmenter.sentence, at: now,
                          source: text, engine: engines.asr.id.name, audioThrough: through))
        await perform(segmenter.volatile(text, nowMs: ms(now)))
    }

    func onFinal(_ text: String, range: ClosedRange<HostTime>) async {
        if let lastFinalThrough, range.upperBound <= lastFinalThrough { return }
        lastFinalThrough = max(lastFinalThrough ?? 0, range.upperBound)
        let now = clock()
        sourceAudioThrough = range.upperBound
        rejectPassthroughEcho(text: text, through: range.upperBound, at: now)
        onAnalysis?(.init(stage: .asrUpdate, sentence: segmenter.sentence, at: now,
                          source: text, engine: engines.asr.id.name,
                          audioThrough: range.upperBound, audioFrom: range.lowerBound))
        await perform(segmenter.final(text, nowMs: ms(now)))
    }

    func tick() async {
        guard running else { return }
        let now = clock()
        await perform(segmenter.tick(nowMs: ms(now), silenceMs: ingest.silenceMs(now: now)))
    }

    private func perform(_ actions: [ListenSegmenter.Action]) async {
        for a in actions {
            switch a {
            case let .draft(sentence, text): startDraft(sentence, text)
            case let .finalize(sentence, trigger, throughMs):
                log.event("listen.finalize", ["sentence": .int(Int(sentence)), "trigger": .tag(trigger.rawValue)])
                if let s = stream {
                    let through = host(throughMs)
                    Task { await s.finalize(through: through) }
                }
            case let .sentenceFinal(f): sentenceFinal(f)
            }
        }
        let line = rejectedEcho?.sentence == segmenter.sentence ? "" : segmenter.sourceLine
        if line != lastSource {
            lastSource = line
            onUpdate(.source(line))
        }
    }

    // MARK: - drafts

    private func startDraft(_ sentence: UInt64, _ text: String) {
        guard !draftsPaused, rejectedEcho?.sentence != sentence, let apple = engines.apple else { return }
        if let d = draftJob {
            d.task.cancel()
            let old = d.job
            Task { await apple.cancel(old) }
        }
        let job = jobs.next()
        let req = MTRequest(job: job, session: session, text: text, isFinalChunk: false, priority: .p2Listen,
                            maxOutputTokens: profile.finalMT.maxOutputTokens)
        let t0 = clock()
        appleJobs.insert(job)
        let task = Task { [weak self] in
            let result = try? await apple.translate(req)
            await self?.appleFinished(job)
            guard let result, !Task.isCancelled else { return }
            await self?.draftDone(sentence, source: text, target: result.text, t0: t0)
        }
        draftJob = (job, task)
    }

    private func appleFinished(_ job: JobID) { appleJobs.remove(job) }

    private func draftDone(_ sentence: UInt64, source: String, target: String, t0: HostTime) {
        log.event("mt.draft", ["sentence": .int(Int(sentence)), "ms": .int(HostClock.ms(t0, to: clock()))])
        // Only an open sentence shows drafts; a frozen final is never overwritten.
        guard running, !draftsPaused, sentence == segmenter.sentence, rejectedEcho?.sentence != sentence else { return }
        drafts[sentence] = (source, target)
        onUpdate(.draft(sentence: sentence, text: target))
    }

    // MARK: - finals

    private func sentenceFinal(_ f: ListenSegmenter.SentenceFinal) {
        guard running else { return }
        onAnalysis?(.init(stage: .sentenceFinal, sentence: f.sentence, at: host(f.finalAtMs),
                          source: f.text, engine: engines.asr.id.name))
        draftJob?.task.cancel()
        draftJob = nil
        log.event("listen.sentence", ["sentence": .int(Int(f.sentence)), "trigger": .tag(f.trigger.rawValue),
                                      "words": .int(FinalizeTrigger.wordCount(f.text)),
                                      "final_timeout": .bool(f.finalTimeout),
                                      "trigger_to_final_ms": .int(f.finalAtMs - f.triggerAtMs),
                                      "first_word_to_trigger_ms": .int(f.firstWordAtMs.map { f.triggerAtMs - $0 } ?? -1)])
        let decision = rejectedEcho?.sentence == f.sentence ? rejectedEcho!.decision
            : echo.decide(text: f.text, startMs: sourceAudioThrough.map(ms) ?? f.firstWordAtMs ?? f.triggerAtMs,
                          echoScore: echoScore(forAudioThrough: sourceAudioThrough, at: clock()))
        if rejectedEcho?.sentence == f.sentence { rejectedEcho = nil }
        sourceAudioThrough = nil
        if case let .drop(reason, overlap) = decision {
            log.event("listen.echo_drop", ["sentence": .int(Int(f.sentence)), "reason": .tag(reason.rawValue), "overlap": .double(overlap)])
            drafts[f.sentence] = nil
            onUpdate(.dropped(sentence: f.sentence))
            return
        }
        finalsInFlight += 1
        remoteText.append((clock(), f.text))
        _ = recentRemoteText(withinS: 5)
        var work = f
        var replaces: UInt64?
        var correctionDeadline: HostTime?
        if lang == .de, profile.deLookback.enabled, let previous = previousFinal,
           !previous.revised, previous.id + 1 == f.sentence,
           clock() >= previous.at, clock() - previous.at <= UInt64(profile.deLookback.windowMs) * 1_000_000,
           Self.startsGermanContinuation(f.text) {
            work.text = previous.source.trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")) + " " + f.text
            replaces = previous.id
            correctionDeadline = previous.at + UInt64(profile.deLookback.windowMs) * 1_000_000
            previousFinal?.revised = true
        }
        let final = work, replacement = replaces, expires = correctionDeadline
        finalTasks[f.sentence] = Task { await self.finalize(final, replacing: replacement, correctionDeadline: expires, original: f) }
    }

    private func finalize(_ f: ListenSegmenter.SentenceFinal, replacing replacement: UInt64? = nil,
                          correctionDeadline: HostTime? = nil, original: ListenSegmenter.SentenceFinal? = nil) async {
        defer { finalsInFlight -= 1; finalTasks[f.sentence] = nil }
        await renderFinal(f, replacing: replacement, correctionDeadline: correctionDeadline, original: original)
    }

    private func renderFinal(_ f: ListenSegmenter.SentenceFinal, replacing replacement: UInt64? = nil,
                             correctionDeadline: HostTime? = nil, original: ListenSegmenter.SentenceFinal? = nil) async {
        guard running, !Task.isCancelled else { return }
        let deadlineMs = f.triggerAtMs + profile.finalMT.deadlineMs
        var source = f.text

        // Second pass (off by default): must land within secondPassBudgetMs of the trigger.
        if replacement == nil, profile.secondPassASR, let sp = engines.secondPass,
           let clip = ingest.clip(from: host((f.firstWordAtMs ?? f.triggerAtMs) - 300), to: host(f.triggerAtMs)) {
            let job = jobs.next()
            secondPassJobs.insert(job)
            defer { secondPassJobs.remove(job) }
            let budget = host(f.triggerAtMs + profile.finalMT.secondPassBudgetMs)
            if let r = try? await sp.transcribe(clip, hint: lang, context: history.last?.turn.source, job: job,
                                                priority: .p2Listen, deadline: budget),
               clock() <= budget, !r.text.isEmpty {
                source = r.text
                log.event("asr.second_pass", ["sentence": .int(Int(f.sentence)), "used": true])
            } else {
                await sp.cancel(job)
                log.event("asr.second_pass", ["sentence": .int(Int(f.sentence)), "used": false])
            }
        }

        guard running, !Task.isCancelled else { return }

        // Apple starts at once: ready by the deadline (p95 ≈ 0.34 s, M0-T11). A draft of exactly
        // this text is reused.
        let apple = engines.apple
        let reuse = drafts[f.sentence].flatMap { $0.source == source ? $0.target : nil }
        drafts[f.sentence] = nil
        let appleJob = jobs.next()
        let appleReq = MTRequest(job: appleJob, session: session, text: source, isFinalChunk: true, priority: .p2Listen,
                                 maxOutputTokens: profile.finalMT.maxOutputTokens)
        if apple != nil { appleJobs.insert(appleJob) }
        let appleTask: Task<String?, Never> = Task {
            if let reuse { return reuse }
            guard let apple else { return nil }
            return try? await apple.translate(appleReq).text
        }
        defer { appleTask.cancel(); appleJobs.remove(appleJob) }

        var text: String?
        var engineTag = "apple"
        if !appleForThisMeeting, let primary = engines.primary {
            let job = jobs.next()
            let req = MTRequest(job: job, session: session, text: source, isFinalChunk: true, priority: .p2Listen,
                                deadline: host(deadlineMs), maxOutputTokens: profile.finalMT.maxOutputTokens,
                                history: history.suffix(2).map(\.turn))
            let call = Task { try await primary.translate(req) }
            let remaining = max(0, deadlineMs - nowMs)
            let wait = Task { await Race.first(call, withinMs: remaining) }
            primaryWaits[job] = wait
            let outcome = await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
            primaryWaits[job] = nil
            guard running, !Task.isCancelled else {
                call.cancel()
                await primary.cancel(job)
                await apple?.cancel(appleJob)
                return
            }
            if appleForThisMeeting {
                call.cancel()
                await primary.cancel(job)
            } else {
                switch outcome {
                case let .value(r):
                    let candidate = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.isEmpty || candidate.caseInsensitiveCompare("<none>") == .orderedSame {
                        log.event("mt.fail", ["sentence": .int(Int(f.sentence)), "reason": .tag("empty")])
                        report(.appleFallback(reason: "empty"))
                    } else {
                        text = candidate
                        engineTag = r.engine.placement == .network ? "openai" : r.engine.name
                        report(.openAI)
                    }
                case let .failure(e):
                    let tag = Self.reasonTag(e)
                    log.event("mt.fail", ["sentence": .int(Int(f.sentence)), "reason": .tag(tag)])
                    report(.appleFallback(reason: tag.hasPrefix("cloud:") ? String(tag.dropFirst(6)) : tag))
                case .timeout:
                    call.cancel()
                    await primary.cancel(job)
                    log.event("mt.late", ["sentence": .int(Int(f.sentence)), "deadline_ms": .int(profile.finalMT.deadlineMs)])
                    report(.appleFallback(reason: "deadline"))
                }
            }
            if text != nil {
                // No suspension between accepting a cloud result and publishing it: a user's
                // Apple-only switch cannot land after selection but before the subtitle.
                appleTask.cancel()
                if let apple { Task { await apple.cancel(appleJob) } }
            }
        }
        var approx = false
        if text == nil {
            approx = true
            text = await withTaskCancellationHandler { await appleTask.value } onCancel: { appleTask.cancel() }
            if text == nil { engineTag = "none"; text = source }   // §4.2 draft fallback: show the source
        }
        guard running, !Task.isCancelled else { return }
        // A correction that missed the three-second display window must not rewrite history.
        // Translate the new fragment normally instead, retaining its own sentence identity.
        if let correctionDeadline, clock() > correctionDeadline, let original {
            await renderFinal(original)
            return
        }
        let out = text ?? source
        let numberWarning = NumberGuard.check(source: out, target: source, targetLang: lang, glossary: glossary()).hardMismatch
        let historyID = replacement ?? f.sentence
        history.removeAll { $0.sentence == historyID }
        history.append((historyID, MTTurn(source: source, target: out)))
        history.sort { $0.sentence < $1.sentence }
        if history.count > 2 { history.removeFirst(history.count - 2) }
        let completedAt = clock(), completedMs = ms(completedAt)
        log.event("mt.final", ["sentence": .int(Int(f.sentence)), "engine": .tag(engineTag), "approx": .bool(approx),
                               "trigger_to_text_ms": .int(completedMs - f.triggerAtMs), "number_warning": .bool(numberWarning),
                               "met_deadline": .bool(completedMs <= deadlineMs)])
        onAnalysis?(.init(stage: .mtCompleted, sentence: historyID, at: completedAt,
                          source: source, translation: out, engine: engineTag, numberWarning: numberWarning))
        onTranscript(source, out, completedAt)
        if let replacement {
            lookbackRevisions += 1
            log.event("listen.de_lookback", ["sentence": .int(Int(replacement)), "revisions": .int(1)])
            onUpdate(.dropped(sentence: f.sentence))
            onUpdate(.final(sentence: replacement, text: out, source: source, approx: approx, numberWarning: numberWarning))
        } else {
            if previousFinal == nil || f.sentence > previousFinal!.id {
                previousFinal = (f.sentence, source, completedAt, false)
            }
            onUpdate(.final(sentence: f.sentence, text: out, source: source, approx: approx, numberWarning: numberWarning))
        }
    }

    static func startsGermanContinuation(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        guard !text.isEmpty else { return false }
        tagger.setLanguage(.german, range: text.startIndex..<text.endIndex)
        var result = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let first = String(text[range]).lowercased()
            result = tag == .verb || ["ab", "an", "auf", "aus", "bei", "ein", "fest", "her", "hin", "los", "mit", "nach", "vor", "weg", "weiter", "zu", "zurück", "zusammen"].contains(first)
            return false
        }
        return result
    }

    /// Only changes are reported.
    private func report(_ t: ListenTranslation) {
        guard t != translation else { return }
        translation = t
        onTranslation(t)
    }

    static func reasonTag(_ e: any Error) -> String {
        if let m = e as? MTError, case let .cloudUnavailable(r) = m { return "cloud:" + r }
        return String(describing: type(of: e))
    }

    // MARK: - test hooks

    var openSentence: UInt64 { segmenter.sentence }
    var pendingFinals: Int { finalsInFlight }
}

/// First of a task's result and a timeout.
enum Race {
    enum Outcome<T: Sendable>: Sendable { case value(T), failure(any Error), timeout }

    static func first<T: Sendable>(_ task: Task<T, any Error>, withinMs ms: Int) async -> Outcome<T> {
        let once = Once<Outcome<T>>()
        return await withTaskCancellationHandler { await withCheckedContinuation { c in
            once.set(c)
            Task {
                do { once.resume(.value(try await task.value)) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(ms))
                once.resume(.timeout)
            }
        } } onCancel: {
            task.cancel()
            once.resume(.failure(CancellationError()))
        }
    }

    final class Once<V: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var c: CheckedContinuation<V, Never>?
        private var done = false
        private var early: V?
        func set(_ c: CheckedContinuation<V, Never>) {
            lock.lock()
            if done, let v = early { lock.unlock(); c.resume(returning: v); return }
            self.c = c
            lock.unlock()
        }
        func resume(_ v: V) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            if let c { self.c = nil; lock.unlock(); c.resume(returning: v) } else { early = v; lock.unlock() }
        }
    }
}
