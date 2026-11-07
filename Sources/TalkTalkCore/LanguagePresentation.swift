// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

extension Lang {
    public var title: String {
        switch self {
        case .zh: String(localized: "中文")
        case .en: String(localized: "英语")
        case .de: String(localized: "德语")
        }
    }
    public var shortCode: String { self == .zh ? String(localized: "中") : rawValue.uppercased() }
}
