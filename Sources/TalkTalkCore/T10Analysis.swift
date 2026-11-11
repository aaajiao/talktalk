import Foundation

/// T10 (ARCHITECTURE.md) pass rules that do not need the Speech framework, so they are unit
/// tested: the per-sentence lag of ① (from the speech end, on the wall clock), its drift (rule C6;
/// C5 reported only), and the MLX-loaded / idle split of ④.
public enum T10Analysis {
    /// C5, reported beside rule C6 (ARCHITECTURE.md T10 ①), not judged: per-sentence lags are
    /// bucketed per `bucketS` of feed time (from the common feed start); bucket 0 is warm-up; the
    /// baseline is `stat` over the samples of buckets 1...`baselineBuckets` pooled (not a median of
    /// bucket values: with two buckets a lower median is their minimum); every later bucket's
    /// `stat` must stay within `toleranceMs` of it. A last bucket with fewer than half the median
    /// bucket n (a run cut short) is listed but not judged.
    public struct LagDrift: Equatable, Sendable {
        public enum Stat: String, Sendable, CaseIterable {
            case p50, p90, mean
            func of(_ xs: [Int]) -> Int {
                switch self {
                case .p50: return nearestRank(xs.sorted(), 0.5)
                case .p90: return nearestRank(xs.sorted(), 0.9)
                case .mean: return Int((Double(xs.reduce(0, +)) / Double(xs.count)).rounded())
                }
            }
        }
        public struct Bucket: Equatable, Sendable {
            public var index: Int
            public var n: Int
            public var p50: Int
            public var p90: Int
            public var mean: Int
            /// The rule's statistic for this bucket.
            public var value: Int
            public init(index: Int, n: Int, p50: Int, p90: Int, mean: Int, value: Int) {
                self.index = index; self.n = n; self.p50 = p50; self.p90 = p90; self.mean = mean; self.value = value
            }
        }
        public var stat: Stat
        public var buckets: [Bucket]
        public var baselineMs: Int?
        /// Largest |bucket value − baseline| over the judged buckets after the baseline window.
        public var maxDeviationMs: Int?
        public var pass: Bool?
        /// Index of a short last bucket left out of the judgement.
        public var skippedTail: Int?

        public static func evaluate(_ samples: [(feedS: Double, lagMs: Int)], bucketS: Double = 600,
                                    baselineBuckets: Int = 1, toleranceMs: Int = 100, stat: Stat = .p90) -> LagDrift {
            var byBucket: [Int: [Int]] = [:]
            for s in samples where s.feedS >= 0 { byBucket[Int(s.feedS / bucketS), default: []].append(s.lagMs) }
            let buckets = byBucket.keys.sorted().map { i -> Bucket in
                let xs = byBucket[i]!
                return Bucket(index: i, n: xs.count, p50: Stat.p50.of(xs), p90: Stat.p90.of(xs), mean: Stat.mean.of(xs), value: stat.of(xs))
            }
            var r = LagDrift(stat: stat, buckets: buckets, baselineMs: nil, maxDeviationMs: nil, pass: nil, skippedTail: nil)
            let pool = (1...max(1, baselineBuckets)).flatMap { byBucket[$0] ?? [] }
            guard !pool.isEmpty else { return r }
            r.baselineMs = stat.of(pool)
            var later = buckets.filter { $0.index > baselineBuckets }
            if let last = later.last, later.count >= 1 {
                let medianN = median(buckets.map(\.n))
                if 2 * last.n < medianN { r.skippedTail = last.index; later.removeLast() }
            }
            guard !later.isEmpty, let base = r.baselineMs else { return r }
            let dev = later.map { abs($0.value - base) }.max()!
            r.maxDeviationMs = dev
            r.pass = dev <= toleranceMs
            return r
        }
    }

