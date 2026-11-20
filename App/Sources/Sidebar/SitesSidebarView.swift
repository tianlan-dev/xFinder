import SwiftUI
import xFinderKit

/// Favorites sidebar with search, + menu and bulk actions.
struct SitesSidebarView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var controller = AppModel.shared.sidebar
    @State private var foldersExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name or address", text: $controller.search)
                    .textFieldStyle(.plain)
                if !controller.search.isEmpty {
                    Button { controller.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 10).padding(.vertical, 6)
            SitesOutline(controller: controller, library: app.library, search: controller.search)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    foldersExpanded.toggle()
                    if foldersExpanded {
                        controller.expandAllToken = abs(controller.expandAllToken) + 1
                    } else {
                        controller.expandAllToken = -(abs(controller.expandAllToken) + 1)
                    }
                } label: {
                    Label(foldersExpanded ? "Collapse All Folders" : "Expand All Folders",
                          systemImage: foldersExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .help(foldersExpanded ? "Collapse All Folders" : "Expand All Folders")
                Menu {
                    Button("New Server…") { controller.newSite(in: selectedFolderID) }
                    Button("New Folder…") { controller.newFolder() }
                    Divider()
                    Button("Import from ~/.ssh/config") { app.importExport.importSSHConfig() }
                    Divider()
                    Button("Import Favorites…") { app.importExport.importFavorites() }
                    Button("Export Favorites…") { app.importExport.exportFavorites() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a server or folder")
            }
        }
        .sheet(item: $controller.editingSite) { e in
            SiteEditView(original: e.site, isNew: e.isNew)
                .environmentObject(app)
        }
        .sheet(item: $controller.editingFolder) { e in
            FolderEditView(original: e.folder, isNew: e.isNew)
                .environmentObject(app)
        }
        .sheet(item: $controller.deleteRequest) { r in
            SidebarDeleteSheet(request: r, controller: controller)
                .environmentObject(app)
        }
    }

    var selectedFolderID: UUID? {
        if controller.selection.count == 1 {
            switch controller.selection[0] {
            case .folder(let id): return id
            case .site(let id): return app.library.site(id)?.folderID
            }
        }
        return nil
    }
}

struct SidebarDeleteSheet: View {
    let request: SidebarController.DeleteRequest
    @ObservedObject var controller: SidebarController
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var folderCount: Int { request.items.filter { if case .folder = $0 { return true }; return false }.count }
    var siteCount: Int { request.items.count - folderCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(folderCount > 0
                 ? "Choose whether to keep the servers inside the folders (they move to the top level) or delete them too. Saved passwords of deleted servers are removed from the Keychain."
                 : "Saved passwords of these servers are removed from the Keychain.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if folderCount > 0 {
                    Button("Delete Folders, Keep Servers") { controller.performDelete(request, keepFolderSites: true); dismiss() }
                    Button("Delete Everything", role: .destructive) { controller.performDelete(request, keepFolderSites: false); dismiss() }
                } else {
                    Button("Delete", role: .destructive) { controller.performDelete(request, keepFolderSites: false); dismiss() }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    var title: String {
        var parts: [String] = []
        if folderCount > 0 { parts.append(folderCount == 1 ? "1 folder" : "\(folderCount) folders") }
        if siteCount > 0 { parts.append(siteCount == 1 ? "1 server" : "\(siteCount) servers") }
        return "Delete " + parts.joined(separator: " and ") + "?"
    }
}
