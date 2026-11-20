import SwiftUI
import UniformTypeIdentifiers
import xFinderKit

/// Bookmark management for the current site.
@MainActor
final class BookmarkActions {
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    func add(path: String, scope: BookmarkScope, session: ConnectionSession, at index: Int? = nil) {
        guard let site = session.site else { return }
        if app.library.site(site.id) == nil {
            session.message = "Save this server to Favorites to keep bookmarks."
            return
        }
        app.library.addBookmark(Bookmark(path: path), scope: scope, siteID: site.id, at: index)
    }
}

/// Bookmarks bar. Normally a row of chips (global first, then folder and
/// server bookmarks). While something is dragged over it, it shows grouped
/// drop zones: "All Servers" (purple), the favorite folder (orange) and
/// "This Server" (blue); dropping decides who sees the bookmark.
struct BookmarksBar: View {
    @ObservedObject var session: ConnectionSession
    @EnvironmentObject var app: AppModel
    @State private var targets = Set<String>()
    @State private var dragActive = false
    @State private var resetTask: Task<Void, Never>?
    @State private var draggedID: UUID?
    @State private var renaming: Bookmark?

    static let bookmarkPrefix = "xfinder-bookmark:"

    var entries: [(bookmark: Bookmark, scope: BookmarkScope)] {
        app.library.visibleBookmarks(for: session.site?.id)
    }

    var folder: SiteFolder? {
        session.site.flatMap { app.library.site($0.id) }.flatMap { app.library.folder(of: $0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark").foregroundStyle(.secondary).font(.callout)
            if dragActive {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        zone(.global, title: "All Servers")
                        if let folder { zone(.folder, title: folder.name) }
                        zone(.site, title: "This Server")
                    }
                    .padding(.vertical, 3)
                }
            } else if entries.isEmpty {
                Text("Drag a folder here, or right-click a folder and choose Add to Bookmarks.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(entries, id: \.bookmark.id) { e in chip(e.bookmark, scope: e.scope) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Bookmark Current Folder") { app.bookmarks.add(path: session.currentPath, scope: .site, session: session) }
                .disabled(!session.isConnected)
        }
        .onDrop(of: [RemoteDragPayload.type, .text], isTargeted: targetBinding("bar")) { providers in
            handleDrop(providers, scope: .site, index: nil)
        }
        .sheet(item: $renaming) { b in
            NameSheet(title: "Rename Bookmark", prompt: b.path, initial: b.name, action: "Rename") { name in
                app.library.renameBookmark(b.id, to: name)
                return true
            }
        }
    }

    // MARK: Drag state

    /// Every drop target reports here; the zones stay visible while any is hovered.
    private func targetBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { targets.contains(key) }, set: { on in
            if on { targets.insert(key) } else { targets.remove(key) }
            resetTask?.cancel()
            if !targets.isEmpty {
                dragActive = true
            } else {
                resetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled, targets.isEmpty else { return }
                    dragActive = false
                    draggedID = nil
                }
            }
        })
    }

    // MARK: Chips

    private func isCurrent(_ b: Bookmark) -> Bool {
        session.isConnected && RemotePath.normalize(session.resolveUserPath(b.path)) == session.currentPath
    }

    static func symbol(_ scope: BookmarkScope) -> String {
        scope == .global ? "globe" : "folder.badge.gearshape"
    }

    func chipLabel(_ b: Bookmark, scope: BookmarkScope, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(scope)).font(.caption).foregroundStyle(.secondary)
            Text(b.name).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.18) : .clear))
        .opacity(draggedID == b.id ? 0.35 : 1)
    }

    func chip(_ b: Bookmark, scope: BookmarkScope) -> some View {
        Button {
            session.navigate(to: session.resolveUserPath(b.path))
        } label: {
            chipLabel(b, scope: scope, highlighted: isCurrent(b))
        }
        .buttonStyle(.plain)
        .disabled(!session.isConnected)
        .help("\(b.path) — \(scope.displayName)")
        .onDrag {
            draggedID = b.id
            return NSItemProvider(object: (Self.bookmarkPrefix + b.id.uuidString) as NSString)
        } preview: {
            chipLabel(b, scope: scope, highlighted: true)
        }
        .contextMenu {
            Menu("Show For") {
                ForEach(BookmarkScope.allCases, id: \.self) { s in
                    Button {
                        app.library.setBookmarkScope(b.id, scope: s, siteID: session.site?.id)
                    } label: {
                        if s == scope { Label(s.displayName, systemImage: "checkmark") } else { Text(s.displayName) }
                    }
                    .disabled(s == .folder && folder == nil)
                }
            }
            Button("Rename…") { renaming = b }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(b.path, forType: .string)
            }
            Divider()
            Button("Remove Bookmark") { app.library.removeBookmark(b.id) }
        }
    }

    // MARK: Drop zones

    @ViewBuilder
    func zone(_ scope: BookmarkScope, title: String) -> some View {
        let list = entries.filter { $0.scope == scope }.map(\.bookmark)
        let key = "zone-\(scope.rawValue)"
        let hovered = targets.contains(key)
        HStack(spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(scope.color).padding(.leading, 4)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, b in
                chipLabel(b, scope: scope, highlighted: false)
                    .onDrop(of: [RemoteDragPayload.type, .text], isTargeted: targetBinding("\(key)-\(b.id)")) { providers in
                        handleDrop(providers, scope: scope, index: i)
                    }
            }
            if scope == .site {
                Text("Drop here").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(scope == .site ? scope.color.opacity(hovered ? 0.15 : 0.04) : scope.color.opacity(hovered ? 0.28 : 0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(scope == .site ? scope.color : scope.color.opacity(hovered ? 0.8 : 0), lineWidth: scope == .site ? 1.5 : 1)
        )
        .onDrop(of: [RemoteDragPayload.type, .text], isTargeted: targetBinding(key)) { providers in
            handleDrop(providers, scope: scope, index: nil)
        }
    }

    /// Remote folders become new bookmarks; dragged bookmarks change scope or position.
    private func handleDrop(_ providers: [NSItemProvider], scope: BookmarkScope, index: Int?) -> Bool {
        let s = session
        let app = self.app
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(RemoteDragPayload.type.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: RemoteDragPayload.type.identifier) { data, _ in
                    guard let data, let payload = try? JSONDecoder().decode(RemoteDragPayload.self, from: data) else { return }
                    Task { @MainActor in
                        var at = index
                        for e in payload.entries where e.isDirectory {
                            app.bookmarks.add(path: e.path, scope: scope, session: s, at: at)
                            at = at.map { $0 + 1 }
                        }
                    }
                }
                return true
            }
            if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { str, _ in
                    guard let str, str.hasPrefix(Self.bookmarkPrefix),
                          let id = UUID(uuidString: String(str.dropFirst(Self.bookmarkPrefix.count))) else { return }
                    Task { @MainActor in
                        var at = index
                        // Moving right within the same list: account for the removed original.
                        let current = app.library.visibleBookmarks(for: s.site?.id).filter { $0.scope == scope }.map(\.bookmark.id)
                        if let at0 = at, let old = current.firstIndex(of: id), old < at0 { at = at0 - 1 }
                        app.library.setBookmarkScope(id, scope: scope, siteID: s.site?.id, at: at)
                    }
                }
                return true
            }
        }
        return false
    }
}

extension BookmarkScope {
    var color: Color {
        switch self {
        case .global: return .purple
        case .folder: return .orange
        case .site: return .blue
        }
    }
}
