import Foundation

/// Creates a single telephone destination for an explicit user action. No call is placed here,
/// and the number is neither persisted nor logged. Formatting never becomes URL syntax.
public enum PhoneDialRequest {
    public static func url(for raw: String) -> URL? {
        var number = ""
        var digitCount = 0
        for scalar in raw.unicodeScalars {
            // Reject pasted multi-line lists and invisible/control characters, including tabs.
            if CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) { return nil }
            switch scalar.value {
            case 48...57:
                digitCount += 1
                guard digitCount <= 15 else { return nil }
                number.unicodeScalars.append(scalar)
            case 43: // One leading plus, after optional formatting whitespace.
                guard number.isEmpty else { return nil }
                number.append("+")
            case 40, 41, 45, 0x2010, 0x2011: // Parentheses, hyphen, nonbreaking hyphen.
                continue
            default:
                guard CharacterSet.whitespaces.contains(scalar) else { return nil }
            }
        }
        guard (3...15).contains(digitCount) else { return nil }
        return URL(string: "tel:" + number)
    }
}
