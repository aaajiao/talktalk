import Foundation

/// Words a spoken sentence does not end on. A speaker who stops after one of them is hesitating,
/// and the period the recognizer put there is not believed. These are closed lists, and a word
/// that is missing behaves as if this type did not exist, so anything that can end a sentence is
/// left out: en "to", "about", "with", "I"; de "ein" and "einen", verb particles.
enum UnfinishedEnding {
    private static let en: Set<String> = [
        "a", "an", "the", "of", "into", "and", "or", "but", "because", "if",
        "my", "your", "our", "their", "its",
        "um", "uh", "er", "erm",
    ]
    private static let de: Set<String> = ["und", "weil", "dass", "wenn", "von", "für", "äh", "ähm", "öh", "hm"]
    private static let zh = ["因为", "所以", "但是", "如果", "而且", "然后", "嗯", "呃"]
    private static let fillers: Set<String> = ["um", "uh", "er", "erm", "äh", "ähm", "öh", "hm"]
    private static let zhFillers: Set<Character> = ["嗯", "呃"]

    /// `text` ends on such a word, with a period or with no punctuation after it. Only fillers
    /// make a complete reply, "?" or "!" means the speaker finished, and "A." or "ER." is a label.
    static func matches(_ text: String, lang: Lang) -> Bool {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if let last = body.last, last == "." || last == "。" { body.removeLast() }
        guard let last = body.last, last.isLetter else { return false }
        if lang == .zh {
            guard zh.contains(where: { body.hasSuffix($0) }) else { return false }
            return !body.allSatisfy { zhFillers.contains($0) || $0.isPunctuation || $0.isWhitespace }
        }
        let words = body.split(whereSeparator: \.isWhitespace)
        guard let tail = words.last, tail.contains(where: \.isLowercase) else { return false }
        let bare = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        guard let word = bare.last, (lang == .de ? de : en).contains(word) else { return false }
        return !bare.allSatisfy(fillers.contains)
    }
}
