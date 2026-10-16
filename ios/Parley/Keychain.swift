import Foundation
import os
import Security

/// Generic passwords in the Keychain (this device only, after first unlock):
/// the signed-in session's tokens.
enum Keychain {
    private static let service = "com.scshafe.parley"
    private static let log = Logger(subsystem: "com.scshafe.parley", category: "keychain")

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func data(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("read \(account, privacy: .public) failed: \(status)")
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    /// Replace the item in place (update, or add when there is none), or
    /// delete it when `data` is nil or empty. The old value is never deleted
    /// before the new one is written, so a failed write keeps it.
    @discardableResult
    static func set(data: Data?, for account: String) -> Bool {
        guard let data, !data.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                log.error("delete \(account, privacy: .public) failed: \(status)")
                return false
            }
            return true
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("write \(account, privacy: .public) failed: \(status)")
            return false
        }
        return true
    }

    static func get(_ account: String) -> String? {
        data(account).map { String(decoding: $0, as: UTF8.self) }
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        set(data: Data(value.utf8), for: account)
    }

    /// Every item of this app: the Keychain outlives a deleted app, so the
    /// first launch after a reinstall clears what the old install left.
    static func removeAll() {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("clear failed: \(status)")
        }
    }
}
