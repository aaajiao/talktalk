/// What a final still asks the viewer to read after replacing a draft already on screen. Shared
/// by the video caption view and the meeting/phone board.
public enum SubtitleFinalReading {
    /// A final that replaces a seen draft stays at least this long, unless its normal budget is shorter.
    public static let minimumSeconds = 1.5
    /// Text counts as rewritten, and is read in full, once this share of it is unread.
    public static let rewrittenShare = 0.6

    /// UTF-16 offsets of the non-space characters of `text` that a longest common subsequence
    /// with `seen` leaves unmatched. A shared prefix would charge everything after one early edit.
    public static func unreadOffsets(in text: String, seen: String) -> [Int] {
        let new = Array(text), old = Array(seen)
        let width = old.count + 1
        var longest = [Int](repeating: 0, count: (new.count + 1) * width)
        for i in new.indices.reversed() {
            for j in old.indices.reversed() {
                longest[i * width + j] = new[i] == old[j]
                    ? longest[(i + 1) * width + j + 1] + 1
                    : max(longest[(i + 1) * width + j], longest[i * width + j + 1])
            }
        }
        var unread: [Int] = []
        var offset = 0, j = 0
        for i in new.indices {
            while j < old.count, new[i] != old[j], longest[(i + 1) * width + j] < longest[i * width + j + 1] { j += 1 }
            if j < old.count, new[i] == old[j] {
                j += 1
            } else if !new[i].isWhitespace {
                unread.append(offset)
            }
            offset += new[i].utf16.count
        }
        return unread
    }

    /// The characters to budget for `text` when `unread` of them are new to the viewer.
    public static func chargedCharacters(unread: Int, in text: String) -> Int {
        let letters = text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
        guard letters > 0, Double(unread) / Double(letters) >= rewrittenShare else { return unread }
        return text.count
    }
}