    /// ① lag per sentence fed, from the sentence's speech end, timed on the wall clock.
    ///
    /// Volatile results carry no per-word times (fourth smoke: one timed run per volatile, ending
    /// at the audio fed at receipt) and come in batches on a ~960 ms grid of fed audio, so the
    /// reference is the sentence's energy speech end (`speechEndAudio`): wall time its last voiced
    /// chunk was handed over (`FeedTable`). The hit is the first result that holds a word of the
    /// sentence (words go to the sentence whose audio window [audioStart, next audioStart) holds
    /// their end, whatever window the result arrives in) and covers the speech end: a volatile
    /// whose range end (else the audio fed at receipt) ≥ speech end, or a final holding the
    /// sentence's last final word (tolerance 0). `completionMs` = hit arrival − that wall time;
    /// `onsetMs` = first result with any word of the sentence − wall time of the onset chunk.
    /// Only sentences with a final (`lastFromFinal`) enter the ① rule.
    public struct ClipLag: Equatable, Sendable {
        public var identity: Int
        /// Wall time of the clip start (for bucketing).
        public var start: Double
        public var onsetMs: Int?
        public var completionMs: Int?
        public var lastFromFinal: Bool?
        public var hitIsFinal: Bool?
        public var lastWordEnd: Double?
        public var hitIndex: Int?
        /// Text units in the hit, and in the sentence's finals (counts only: zh finals often span
        /// two sentences and volatile units are cumulative, so the two do not compare).
        public var hitUnits: Int?
        public var finalUnits: Int?
        /// The result that first holds the whole sentence: among the volatiles covering the speech
        /// end and fed before the next sentence's onset, the first reaching their largest unit
        /// count (or the first final with the last word, if earlier). A batch's results arrive
        /// within ~12 ms with growing units, so the hit is often the batch's first, not complete.
        public var completeIndex: Int?
        public var completeMs: Int?
        /// The complete result came a batch (~960 ms of fed audio) or more after the hit.
        public var lateBatch: Bool?
    }

    public struct ResultEvent: Equatable, Sendable {
        public var t: Double
        public var isFinal: Bool
        public var wordEnds: [Double]
        /// Audio seconds fed when the result was received (one chunk of race: read after yield).
        public var fedAtReceipt: Double
        public var rangeEnd: Double?
        /// Text units of the whole result (a count only).
        public var units: Int
        public init(t: Double, isFinal: Bool, wordEnds: [Double], fedAtReceipt: Double = .infinity, rangeEnd: Double? = nil, units: Int = 0) {
            self.t = t; self.isFinal = isFinal; self.wordEnds = wordEnds; self.fedAtReceipt = fedAtReceipt; self.rangeEnd = rangeEnd
            self.units = units
        }
    }

    public struct ClipTimes: Equatable, Sendable {
        /// Audio seconds (the analyzer's timeline).
        public var audioStart: Double
        public var onsetAudio: Double
        public var speechEndAudio: Double
        /// Which sentence of the rotation (k % clips.count).
        public var identity: Int
        public init(audioStart: Double, onsetAudio: Double, speechEndAudio: Double, identity: Int = 0) {
            self.audioStart = audioStart; self.onsetAudio = onsetAudio; self.speechEndAudio = speechEndAudio; self.identity = identity
        }
    }

    /// Audio start of every chunk fed (ascending) and the wall time it was handed over.
    public struct FeedTable: Equatable, Sendable {
        public var audio: [Double] = []
        public var wall: [Double] = []
        public init() {}
        public init(audio: [Double], wall: [Double]) { self.audio = audio; self.wall = wall }
        public mutating func append(audio a: Double, wall w: Double) { audio.append(a); wall.append(w) }

        /// Index of the last chunk whose start satisfies `pred` (audio is ascending).
        public func last(_ pred: (Double) -> Bool) -> Int? {
            var lo = 0, hi = audio.count   // first index where pred fails
            while lo < hi { let m = (lo + hi) / 2; if pred(audio[m]) { lo = m + 1 } else { hi = m } }
            return lo == 0 ? nil : lo - 1
        }
        /// Audio ending at x was fed with the chunk that holds (x − ε): the last chunk starting before x.
        public func wallForWordEnd(_ x: Double) -> Double? { last { $0 < x }.map { wall[$0] } }
        /// Speech starting at x was fed with the chunk that holds x: the last chunk starting at or before x.
        public func wallForOnset(_ x: Double) -> Double? { last { $0 <= x }.map { wall[$0] } }
    }

