import Foundation
import Security

/// Injected so a harness can hold tokens without touching the real Keychain.
protocol ExtensionOAuthTokenStore: Sendable {
    func get(account: String) -> String?
    func set(_ value: String, account: String) -> Bool
    func remove(account: String) -> Bool
    func removeAll(prefix: String, exactMatch: String)
}

struct KeychainOAuthTokenStore: ExtensionOAuthTokenStore {
    private let serviceName = "com.tinycast.extensions.oauth"

    private func query(account: String? = nil, _ extra: [CFString: Any] = [:]) -> CFDictionary {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: serviceName]
        if let account { query[kSecAttrAccount] = account }
        return query.merging(extra) { $1 } as CFDictionary
    }

    func get(account: String) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query(account: account, [kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]), &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let attributes: [CFString: Any] = [
            kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemUpdate(query(account: account), attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        return SecItemAdd(query(account: account, attributes), nil) == errSecSuccess
    }

    func remove(account: String) -> Bool {
        let status = SecItemDelete(query(account: account))
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func removeAll(prefix: String, exactMatch: String) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query([kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]), &item)
        guard status == errSecSuccess, let items = item as? [[String: Any]] else { return }
        for attributes in items {
            guard let account = attributes[kSecAttrAccount as String] as? String,
                account == exactMatch || account.hasPrefix(prefix)
            else { continue }
            SecItemDelete(query(account: account))
        }
    }
}

/// Secure storage for extension OAuth tokens, keyed by extension name and provider.
enum ExtensionOAuthKeychain {
    nonisolated(unsafe) static var store: ExtensionOAuthTokenStore = KeychainOAuthTokenStore()

    static func accountKey(extensionName: String, providerId: String?) -> String {
        guard let providerId, !providerId.isEmpty else { return extensionName }
        return "\(extensionName):\(providerId)"
    }

    static func getTokens(extensionName: String, providerId: String?) -> String? {
        store.get(account: accountKey(extensionName: extensionName, providerId: providerId))
    }

    @discardableResult
    static func setTokens(_ jsonString: String, extensionName: String, providerId: String?) -> Bool {
        store.set(jsonString, account: accountKey(extensionName: extensionName, providerId: providerId))
    }

    @discardableResult
    static func removeTokens(extensionName: String, providerId: String?) -> Bool {
        store.remove(account: accountKey(extensionName: extensionName, providerId: providerId))
    }

    static func removeAllTokens(extensionName: String) {
        store.removeAll(prefix: "\(extensionName):", exactMatch: extensionName)
    }
}
