import Foundation
import Security
import Synchronization

/// The only code that reads or writes the OpenAI API key (ARCHITECTURE.md, "数据与隐私").
///
/// Login (file-based) keychain, `kSecClassGenericPassword`, not synchronizable. No
/// `kSecAttrAccessible` and no `kSecUseDataProtectionKeychain`: an ad-hoc signed app has no
/// keychain-access-groups entitlement (expected -34018; checked in M0-T4 ⑧). The default ACL
/// trusts the app that created the item, so the item must be created by the app itself
/// (settings paste box, or `--bench store-key` in the dev build), never by `security`.
///
/// The value is never logged, never echoed and never written anywhere except the Keychain.
public struct KeychainSecret: Sendable {
    public let service: String
    public let account: String
    public let label: String

    private static let writes = Atomic<UInt64>(0)
    /// Changes after every save or delete in this process, so a held copy can tell it is stale.
    public static var writeGeneration: UInt64 { writes.load(ordering: .sequentiallyConsistent) }
    private static func noteWrite() { writes.add(1, ordering: .sequentiallyConsistent) }

    public init(service: String, account: String = "api-key", label: String) {
        self.service = service
        self.account = account
        self.label = label
    }

    /// The app's OpenAI entry for a bundle id: `<bundle id>.openai`, account `api-key`.
    /// `com.aaajiao.talktalk` -> `com.aaajiao.talktalk.openai`;
    /// `com.aaajiao.talktalk.dev` -> `com.aaajiao.talktalk.dev.openai`.
    public static func openAI(bundleID: String) -> KeychainSecret? {
        guard bundleID == "com.aaajiao.talktalk" || bundleID == "com.aaajiao.talktalk.dev" else { return nil }
        let label = bundleID.hasSuffix(".dev") ? "TalkTalk Dev OpenAI API key" : "TalkTalk OpenAI API key"
        return KeychainSecret(service: bundleID + ".openai", label: label)
    }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let operation: String
        public let status: OSStatus
        public var description: String { "\(operation) failed: OSStatus \(status)" }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// Adds the item, or updates its data if it already exists.
    public func store(_ secret: Data) throws {
        defer { Self.noteWrite() }
        var add = baseQuery
        add[kSecAttrLabel as String] = label
        add[kSecValueData as String] = secret
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw Failure(operation: "SecItemAdd", status: status) }
        let update: [String: Any] = [kSecValueData as String: secret, kSecAttrLabel as String: label]
        let ustatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard ustatus == errSecSuccess else { throw Failure(operation: "SecItemUpdate", status: ustatus) }
    }

    /// Asks only whether the item exists; requests neither data nor attributes.
    public func exists() -> Bool {
        var q = baseQuery
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func read() throws -> Data {
        var q = baseQuery
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            throw Failure(operation: "SecItemCopyMatching", status: status)
        }
        return data
    }

    public func delete() throws {
        defer { Self.noteWrite() }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "SecItemDelete", status: status)
        }
    }
}

/// Shape checks on a pasted key, done without ever echoing it.
public enum APIKeyShape {
    /// Trims whitespace and newlines that paste often adds.
    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil when acceptable, otherwise a reason that does not contain any part of the key.
    public static func problem(_ key: String) -> String? {
        if key.isEmpty { return "empty" }
        if !key.hasPrefix("sk-") { return "does not start with sk-" }
        if key.count < 40 { return "shorter than 40 characters" }
        if key.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7e }) {
            return "contains whitespace or non-ASCII characters"
        }
        return nil
    }

    /// What the settings page may show: `sk-…` plus the last 4 characters.
    public static func masked(_ key: String) -> String {
        guard key.count > 8 else { return "sk-…" }
        return "sk-…" + key.suffix(4)
    }
}
