import Foundation
import Security

/// Stores the proxy auth token in the iOS Keychain — encrypted, OS-managed
/// storage for the one real secret in the app. Everything else (server node id,
/// port) is non-sensitive and lives in UserDefaults via @AppStorage.
///
/// Accessibility is `…AfterFirstUnlockThisDeviceOnly`: readable after the first
/// unlock following a boot (so it survives backgrounding), never synced to
/// iCloud, and never restored onto another device.
enum TokenStore {
    private static let account = "default"

    /// The proxy auth token — the primary credential.
    static let authTokenService = "com.example.flextunnel.authToken"
    /// The shared bearer token for custom relays — a separate secret so it
    /// survives launches alongside the auth token (custom relays only).
    static let relayTokenService = "com.example.flextunnel.relayAuthToken"

    /// Persist `token` under `service`, replacing any existing value. Empty
    /// strings are treated as a clear so we never store a blank secret.
    static func save(_ token: String, service: String = authTokenService) {
        guard !token.isEmpty, let data = token.data(using: .utf8) else {
            clear(service: service)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    /// Read back the token stored under `service`, or nil if none is set.
    static func load(service: String = authTokenService) -> String? {
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
              let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return token
    }

    /// Remove the token stored under `service`.
    static func clear(service: String = authTokenService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