    /// Below this a lag is a fault, not noise (one chunk is handed over at its first sample's time).
    public static let negativeFaultMs = -20

    public static func clipLags(events: [ResultEvent], clips: [ClipTimes], feeds: FeedTable) -> [ClipLag] {
        let order = events.indices.sorted { events[$0].t < events[$1].t }
        return clips.enumerated().map { i, c in
            let lo = c.audioStart, hi = i + 1 < clips.count ? clips[i + 1].audioStart : .infinity
            func words(_ e: ResultEvent) -> [Double] { e.wordEnds.filter { $0 >= lo && $0 < hi } }
            var lag = ClipLag(identity: c.identity, start: feeds.wallForOnset(c.audioStart) ?? 0)
            let finals = order.filter { events[$0].isFinal && !words(events[$0]).isEmpty }
            let finalMax = finals.flatMap { words(events[$0]) }.max()
            guard let last = finalMax ?? order.flatMap({ words(events[$0]) }).max() else { return lag }
            lag.lastWordEnd = last
            lag.lastFromFinal = finalMax != nil
            if finalMax != nil { lag.finalUnits = finals.map { events[$0].units }.reduce(0, +) }
            if let f = order.first(where: { !words(events[$0]).isEmpty }), let w = feeds.wallForOnset(c.onsetAudio) {
                lag.onsetMs = ms(events[f].t - w)
            }
            func covers(_ e: ResultEvent) -> Bool {
                let ws = words(e)
                guard !ws.isEmpty else { return false }
                if e.isFinal { return ws.max()! >= last - 1e-9 }
                return (e.rangeEnd ?? e.fedAtReceipt) >= c.speechEndAudio - 1e-6
            }
            if let h = order.first(where: { covers(events[$0]) }) {
                lag.hitIndex = h
                lag.hitIsFinal = events[h].isFinal
                lag.hitUnits = events[h].units
                let refWall = feeds.wallForWordEnd(c.speechEndAudio)
                if let w = refWall { lag.completionMs = ms(events[h].t - w) }
                // Whole sentence: volatiles covering the speech end, before the next onset.
                let nextOnset = i + 1 < clips.count ? clips[i + 1].onsetAudio : .infinity
                let cands = order.filter { k in
                    let e = events[k]
                    guard !e.isFinal, let r = e.rangeEnd else { return false }
                    return r >= c.speechEndAudio - 1e-6 && r < nextOnset && e.t >= events[h].t
                }
                var complete = h
                if let maxU = cands.map({ events[$0].units }).max(), let k = cands.first(where: { events[$0].units == maxU }) { complete = k }
                if let f = order.first(where: { events[$0].isFinal && covers(events[$0]) }), events[f].t < events[complete].t { complete = f }
                lag.completeIndex = complete
                if let w = refWall { lag.completeMs = ms(events[complete].t - w) }
                func audioOf(_ e: ResultEvent) -> Double { e.isFinal ? e.fedAtReceipt : (e.rangeEnd ?? e.fedAtReceipt) }
                lag.lateBatch = audioOf(events[complete]) - audioOf(events[h]) > 0.48
            }
            return lag
        }
    }

