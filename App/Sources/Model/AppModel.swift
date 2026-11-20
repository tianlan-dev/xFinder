import SwiftUI
import xFinderKit

/// Root application state: persistent stores and shared services.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let paths: AppPaths
    let secrets: SecretStore
    let knownHosts: KnownHostsStore
    let prompts: PromptCenter
    let environment: ConnectionEnvironment

    @Published var library: SiteLibrary { didSet { if library != oldValue { saveLibrary() } } }
    @Published var keys: KeyLibrary { didSet { if keys != oldValue { try? keys.save(to: paths.keysFile) } } }
    @Published var accounts: AccountStore { didSet { if accounts != oldValue { try? accounts.save(to: paths.accountsFile) } } }
    @Published var settings: AppSettings { didSet { if settings != oldValue { try? settings.save(to: paths.settingsFile) } } }
    /// Bumped when the trust store changes (Settings ▸ Security).
    @Published var trustRevision = 0

    lazy var tabs = SessionTabs(app: self)
    lazy var transfers = TransferCenter(app: self)
    lazy var editSync = EditSyncCenter(app: self)
    lazy var browserActions = BrowserActions(app: self)
    lazy var importExport = ImportExportActions(app: self)
    lazy var updates = UpdateController(app: self)
    lazy var terminal = TerminalActions(app: self)
    lazy var sidebar = SidebarController(app: self)
    lazy var bookmarks = BookmarkActions(app: self)
    lazy var clipboard = RemoteClipboard(app: self)
    /// True while the remote file list has keyboard focus (enables ⌘⌫ etc.).
    @Published var fileListFocused = false
    /// Set before relaunching after an update.
    var skipQuitConfirmation = false

    private init() {
        paths = .standard
        _ = try? AppPaths.ensureDirectory(paths.supportDirectory)
        _ = try? AppPaths.ensureDirectory(paths.cacheDirectory)
        secrets = KeychainStore()
        knownHosts = KnownHostsStore(url: paths.knownHostsFile)
        prompts = PromptCenter()
        environment = ConnectionEnvironment(knownHosts: knownHosts, secrets: secrets, interaction: prompts)
        library = (try? SiteLibrary.load(from: paths.sitesFile)) ?? SiteLibrary()
        keys = KeyLibrary.load(from: paths.keysFile)
        accounts = AccountStore.load(from: paths.accountsFile)
        var s = AppSettings.load(from: paths.settingsFile)
        s.sanitize()
        settings = s
    }

    private func saveLibrary() {
        do { try library.save(to: paths.sitesFile) } catch { NSLog("xFinder: failed to save sites: \(error)") }
    }

    private var keyInfoCache: [String: (stamp: Date?, info: SSHKeyInfo?)] = [:]

    /// Key metadata (type, fingerprint), cached by file modification date.
    func keyInfo(_ k: SSHKeyEntry) -> SSHKeyInfo? {
        let path = k.expandedPath
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let c = keyInfoCache[path], c.stamp == stamp { return c.info }
        let info = try? SSHPrivateKeyLoader.info(path: path)
        keyInfoCache[path] = (stamp, info)
        return info
    }

    /// "id_rsa (ssh-rsa · 6Fu9aGMe)"
    func keyLabel(_ k: SSHKeyEntry) -> String {
        guard let info = keyInfo(k) else { return "\(k.alias) (missing)" }
        let type = info.type?.rawValue ?? info.typeName
        if let fp = info.fingerprint {
            let short = fp.hasPrefix("SHA256:") ? String(fp.dropFirst(7).prefix(8)) : String(fp.prefix(8))
            return "\(k.alias) (\(type) · \(short))"
        }
        return "\(k.alias) (\(type))"
    }

    /// Display name of the download folder ("Downloads").
    var downloadFolderName: String {
        FileManager.default.displayName(atPath: settings.downloadDirectoryURL.path)
    }

    var resolver: SiteSettingsResolver {
        SiteSettingsResolver(library: library, keys: keys, accounts: accounts, settings: settings)
    }

    func connectionConfig(for site: Site, originID: UUID?, allowSaving: Bool = true) -> ConnectionConfig {
        ConnectionConfig(site: site, resolved: resolver.resolve(site), allowSavingSecrets: allowSaving, originID: originID)
    }

    func makeFileSystem(for site: Site, originID: UUID?) throws -> RemoteFileSystem {
        try RemoteFileSystemFactory.make(connectionConfig(for: site, originID: originID), environment: environment)
    }

    // MARK: Library helpers

    func deleteSites(_ ids: Set<UUID>) {
        let removed = library.removeSites(ids)
        for s in removed { secrets.delete(KeychainAccountName.sitePassword(s.id)) }
    }

    func deleteFolder(_ id: UUID, keepSites: Bool) {
        let removed = library.removeFolder(id, keepSites: keepSites)
        for s in removed { secrets.delete(KeychainAccountName.sitePassword(s.id)) }
    }

    /// Current up-to-date copy of a site.
    func site(_ id: UUID?) -> Site? { id.flatMap { library.site($0) } }
}
