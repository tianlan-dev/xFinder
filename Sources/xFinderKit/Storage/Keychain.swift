import Foundation
import Security

/// Secret storage abstraction (Keychain in the app, in-memory in tests).
public protocol SecretStore: AnyObject, Sendable {
    func read(_ account: String) -> String?
    func write(_ secret: String, for account: String) throws
    func delete(_ account: String)
}

/// Generic-password Keychain items under service `xFinder`.
public final class KeychainStore: SecretStore, @unchecked Sendable {
    public let service: String

    public init(service: String = xFinderKit.keychainService) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = baseQuery(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            q[kSecAttrLabel as String] = "xFinder (\(account))"
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw RemoteError.localIO("Keychain error \(addStatus)")
            }
        } else if status != errSecSuccess {
            throw RemoteError.localIO("Keychain error \(status)")
        }
    }

    public func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

/// In-memory secret store for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) { items = initial }

    public func read(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    public func write(_ secret: String, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = secret
    }

    public func delete(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }

    public var allAccounts: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.keys)
    }
}
