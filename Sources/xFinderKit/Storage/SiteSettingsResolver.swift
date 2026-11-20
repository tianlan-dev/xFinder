import Foundation

/// Effective connection settings after applying inheritance.
public struct ResolvedSiteSettings: Hashable, Sendable {
    public var username: String
    public var account: Account?
    public var key: SSHKeyEntry?
    public var authOrder: AuthOrder
    /// Key-only account: never send a password.
    public var keyOnly: Bool
    /// Keychain account name holding the password for this connection.
    public var passwordKeychainAccount: String
    /// Whether password authentication may be attempted.
    public var allowsPassword: Bool { !keyOnly }
}

/// Applies the inheritance rules:
///
/// | Setting    | Order                                                     |
/// |------------|-----------------------------------------------------------|
/// | Username   | account → site → folder → local user name (SFTP only)     |
/// | Account    | site's account; folder's only if the site has no username |
/// | Key        | site → folder → global default; account key when set      |
/// | Auth order | site → folder → account → global                          |
public struct SiteSettingsResolver: Sendable {
    public var library: SiteLibrary
    public var keys: KeyLibrary
    public var accounts: AccountStore
    public var settings: AppSettings
    public var localUserName: String

    public init(library: SiteLibrary, keys: KeyLibrary, accounts: AccountStore, settings: AppSettings,
                localUserName: String = NSUserName()) {
        self.library = library
        self.keys = keys
        self.accounts = accounts
        self.settings = settings
        self.localUserName = localUserName
    }

    public func resolveAccount(for site: Site) -> Account? {
        if let a = accounts.account(site.accountID) { return a }
        let siteUser = site.username.trimmingCharacters(in: .whitespaces)
        if siteUser.isEmpty, let folder = library.folder(of: site), let a = accounts.account(folder.accountID) {
            return a
        }
        return nil
    }

    public func resolve(_ site: Site) -> ResolvedSiteSettings {
        let folder = library.folder(of: site)
        let account = resolveAccount(for: site)

        // Username
        var username = ""
        if let a = account, !a.username.isEmpty {
            username = a.username
        } else if !site.username.isEmpty {
            username = site.username
        } else if let f = folder, !f.username.isEmpty {
            username = f.username
        } else if site.protocolType.isSSH {
            username = localUserName
        }

        // Key
        var key: SSHKeyEntry?
        if let a = account {
            key = keys.key(a.key.keyID)
        } else {
            switch site.key {
            case .key(let id): key = keys.key(id)
            case .none: key = nil
            case .inherit:
                switch folder?.key ?? .inherit {
                case .key(let id): key = keys.key(id)
                case .none: key = nil
                case .inherit: key = keys.key(settings.defaultKeyID)
                }
            }
        }

        // Auth order
        let order = site.authOrder ?? folder?.authOrder ?? account?.authOrder ?? settings.defaultAuthOrder

        let keychain = account.map { KeychainAccountName.accountPassword($0.id) }
            ?? KeychainAccountName.sitePassword(site.id)

        return ResolvedSiteSettings(username: username, account: account, key: key, authOrder: order,
                                    keyOnly: account?.isKeyOnly ?? false, passwordKeychainAccount: keychain)
    }
}
