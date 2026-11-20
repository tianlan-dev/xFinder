import Foundation

/// Everything needed to open a connection to one favorite.
public struct ConnectionConfig: Sendable {
    public var site: Site
    public var resolved: ResolvedSiteSettings
    /// False for "Test" connections: entered secrets are never saved.
    public var allowSavingSecrets: Bool
    /// Session/tab that owns this connection (for prompts).
    public var originID: UUID?

    public init(site: Site, resolved: ResolvedSiteSettings, allowSavingSecrets: Bool = true, originID: UUID? = nil) {
        self.site = site
        self.resolved = resolved
        self.allowSavingSecrets = allowSavingSecrets
        self.originID = originID
    }

    public var host: String { site.host.trimmingCharacters(in: .whitespaces) }
    public var port: Int { site.effectivePort }
    public var username: String { resolved.username }
    public var hostLabel: String { port == site.protocolType.defaultPort ? host : "\(host):\(port)" }
}

/// Shared services used by every protocol implementation.
public struct ConnectionEnvironment: Sendable {
    public var knownHosts: KnownHostsStore
    public var broker: PasswordBroker
    public var interaction: ConnectionInteraction
    public var tlsTrust: TLSTrustEvaluator
    public var secrets: SecretStore

    public init(knownHosts: KnownHostsStore, secrets: SecretStore, interaction: ConnectionInteraction) {
        self.knownHosts = knownHosts
        self.secrets = secrets
        self.interaction = interaction
        self.broker = PasswordBroker(secrets: secrets, interaction: interaction)
        self.tlsTrust = TLSTrustEvaluator(store: knownHosts, interaction: interaction)
    }
}

/// Credentials that already worked, kept in memory only so transfer connections
/// can reuse them without prompting.
public struct CachedCredentials: @unchecked Sendable {
    public var password: String?
    public var key: LoadedPrivateKey?
    public init(password: String? = nil, key: LoadedPrivateKey? = nil) {
        self.password = password
        self.key = key
    }
}

public enum RemoteFileSystemFactory {
    public static func make(_ config: ConnectionConfig, environment: ConnectionEnvironment) throws -> RemoteFileSystem {
        switch config.site.protocolType {
        case .sftp:
            return SFTPFileSystem(config: config, environment: environment)
        case .scp:
            return SCPFileSystem(config: config, environment: environment)
        case .ftp, .ftpsExplicit, .ftpsImplicit:
            return FTPFileSystem(config: config, environment: environment)
        case .webdav, .webdavs:
            return WebDAVFileSystem(config: config, environment: environment)
        case .s3:
            return S3FileSystem(config: config, environment: environment)
        }
    }
}

/// Bounded helper for running closures with a timeout.
public func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RemoteError.timeout
        }
        guard let result = try await group.next() else { throw RemoteError.timeout }
        group.cancelAll()
        return result
    }
}

/// Thread-safe mutable box.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    public init(_ value: Value) { _value = value }
    public var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&_value)
    }
}
