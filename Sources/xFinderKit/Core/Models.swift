import Foundation

/// Connection protocol of a favorite.
public enum SiteProtocol: String, Codable, CaseIterable, Sendable, Identifiable {
    case sftp
    case scp
    case ftp
    case ftpsExplicit
    case ftpsImplicit
    case webdav
    case webdavs
    case s3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sftp: return "SFTP"
        case .scp: return "SCP (shell)"
        case .ftp: return "FTP"
        case .ftpsExplicit: return "FTPS (explicit)"
        case .ftpsImplicit: return "FTPS (implicit)"
        case .webdav: return "WebDAV (http)"
        case .webdavs: return "WebDAV (https)"
        case .s3: return "S3"
        }
    }

    public var shortName: String {
        switch self {
        case .sftp: return "SFTP"
        case .scp: return "SCP"
        case .ftp: return "FTP"
        case .ftpsExplicit, .ftpsImplicit: return "FTPS"
        case .webdav, .webdavs: return "WebDAV"
        case .s3: return "S3"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sftp, .scp: return 22
        case .ftp, .ftpsExplicit: return 21
        case .ftpsImplicit: return 990
        case .webdav: return 80
        case .webdavs, .s3: return 443
        }
    }

    /// SFTP and SCP (shell): SSH sign-in, keys, host keys and the terminal.
    public var isSSH: Bool { self == .sftp || self == .scp }
    public var isFTP: Bool { self == .ftp || self == .ftpsExplicit || self == .ftpsImplicit }
    public var isWebDAV: Bool { self == .webdav || self == .webdavs }

    public var capabilities: RemoteCapabilities {
        switch self {
        case .sftp: return .sftp
        case .scp: return .scp
        case .ftp, .ftpsExplicit, .ftpsImplicit: return .ftp
        case .webdav, .webdavs: return .webDAV
        case .s3: return .s3
        }
    }
}

/// Authentication method order. `nil` on a site/folder/account means "inherit".
public enum AuthOrder: String, Codable, CaseIterable, Sendable, Identifiable {
    case keyFirst
    case passwordFirst

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .keyFirst: return "Key first, then password"
        case .passwordFirst: return "Password first, then key"
        }
    }
}

/// Key selection with inheritance. `.none` stops inheritance (no key).
public enum KeyChoice: Hashable, Sendable, Codable {
    case inherit
    case none
    case key(UUID)

    public var keyID: UUID? {
        if case .key(let id) = self { return id }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        switch s {
        case "inherit": self = .inherit
        case "none": self = .none
        default:
            guard let id = UUID(uuidString: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid key choice \(s)")
            }
            self = .key(id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .inherit: try c.encode("inherit")
        case .none: try c.encode("none")
        case .key(let id): try c.encode(id.uuidString)
        }
    }
}

/// A bookmarked remote folder.
public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String

    public init(id: UUID = UUID(), name: String? = nil, path: String) {
        self.id = id
        self.path = path
        self.name = name ?? RemotePath.lastComponent(path)
    }
}

/// Visibility scope of a bookmark.
public enum BookmarkScope: String, Codable, CaseIterable, Sendable {
    case global
    case folder
    case site

    public var displayName: String {
        switch self {
        case .global: return "All Servers"
        case .folder: return "Servers in This Folder"
        case .site: return "This Server Only"
        }
    }
}

