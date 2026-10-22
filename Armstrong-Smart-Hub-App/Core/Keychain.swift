import Foundation
import Security

/// Stores the hub session token in the Keychain, available after first unlock
/// so background refreshes keep working, and never synced off the device. It's
/// kept in the app group's access group, so the widgets can call the hub too.
enum Keychain {
    private static let service = "com.armstrong.hub.session"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: String) {
        delete(account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessGroup as String: SharedHub.appGroup,
            kSecValueData as String: Data(value.utf8),
        ]
        // Without the group (a build missing the app group), keep it to the app rather than lose it.
        if SecItemAdd(query as CFDictionary, nil) != errSecSuccess {
            query[kSecAttrAccessGroup as String] = nil
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
