import Foundation
import Security

/// Generic passwords in the Keychain (this device only, after first unlock):
/// the dev token and the signed-in session's tokens.
enum Keychain {
    private static let service = "com.scshafe.parley"

    static func data(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    /// Replace the item, or delete it when `data` is nil or empty.
    static func set(data: Data?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data, !data.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        data(account).map { String(decoding: $0, as: UTF8.self) }
    }

    static func set(_ value: String, for account: String) {
        set(data: Data(value.utf8), for: account)
    }
}
