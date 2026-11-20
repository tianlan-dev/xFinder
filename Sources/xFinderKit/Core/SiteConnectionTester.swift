import Foundation

/// Secret store that overlays unsaved values on another store and never writes.
public final class OverlaySecretStore: SecretStore, @unchecked Sendable {
    let base: SecretStore
    let overrides: [String: String]
    public init(base: SecretStore, overrides: [String: String]) {
        self.base = base
        self.overrides = overrides
    }
    public func read(_ account: String) -> String? { overrides[account] ?? base.read(account) }
    public func write(_ secret: String, for account: String) throws {}
    public func delete(_ account: String) {}
}

/// "Test" in the server editor: connects with unsaved settings and checks that the
/// initial folder exists and is a folder. Entered passwords are never saved.
public enum SiteConnectionTester {
    public struct Result: Sendable {
        public var success: Bool
        public var message: String
    }

    public static func test(site: Site, resolved: ResolvedSiteSettings, unsavedPassword: String?,
                            knownHosts: KnownHostsStore, secrets: SecretStore,
                            interaction: ConnectionInteraction) async -> Result {
        var overrides: [String: String] = [:]
        if let p = unsavedPassword, !p.isEmpty { overrides[resolved.passwordKeychainAccount] = p }
        let env = ConnectionEnvironment(knownHosts: knownHosts,
                                        secrets: OverlaySecretStore(base: secrets, overrides: overrides),
                                        interaction: interaction)
        let config = ConnectionConfig(site: site, resolved: resolved, allowSavingSecrets: false)
        let fs: RemoteFileSystem
        do {
            fs = try RemoteFileSystemFactory.make(config, environment: env)
            try await fs.connect()
        } catch {
            return Result(success: false, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        defer { Task { await fs.disconnect() } }
        let initial = site.initialPath.trimmingCharacters(in: .whitespaces)
        guard !initial.isEmpty, initial != "~" else {
            return Result(success: true, message: "Connected successfully. Home folder: \(fs.homeDirectory)")
        }
        var path = initial
        if path.hasPrefix("~/") { path = RemotePath.join(fs.homeDirectory, String(path.dropFirst(2))) }
        else if !path.hasPrefix("/") { path = RemotePath.join(fs.homeDirectory, path) }
        do {
            let item = try await fs.stat(path)
            if item.isDirectoryLike {
                return Result(success: true, message: "Connected successfully. The initial folder \(path) exists.")
            }
            return Result(success: false, message: "Connected, but the initial folder \(path) is not a folder.")
        } catch {
            return Result(success: false, message: "Connected, but the initial folder \(path) could not be opened: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }
}