    /// ① rule C6 (ARCHITECTURE.md T10 ①): the lag split into the parts that can drift, each
    /// judged on its own. lag = (hit range end − speech end: the wait for the next ~960 ms grid
    /// point, uniform, does not drift) + delivery delay + backlog + 960 × (late batch). Same buckets
    /// as C5: `bucketS` of feed time, bucket 0 warm-up, baseline = buckets 1...`baselineBuckets`
    /// pooled, later buckets judged; both locales are judged by the caller.
    /// a. delivery p90 within `deliveryMs` of the baseline; b. backlog max ≤ `backlogMs` (absolute);
    /// c. median batch gap within `gapMs` of the baseline; d. late-batch share ≤ baseline +
    /// `lateBatchPoints`; e. complete-lag p90 within `completeMs` of the baseline (the wide guard).
    public struct C6: Equatable, Sendable {
        public struct Bucket: Equatable, Sendable {
            public var index: Int
            public var clips: Int
            public var deliveryP90: Int?
            public var backlogMax: Int?
            public var medianBatchGap: Int?
            public var lateBatchFrac: Double?
            public var completeP90: Int?
        }
        public var buckets: [Bucket]
        public var baseline: Bucket?
        public var pass: Bool?
        /// Checks that failed (a–e), and where ("a@3": check a in bucket 3).
        public var failedChecks: [String]
        public var failures: [String]
        public var skippedTail: Int?

        public struct Inputs: Sendable {
            public var delivery: [(feedS: Double, ms: Int)] = []
            public var backlog: [(feedS: Double, ms: Int)] = []
            public var batchGaps: [(feedS: Double, ms: Int)] = []
            public var clips: [(feedS: Double, completeMs: Int, lateBatch: Bool)] = []
            public init() {}
        }

        static func stats(_ index: Int, _ inp: Inputs, _ inBucket: (Double) -> Bool) -> Bucket {
            let d = inp.delivery.filter { inBucket($0.feedS) }.map(\.ms)
            let b = inp.backlog.filter { inBucket($0.feedS) }.map(\.ms)
            let g = inp.batchGaps.filter { inBucket($0.feedS) }.map(\.ms)
            let c = inp.clips.filter { inBucket($0.feedS) }
            return Bucket(index: index, clips: c.count,
                          deliveryP90: d.isEmpty ? nil : LagDrift.Stat.p90.of(d),
                          backlogMax: b.max(),
                          medianBatchGap: g.isEmpty ? nil : median(g),
                          lateBatchFrac: c.isEmpty ? nil : Double(c.filter(\.lateBatch).count) / Double(c.count),
                          completeP90: c.isEmpty ? nil : LagDrift.Stat.p90.of(c.map(\.completeMs)))
        }

        public static func evaluate(_ inp: Inputs, bucketS: Double = 600, baselineBuckets: Int = 1,
                                    deliveryMs: Int = 100, backlogMs: Int = 100, gapMs: Int = 100,
                                    lateBatchPoints: Double = 0.10, completeMs: Int = 150) -> C6 {
            func bucket(_ x: Double) -> Int? { x >= 0 ? Int(x / bucketS) : nil }
            let all = Set(inp.delivery.map(\.feedS) + inp.backlog.map(\.feedS) + inp.batchGaps.map(\.feedS) + inp.clips.map(\.feedS))
                .compactMap(bucket)
            let indices = Array(Set(all)).sorted()
            let buckets = indices.map { i in stats(i, inp) { bucket($0) == i } }
            var r = C6(buckets: buckets, baseline: nil, pass: nil, failedChecks: [], failures: [], skippedTail: nil)
            let nb = max(1, baselineBuckets)
            let base = stats(-1, inp) { x in bucket(x).map { $0 >= 1 && $0 <= nb } ?? false }
            guard base.clips > 0 || base.deliveryP90 != nil else { return r }
            r.baseline = base
            var later = buckets.filter { $0.index > nb }
            if let last = later.last, 2 * last.clips < median(buckets.map(\.clips)) { r.skippedTail = last.index; later.removeLast() }
            guard !later.isEmpty else { return r }
            var failed = Set<String>()
            for b in later {
                func fail(_ k: String, _ why: String) { failed.insert(k); r.failures.append("\(k)@\(b.index): \(why)") }
                if let x = b.deliveryP90, let y = base.deliveryP90, abs(x - y) > deliveryMs { fail("a", "delivery p90 \(x) vs \(y)") }
                if let x = b.backlogMax, x > backlogMs { fail("b", "backlog max \(x)") }
                if let x = b.medianBatchGap, let y = base.medianBatchGap, abs(x - y) > gapMs { fail("c", "batch gap \(x) vs \(y)") }
                if let x = b.lateBatchFrac, let y = base.lateBatchFrac, x > y + lateBatchPoints + 1e-9 {
                    fail("d", "late batch \(Int((x * 100).rounded()))% vs \(Int((y * 100).rounded()))%")
                }
                if let x = b.completeP90, let y = base.completeP90, abs(x - y) > completeMs { fail("e", "complete p90 \(x) vs \(y)") }
            }
            r.failedChecks = failed.sorted()
            r.pass = failed.isEmpty
            return r
        }

