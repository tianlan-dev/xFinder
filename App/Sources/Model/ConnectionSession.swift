import SwiftUI
import xFinderKit

enum SessionStatus: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
    case disconnected

    var color: Color {
        switch self {
        case .idle: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        case .disconnected: return .orange
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        }
    }
}

/// Sheets and confirmations shown by the browser.
enum BrowserSheet: Identifiable {
    case newFolder(parent: String)
    case rename(RemoteItem)
    case permissions(RemoteItem)
    case info(RemoteItem)
    case goToFolder
    case confirmDelete([RemoteItem])

    var id: String {
        switch self {
        case .newFolder(let p): return "new:\(p)"
        case .rename(let i): return "rename:\(i.path)"
        case .permissions(let i): return "chmod:\(i.path)"
        case .info(let i): return "info:\(i.path)"
        case .goToFolder: return "goto"
        case .confirmDelete(let items): return "delete:\(items.map(\.path).joined(separator: "|"))"
        }
    }
}

/// One tab: its own connection, path, selection, sorting and expansion state.
@MainActor
final class ConnectionSession: ObservableObject, Identifiable {
    let id = UUID()
    unowned let app: AppModel

    /// The favorite (or an unsaved Quick Connect site).
    @Published var site: Site?
    @Published var isQuickConnect = false
    @Published private(set) var status: SessionStatus = .idle
    @Published private(set) var currentPath = "/"
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var children: [String: [RemoteItem]] = [:]
    @Published var expanded: Set<String> = []
    @Published var selection: Set<String> = []
    @Published var sortKey: FileSortKey = .name
    @Published var sortAscending = true
    @Published var message: String?
    @Published var sheet: BrowserSheet?
    @Published var isLoading = false
    /// Per-tab hidden-files toggle; starts from the global default.
    @Published var showHidden: Bool
    /// The last connect failed because the server has no SFTP subsystem.
    @Published private(set) var sftpUnavailable = false
    /// Increments whenever the visible listing changes (drives table reloads).
    @Published private(set) var revision = 0

    private(set) var fileSystem: RemoteFileSystem?
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var connectTask: Task<Void, Never>?

    init(app: AppModel, site: Site? = nil) {
        self.app = app
        self.site = site
        self.showHidden = app.settings.showHiddenFiles
    }

    var title: String {
        if let site { return site.displayName.isEmpty ? "Untitled" : site.displayName }
        return "Quick Connect"
    }

    var isEmpty: Bool { site == nil && fileSystem == nil }
    var capabilities: RemoteCapabilities { fileSystem?.capabilities ?? site?.protocolType.capabilities ?? [] }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isConnected: Bool { status == .connected }

    // MARK: Connection

    func open(_ site: Site, quickConnect: Bool = false) {
        self.site = site
        self.isQuickConnect = quickConnect
        connect()
    }

