// l10n: zh-Hans (scripts/check-strings.sh)
import Foundation

extension Lang {
    public var title: String {
        switch self {
        case .zh: String(appLocalized: "中文")
        case .en: String(appLocalized: "英语")
        case .de: String(appLocalized: "德语")
        case .fr: String(appLocalized: "法语")
        }
    }
    public var shortCode: String { self == .zh ? String(appLocalized: "中") : rawValue.uppercased() }
}