        /// C6 inputs from one lane's results: delivery = receipt − hand-over of the chunk ending at
        /// the volatile's range end (feed table); backlog = audio fed at receipt − range end; batch
        /// gaps between volatiles with distinct range ends (in fed audio); per sentence with a
        /// final, the complete lag and whether it came a batch late. Times are wall seconds from
        /// `feedStart`.
        public static func inputs(events: [ResultEvent], lags: [ClipLag], feeds: FeedTable, feedStart: Double) -> Inputs {
            var inp = Inputs()
            let vol = events.filter { !$0.isFinal && $0.rangeEnd != nil }.sorted { $0.t < $1.t }
            var lastEnd: Double?
            for e in vol {
                let x = e.t - feedStart, r = e.rangeEnd!
                if let w = feeds.wallForWordEnd(r) { inp.delivery.append((x, ms(e.t - w))) }
                if e.fedAtReceipt.isFinite { inp.backlog.append((x, ms(e.fedAtReceipt - r))) }
                if let p = lastEnd, abs(r - p) > 1e-6, r > p { inp.batchGaps.append((x, ms(r - p))) }
                if lastEnd.map({ r > $0 + 1e-6 }) ?? true { lastEnd = r }
            }
            for l in lags where l.lastFromFinal == true {
                if let c = l.completeMs, let late = l.lateBatch { inp.clips.append((l.start - feedStart, c, late)) }
            }
            return inp
        }
    }

    /// Results holding a word that ends after the audio fed when they arrived (+ one chunk for the
    /// read-after-yield race): impossible for a correct pipeline.
    public static func causalFaults(_ events: [ResultEvent], chunkS: Double = 0.02) -> Int {
        events.filter { e in e.wordEnds.contains { $0 > e.fedAtReceipt + chunkS + 1e-6 } }.count
    }

    /// Lags below `negativeFaultMs`.
    public static func negative(_ lags: [ClipLag]) -> Int {
        lags.filter { ($0.completionMs ?? 0) < negativeFaultMs || ($0.onsetMs ?? 0) < negativeFaultMs }.count
    }

    /// A word run that counts: has a letter, digit or ideograph ("." and "。" alone do not).
    public static func isWord(_ s: String) -> Bool { textUnits(s) > 0 }

    /// Text units for zh and en/de alike: each CJK ideograph is one, each run of other letters or
    /// digits is one (punctuation and spaces are not counted).
    public static func textUnits(_ s: String) -> Int {
        var n = 0, inWord = false
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) {
                n += 1; inWord = false
            } else if CharacterSet.alphanumerics.contains(u) {
                if !inWord { n += 1; inWord = true }
            } else { inWord = false }
        }
        return n
    }

    public static func ms(_ s: Double) -> Int { Int((s * 1000).rounded()) }

    /// ④ "MLX 满载、空载各一半": items alternate in blocks (idle first), so both halves span the
    /// whole run and slow drift (thermal, page cache) does not land on one side only.
    public static func loaded(item index: Int, block: Int) -> Bool {
        guard block > 0 else { return false }
        return (index / block) % 2 == 1
    }

    static func nearestRank(_ sorted: [Int], _ q: Double) -> Int {
        sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count)).rounded(.up)) - 1))]
    }

    static func median(_ xs: [Int]) -> Int { nearestRank(xs.sorted(), 0.5) }
}