    func connect(restorePath: String? = nil) {
        guard let site else { return }
        connectTask?.cancel()
        let old = fileSystem
        fileSystem = nil
        Task { await old?.disconnect() }
        status = .connecting
        message = nil
        sftpUnavailable = false
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fs = try self.app.makeFileSystem(for: self.app.site(site.id) ?? site, originID: self.id)
                try await fs.connect()
                if Task.isCancelled { await fs.disconnect(); return }
                self.fileSystem = fs
                let onDisconnect: @Sendable () -> Void = { [weak self] in
                    Task { @MainActor in self?.handleDisconnect() }
                }
                if let sftp = fs as? SFTPFileSystem { sftp.setDisconnectHandler(onDisconnect) }
                if let scp = fs as? SCPFileSystem { scp.setDisconnectHandler(onDisconnect) }
                self.status = .connected
                self.app.editSync.serverConnected(siteID: site.id)
                let initial = restorePath ?? self.initialPath(site: site, home: fs.homeDirectory)
                let ok = await self.load(path: initial, recordHistory: false)
                if !ok && initial != fs.homeDirectory {
                    self.message = "Could not open \(initial). Showing the home folder instead."
                    _ = await self.load(path: fs.homeDirectory, recordHistory: false)
                }
            } catch {
                if Task.isCancelled { return }
                self.sftpUnavailable = (error as? RemoteError) == .sftpUnavailable
                self.status = .failed(Self.describe(error))
            }
        }
    }

    /// Switches this server to SCP (shell) and connects again.
    func switchToSCPAndRetry() {
        guard var s = site else { return }
        s.protocolType = .scp
        if app.library.site(s.id) != nil {
            app.library.updateSite(s)
            s = app.library.site(s.id) ?? s
        }
        site = s
        connect(restorePath: nil)
    }

    private func initialPath(site: Site, home: String) -> String {
        let p = site.initialPath.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return home }
        if p == "~" { return home }
        if p.hasPrefix("~/") { return RemotePath.join(home, String(p.dropFirst(2))) }
        return p.hasPrefix("/") ? p : RemotePath.join(home, p)
    }

    func handleDisconnect() {
        guard status == .connected else { return }
        status = .disconnected
        message = "The connection was closed."
    }

    func reconnect() {
        connect(restorePath: currentPath)
    }

    func disconnect() {
        connectTask?.cancel()
        let fs = fileSystem
        fileSystem = nil
        Task { await fs?.disconnect() }
        status = site == nil ? .idle : .disconnected
    }

    func close() {
        disconnect()
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return error.localizedDescription
    }

    // MARK: Listing

    func displayed(_ list: [RemoteItem]) -> [RemoteItem] {
        let filtered = showHidden ? list : list.filter { !$0.isHidden }
        return sorted(filtered)
    }

    func sorted(_ list: [RemoteItem]) -> [RemoteItem] {
        FileListSort.sorted(list, by: sortKey, ascending: sortAscending,
                            foldersFirst: app.settings.foldersFirst)
    }

    var visibleItems: [RemoteItem] { displayed(items) }
    func visibleChildren(_ path: String) -> [RemoteItem]? { children[path].map(displayed) }

    @discardableResult
    func load(path: String, recordHistory: Bool = true) async -> Bool {
        guard let fs = fileSystem else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await fs.list(path)
            if recordHistory && path != currentPath {
                backStack.append(currentPath)
                forwardStack.removeAll()
            }
            currentPath = path
            items = list
            children = [:]
            expanded = []
            selection = []
            revision += 1
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func navigate(to path: String) {
        Task { await load(path: RemotePath.normalize(path)) }
    }

    func goBack() {
        guard let p = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        Task { await load(path: p, recordHistory: false) }
    }

    func goForward() {
        guard let p = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        Task { await load(path: p, recordHistory: false) }
    }

    func goUp() {
        let parent = RemotePath.parent(currentPath)
        if parent != currentPath { navigate(to: parent) }
    }

    /// Resolves "Go to Folder" input (supports `~`).
    func resolveUserPath(_ input: String) -> String {
        let t = input.trimmingCharacters(in: .whitespaces)
        let home = fileSystem?.homeDirectory ?? "/"
        if t.isEmpty || t == "~" { return home }
        if t.hasPrefix("~/") { return RemotePath.join(home, String(t.dropFirst(2))) }
        if t.hasPrefix("/") { return RemotePath.normalize(t) }
        return RemotePath.join(currentPath, t)
    }

    /// Reloads the current folder and every expanded folder; folders that no longer
    /// exist are collapsed.
    func refresh() {
        guard let fs = fileSystem else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let list = try await fs.list(currentPath)
                var newChildren: [String: [RemoteItem]] = [:]
                var newExpanded: Set<String> = []
                for path in expanded.sorted(by: { $0.count < $1.count }) {
                    // Only keep folders whose parent is still visible.
                    let parent = RemotePath.parent(path)
                    guard parent == currentPath || newExpanded.contains(parent) else { continue }
                    if let sub = try? await fs.list(path) {
                        newChildren[path] = sub
                        newExpanded.insert(path)
                    }
                }
                items = list
                children = newChildren
                expanded = newExpanded
                let all = Set(list.map(\.path)).union(newChildren.values.flatMap { $0.map(\.path) })
                selection = selection.intersection(all)
                revision += 1
            } catch {
                handle(error)
            }
        }
    }

    /// Loads a folder's contents for in-place expansion.
    func expand(_ path: String) {
        if expanded.contains(path) && children[path] != nil { return }
        expanded.insert(path)
        guard children[path] == nil, let fs = fileSystem else { revision += 1; return }
        Task {
            do {
                children[path] = try await fs.list(path)
                revision += 1
            } catch {
                expanded.remove(path)
                handle(error)
            }
        }
    }

    func collapse(_ path: String) {
        expanded.remove(path)
        for p in expanded where RemotePath.isSameOrDescendant(p, of: path) { expanded.remove(p) }
    }

    func item(at path: String) -> RemoteItem? {
        if let i = items.first(where: { $0.path == path }) { return i }
        for list in children.values { if let i = list.first(where: { $0.path == path }) { return i } }
        return nil
    }

    var selectedItems: [RemoteItem] { selection.compactMap { item(at: $0) }.sorted { $0.path < $1.path } }

    /// Reloads a single folder if it is on screen.
    func reloadFolder(_ path: String) {
        let p = RemotePath.normalize(path)
        if p == currentPath { refresh(); return }
        if children[p] != nil, let fs = fileSystem {
            Task {
                if let sub = try? await fs.list(p) { children[p] = sub; revision += 1 }
            }
        }
    }

    func handle(_ error: Error) {
        if let r = error as? RemoteError, r == .notConnected {
            status = .disconnected
        }
        if error is CancellationError { return }
        message = Self.describe(error)
    }

    // MARK: File operations

    func createFolder(named name: String, in parent: String? = nil) async -> Bool {
        if let err = RemotePath.validateName(name) { message = err; return false }
        guard let fs = fileSystem else { return false }
        let dir = parent ?? currentPath
        let path = RemotePath.join(dir, name)
        let existing = (dir == currentPath ? items : (children[dir] ?? []))
        if existing.contains(where: { $0.name == name }) { message = "\"\(name)\" already exists."; return false }
        do {
            try await fs.createDirectory(path)
            reloadFolder(dir)
            selection = [path]
            return true
        } catch { handle(error); return false }
    }

    func rename(_ item: RemoteItem, to newName: String) async -> Bool {
        if newName == item.name { return true }
        if let err = RemotePath.validateName(newName) { message = err; return false }
        guard let fs = fileSystem else { return false }
        let dir = RemotePath.parent(item.path)
        let siblings = dir == currentPath ? items : (children[dir] ?? [])
        if siblings.contains(where: { $0.name == newName }) { message = "\"\(newName)\" already exists."; return false }
        do {
            try await fs.rename(item.path, to: RemotePath.join(dir, newName))
            reloadFolder(dir)
            return true
        } catch { handle(error); return false }
    }

    func delete(_ targets: [RemoteItem]) async {
        guard let fs = fileSystem else { return }
        var folders = Set<String>()
        for item in targets {
            do {
                try await fs.delete(item.path, isDirectory: item.type == .directory)
                folders.insert(RemotePath.parent(item.path))
            } catch { handle(error); break }
        }
        for f in folders { reloadFolder(f) }
    }

    func setPermissions(_ item: RemoteItem, mode: UInt32) async -> Bool {
        guard let fs = fileSystem else { return false }
        do {
            try await fs.setPermissions(item.path, mode: mode)
            reloadFolder(RemotePath.parent(item.path))
            return true
        } catch { handle(error); return false }
    }

    /// Moves items within this server (rename-based drag and drop).
    func move(_ paths: [String], into folder: String) async {
        guard let fs = fileSystem else { return }
        var dirs = Set([folder])
        for p in paths {
            let dest = RemotePath.join(folder, RemotePath.lastComponent(p))
            if dest == p || RemotePath.isSameOrDescendant(folder, of: p) { continue }
            do {
                try await fs.rename(p, to: dest)
                dirs.insert(RemotePath.parent(p))
            } catch { handle(error); break }
        }
        for d in dirs { reloadFolder(d) }
    }
}
