import Foundation
import Security

/// The auth token for your proxy service, in a Keychain item shared between the
/// container app and the keyboard extension.
///
/// The App Group identifier doubles as the Keychain access group, which avoids
/// hard-coding a team-prefixed string that changes with the signing identity.
///
/// `kSecAttrAccessibleAfterFirstUnlock` rather than `WhenUnlocked`: a keyboard can
/// be asked to render before the first foreground unlock of a session, and a token
/// read that fails there looks to the user like being randomly signed out.
public enum KeychainStore {
    private static let service = "com.asre1212.dictation.auth"
    private static let account = "proxy-token"

    public static func loadToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    @discardableResult
    public static func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteToken() }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query = baseQuery()
        let updates: [String: Any] = [kSecValueData as String: data]

        switch SecItemUpdate(query as CFDictionary, updates as CFDictionary) {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        default:
            return false
        }
    }

    @discardableResult
    public static func deleteToken() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppGroup.identifier,
        ]
    }
}
