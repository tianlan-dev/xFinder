import Foundation

/// Shared accounts (`accounts.json`).
public struct AccountStore: Codable, Hashable, Sendable {
    public var accounts: [Account]

    public init(accounts: [Account] = []) { self.accounts = accounts }

    public static func load(from url: URL) -> AccountStore {
        (try? JSONFile.load(AccountStore.self, from: url)) ?? AccountStore()
    }

    public func save(to url: URL) throws { try JSONFile.save(self, to: url) }

    public func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Adds an account; duplicate names are numbered; without a key the password
    /// is always enabled.
    @discardableResult
    public mutating func add(_ account: Account) -> Account {
        var a = account
        a.name = uniqueName(a.name.isEmpty ? (a.username.isEmpty ? "Account" : a.username) : a.name, excluding: nil)
        if a.key.keyID == nil { a.usePassword = true }
        if a.key == .inherit { a.key = .none }
        accounts.append(a)
        return a
    }

    public mutating func update(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        var a = account
        a.name = uniqueName(a.name.isEmpty ? "Account" : a.name, excluding: a.id)
        if a.key.keyID == nil { a.usePassword = true }
        if a.key == .inherit { a.key = .none }
        accounts[i] = a
    }

    public mutating func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
    }

    public func uniqueName(_ base: String, excluding id: UUID?) -> String {
        let existing = Set(accounts.filter { $0.id != id }.map { $0.name.lowercased() })
        return SiteLibrary.uniqueName(base, existing: existing)
    }

    /// Matches by case-insensitive name plus exact username (used on import).
    public func match(name: String, username: String) -> Account? {
        accounts.first { $0.name.lowercased() == name.lowercased() && $0.username == username }
    }
}
