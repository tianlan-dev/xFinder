import SwiftUI
import AppKit
import UniformTypeIdentifiers
import xFinderKit

/// The remote file browser of one tab.
struct BrowserView: View {
    @ObservedObject var session: ConnectionSession
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            BookmarksBar(session: session)
            Divider()
            BreadcrumbBar(session: session)
            Divider()
            ZStack {
                RemoteFileTable(session: session, showHidden: session.showHidden,
                                foldersFirst: app.settings.foldersFirst, handlers: handlers)
                    .opacity(session.isConnected ? 1 : 0.35)
                    .disabled(!session.isConnected)
                statusOverlay
            }
            if let m = session.message {
                MessageBanner(text: m) { session.message = nil }
            }
        }
        .sheet(item: $session.sheet) { sheet in
            BrowserSheetView(session: session, sheet: sheet)
                .environmentObject(app)
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch session.status {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(session.site?.host ?? "")…").foregroundStyle(.secondary)
                Button("Cancel") { session.disconnect() }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let reason):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("Could not connect").font(.headline)
                Text(reason).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                HStack {
                    if session.site.map({ app.library.site($0.id) != nil }) ?? false {
                        Button("Edit Server…") { app.sidebar.edit(siteID: session.site!.id) }
                    }
                    if session.sftpUnavailable {
                        Button("Try Again") { session.connect() }
                        Button("Use SCP (shell)") { session.switchToSCPAndRetry() }
                            .keyboardShortcut(.defaultAction)
                            .help("Change this server's protocol to SCP (shell) and connect again")
                    } else {
                        Button("Try Again") { session.connect() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .disconnected:
            VStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("Disconnected").font(.headline)
                Button("Reconnect") { session.reconnect() }.keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        default:
            EmptyView()
        }
    }

    private var handlers: RemoteFileTableHandlers {
        let s = session
        let app = self.app
        return RemoteFileTableHandlers(
            open: { item in app.browserActions.open(item, in: s) },
            menu: { clicked, menu in BrowserContextMenu.build(menu, clicked: clicked, session: s, app: app) },
            delete: { if !s.selectedItems.isEmpty { s.sheet = .confirmDelete(s.selectedItems) } },
            copy: { app.clipboard.copy(s.selectedItems, from: s) },
            paste: { folder in app.clipboard.paste(into: folder, session: s) },
            dropFiles: { urls, folder in app.transfers.upload(urls, to: folder, session: s) },
            dropRemote: { payload, folder, copy in app.transfers.handleRemoteDrop(payload, into: folder, target: s, copy: copy) },
            promiseProvider: { item in app.transfers.filePromiseProvider(for: item, session: s) },
            focusChanged: { focused in app.fileListFocused = focused }
        )
    }
}

struct MessageBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "info.circle")
            Text(text).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.18))
    }
}

/// Clickable path components; dropping Finder files on one uploads there.
struct BreadcrumbBar: View {
    @ObservedObject var session: ConnectionSession
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(RemotePath.ancestors(session.currentPath), id: \.self) { path in
                    if path != "/" {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    BreadcrumbItem(path: path, session: session)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 24)
    }
}

struct BreadcrumbItem: View {
    let path: String
    @ObservedObject var session: ConnectionSession
    @EnvironmentObject var app: AppModel
    @State private var targeted = false

    var body: some View {
        Button { session.navigate(to: path) } label: {
            Text(path == "/" ? "/" : RemotePath.lastComponent(path))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
            .buttonStyle(.plain)
            .disabled(!session.isConnected)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(targeted ? Color.accentColor.opacity(0.3) : .clear))
            .onDrop(of: [.fileURL, RemoteDragPayload.type], isTargeted: $targeted) { providers in
                handleDrop(providers)
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let s = session
        let folder = path
        let app = self.app
        let remote = providers.filter { $0.hasItemConformingToTypeIdentifier(RemoteDragPayload.type.identifier) }
        if !remote.isEmpty {
            let collected = Locked<[RemoteDragPayload]>([])
            let group = DispatchGroup()
            for p in remote {
                group.enter()
                p.loadDataRepresentation(forTypeIdentifier: RemoteDragPayload.type.identifier) { data, _ in
                    if let data, let payload = try? JSONDecoder().decode(RemoteDragPayload.self, from: data) {
                        collected.withLock { $0.append(payload) }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let all = collected.value
                guard var merged = all.first else { return }
                for p in all.dropFirst() where p.sessionID == merged.sessionID { merged.entries += p.entries }
                MainActor.assumeIsolated {
                    app.transfers.handleRemoteDrop(merged, into: folder, target: s, copy: merged.sessionID != s.id)
                }
            }
            return true
        }
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { app.transfers.upload(urls, to: folder, session: s) }
        }
        return true
    }
}

/// Context menu of the file list.
@MainActor
enum BrowserContextMenu {
    static func build(_ menu: NSMenu, clicked: RemoteItem?, session s: ConnectionSession, app: AppModel) {
        let items = s.selectedItems
        let caps = s.capabilities
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let mi = ClosureMenuItem(title: title, action: action)
            mi.isEnabled = enabled
            menu.addItem(mi)
        }
        if let clicked {
            add("Open") { app.browserActions.open(clicked, in: s) }
            if !clicked.isDirectoryLike {
                let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                openWith.submenu = OpenWithMenu.build(for: clicked, session: s, app: app)
                menu.addItem(openWith)
            }
            menu.addItem(.separator())
            add("Rename…", enabled: caps.contains(.rename) && items.count == 1) { s.sheet = .rename(clicked) }
            add("Copy") { app.clipboard.copy(items, from: s) }
            add("Duplicate") { app.browserActions.duplicateSelection() }
            if clicked.isDirectoryLike {
                add("Paste Into Folder", enabled: app.clipboard.canPaste) { app.clipboard.paste(into: clicked.path, session: s) }
            }
            menu.addItem(.separator())
            add("Download to \(app.downloadFolderName)") { app.browserActions.downloadSelection(to: nil) }
            add("Download To…") { app.browserActions.downloadSelectionChoosingFolder() }
            if clicked.isDirectoryLike {
                add("Upload Into Folder…") { app.browserActions.chooseAndUpload(into: clicked.path) }
            }
            menu.addItem(.separator())
            add("Get Info") { s.sheet = .info(clicked) }
            add("Change Permissions…", enabled: caps.contains(.chmod) && items.count == 1) { s.sheet = .permissions(clicked) }
            add("Copy Path") { app.browserActions.copyPath() }
            if clicked.isDirectoryLike {
                add("Add to Bookmarks") { app.bookmarks.add(path: clicked.path, scope: .site, session: s) }
            }
            menu.addItem(.separator())
            add("Delete…", enabled: caps.contains(.delete)) { s.sheet = .confirmDelete(items) }
        } else {
            add("New Folder…", enabled: caps.contains(.mkdir)) { s.sheet = .newFolder(parent: s.currentPath) }
            add("Upload…") { app.browserActions.chooseAndUpload() }
            add("Paste", enabled: app.clipboard.canPaste) { app.clipboard.paste(into: s.currentPath, session: s) }
            add("Refresh") { s.refresh() }
            add("Copy Path") { app.browserActions.copyPath() }
            add("Bookmark Current Folder") { app.bookmarks.add(path: s.currentPath, scope: .site, session: s) }
        }
    }
}

/// NSMenuItem running a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
