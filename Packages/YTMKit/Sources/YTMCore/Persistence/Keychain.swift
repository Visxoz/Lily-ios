import Foundation
import Security

/// Secrets (sign-in cookies, the Last.fm session) as device-only generic passwords.
enum Keychain {
    private static let service = "YTMusic"

    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    static func data(for key: String) -> Data? {
        var query = query(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Stores `data` under `key`, or deletes the item when `data` is nil.
    static func set(_ data: Data?, for key: String) {
        let query = query(key)
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        // Readable after first unlock, so songs resolve on the lock screen, and
        // never restored to another device from a backup.
        let update: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
        }
    }
}
