import Foundation

/// Transcript-vs-script comparison for the enrollment CER check (ARCHITECTURE.md:
/// "去标点后算 CER；CER ≤8%，语种 zh，且不缺整个分句"). Pure functions.
public enum TranscriptComparison {
    public struct Result: Sendable, Equatable {
        /// Character error rate against the normalized script (edits / script length).
        public let cer: Double
        /// Share of Han characters among the transcript's letters (0…1); language gate "zh".
        public let hanShare: Double
        /// Indices of script clauses whose characters are mostly unmatched (< 50%).
        public let missingClauses: [Int]

        public var languageIsZh: Bool { hanShare >= 0.8 }
    }

    /// Keeps letters and digits, drops punctuation, symbols and whitespace; lowercases Latin.
    public static func normalize(_ s: String) -> [Character] {
        var out: [Character] = []
        for scalar in s.unicodeScalars {
            let p = scalar.properties
            if p.isAlphabetic || p.numericType != nil {
                out.append(contentsOf: String(scalar).lowercased())
            }
        }
        return out
    }

    public static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { s in
            switch s.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: true
            default: false
            }
        }
    }

    /// Script clauses split at Chinese/Latin punctuation, normalized, empty ones dropped.
    public static func clauses(of text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "，。！？；、,.!?;:：")
        return text.components(separatedBy: separators)
            .map { String(normalize($0)) }
            .filter { !$0.isEmpty }
    }

    public static func compare(transcript: String, script: String) -> Result {
        let ref = normalize(script)
        let hyp = normalize(transcript)
        let letters = hyp.filter { $0.isLetter }
        let hanShare = letters.isEmpty ? 0 : Double(letters.filter(isHan).count) / Double(letters.count)

        let (distance, matched) = align(ref: ref, hyp: hyp)
        let cer = ref.isEmpty ? (hyp.isEmpty ? 0 : 1) : Double(distance) / Double(ref.count)

        // Map each normalized script character to its clause.
        var clauseOf: [Int] = []
        let clauseList = clauses(of: script)
        for (i, clause) in clauseList.enumerated() { clauseOf.append(contentsOf: Array(repeating: i, count: clause.count)) }
        var missing: [Int] = []
        if clauseOf.count == ref.count {
            for i in clauseList.indices {
                let positions = clauseOf.indices.filter { clauseOf[$0] == i }
                let hit = positions.filter { matched[$0] }.count
                if Double(hit) < 0.5 * Double(positions.count) { missing.append(i) }
            }
        }
        return Result(cer: cer, hanShare: hanShare, missingClauses: missing)
    }

    /// Levenshtein distance plus, for each reference position, whether an optimal alignment
    /// matched it exactly.
    static func align(ref: [Character], hyp: [Character]) -> (Int, [Bool]) {
        let n = ref.count, m = hyp.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let sub = d[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                    d[i][j] = min(sub, d[i - 1][j] + 1, d[i][j - 1] + 1)
                }
            }
        }
        var matched = [Bool](repeating: false, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            if ref[i - 1] == hyp[j - 1] && d[i][j] == d[i - 1][j - 1] {
                matched[i - 1] = true
                i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j - 1] + 1 {
                i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return (d[n][m], matched)
    }
}
