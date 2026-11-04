import Foundation
import Security

/// The access token, in the keychain.
///
/// GroupMe tokens do not appear to rotate, so this is write-once in practice.
/// `.afterFirstUnlock` because background sync needs to read it while the phone
/// is locked; it does not need to be readable before the first unlock after boot.
actor TokenStore {
    static let shared = TokenStore()

    private let service = "sh.dunkirk.GroupMeNot"
    private let account = "access-token"
    private var cached: String?

    func token() -> String? {
        if let cached { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        cached = value
        return value
    }

    var isSignedIn: Bool { token() != nil }

    /// Whether the keychain took it. A refusal is rare and real: a session
    /// built on a token only this process holds is a session that ends at
    /// the next launch, with no way to say why.
    @discardableResult
    func save(_ token: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { return false }
        cached = token
        return true
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        cached = nil
    }
}