/// A saved server (favorite).
public struct Site: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var protocolType: SiteProtocol
    public var host: String
    /// nil = protocol default port.
    public var port: Int?
    /// Empty = inherit.
    public var username: String
    public var key: KeyChoice
    public var authOrder: AuthOrder?
    public var initialPath: String
    public var folderID: UUID?
    /// Host alias from `~/.ssh/config` (set when imported from ssh config).
    public var sshConfigAlias: String?
    public var webDAVBasePath: String
    public var s3Bucket: String
    public var s3Region: String
    public var s3UsePlainHTTP: Bool
    public var bookmarks: [Bookmark]
    public var accountID: UUID?

    public init(id: UUID = UUID(), name: String = "", protocolType: SiteProtocol = .sftp,
                host: String = "", port: Int? = nil, username: String = "",
                key: KeyChoice = .inherit, authOrder: AuthOrder? = nil, initialPath: String = "",
                folderID: UUID? = nil, sshConfigAlias: String? = nil, webDAVBasePath: String = "",
                s3Bucket: String = "", s3Region: String = "", s3UsePlainHTTP: Bool = false,
                bookmarks: [Bookmark] = [], accountID: UUID? = nil) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.host = host
        self.port = port
        self.username = username
        self.key = key
        self.authOrder = authOrder
        self.initialPath = initialPath
        self.folderID = folderID
        self.sshConfigAlias = sshConfigAlias
        self.webDAVBasePath = webDAVBasePath
        self.s3Bucket = s3Bucket
        self.s3Region = s3Region
        self.s3UsePlainHTTP = s3UsePlainHTTP
        self.bookmarks = bookmarks
        self.accountID = accountID
    }

    public var effectivePort: Int { port ?? protocolType.defaultPort }
    public var displayName: String { name.isEmpty ? host : name }

    enum CodingKeys: String, CodingKey {
        case id, name, protocolType = "protocol", host, port, username, key, authOrder, initialPath
        case folderID, sshConfigAlias, webDAVBasePath, s3Bucket, s3Region, s3UsePlainHTTP, bookmarks, accountID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        protocolType = try c.decodeIfPresent(SiteProtocol.self, forKey: .protocolType) ?? .sftp
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        key = try c.decodeIfPresent(KeyChoice.self, forKey: .key) ?? .inherit
        authOrder = try c.decodeIfPresent(AuthOrder.self, forKey: .authOrder)
        initialPath = try c.decodeIfPresent(String.self, forKey: .initialPath) ?? ""
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        sshConfigAlias = try c.decodeIfPresent(String.self, forKey: .sshConfigAlias)
        webDAVBasePath = try c.decodeIfPresent(String.self, forKey: .webDAVBasePath) ?? ""
        s3Bucket = try c.decodeIfPresent(String.self, forKey: .s3Bucket) ?? ""
        s3Region = try c.decodeIfPresent(String.self, forKey: .s3Region) ?? ""
        s3UsePlainHTTP = try c.decodeIfPresent(Bool.self, forKey: .s3UsePlainHTTP) ?? false
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
    }
}

/// A single-level folder of favorites with inheritable defaults.
public struct SiteFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var username: String
    public var key: KeyChoice
    public var authOrder: AuthOrder?
    public var accountID: UUID?
    public var bookmarks: [Bookmark]
    /// Ordered site IDs inside this folder.
    public var siteIDs: [UUID]

    public init(id: UUID = UUID(), name: String, username: String = "", key: KeyChoice = .inherit,
                authOrder: AuthOrder? = nil, accountID: UUID? = nil, bookmarks: [Bookmark] = [],
                siteIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.username = username
        self.key = key
        self.authOrder = authOrder
        self.accountID = accountID
        self.bookmarks = bookmarks
        self.siteIDs = siteIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        key = try c.decodeIfPresent(KeyChoice.self, forKey: .key) ?? .inherit
        authOrder = try c.decodeIfPresent(AuthOrder.self, forKey: .authOrder)
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        siteIDs = try c.decodeIfPresent([UUID].self, forKey: .siteIDs) ?? []
    }
}

/// A registered SSH private key (only path + alias are stored).
public struct SSHKeyEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var alias: String
    public var path: String

    public init(id: UUID = UUID(), alias: String, path: String) {
        self.id = id
        self.alias = alias
        self.path = path
    }

    public var expandedPath: String { (path as NSString).expandingTildeInPath }
}

/// A shared login (username + key/password) reusable across servers.
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var username: String
    /// `.none` or `.key(id)`; accounts never inherit keys.
    public var key: KeyChoice
    public var usePassword: Bool
    public var authOrder: AuthOrder?

    public init(id: UUID = UUID(), name: String, username: String, key: KeyChoice = .none,
                usePassword: Bool = true, authOrder: AuthOrder? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.key = key
        self.usePassword = key.keyID == nil ? true : usePassword
        self.authOrder = authOrder
    }

    /// An account with a key and no password: never sends a password over SSH.
    public var isKeyOnly: Bool { key.keyID != nil && !usePassword }
}

/// Keychain account name helpers.
public enum KeychainAccountName {
    public static func sitePassword(_ id: UUID) -> String { "site-password.\(id.uuidString)" }
    public static func keyPassphrase(_ id: UUID) -> String { "key-passphrase.\(id.uuidString)" }
    public static func accountPassword(_ id: UUID) -> String { "account-password.\(id.uuidString)" }
}
