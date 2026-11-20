import SwiftUI
import xFinderKit

/// State for sidebar sheets and confirmations.
@MainActor
final class SidebarController: ObservableObject {
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    struct SiteEditing: Identifiable {
        let id = UUID()
        var site: Site
        var isNew: Bool
    }
    struct FolderEditing: Identifiable {
        let id = UUID()
        var folder: SiteFolder
        var isNew: Bool
    }
    struct DeleteRequest: Identifiable {
        let id = UUID()
        var items: [LibraryItemRef]
    }

    @Published var editingSite: SiteEditing?
    @Published var editingFolder: FolderEditing?
    @Published var deleteRequest: DeleteRequest?
    @Published var selection: [LibraryItemRef] = []
    @Published var search = ""
    /// Bumped to expand (+) or collapse (-) all folders.
    @Published var expandAllToken = 0

    func newSite(in folder: UUID?) {
        var s = Site(protocolType: .sftp)
        s.folderID = folder
        editingSite = SiteEditing(site: s, isNew: true)
    }

    func edit(siteID: UUID) {
        if let s = app.library.site(siteID) { editingSite = SiteEditing(site: s, isNew: false) }
    }

    func newFolder() {
        editingFolder = FolderEditing(folder: SiteFolder(name: app.library.uniqueFolderName("New Folder")), isNew: true)
    }

    func edit(folderID: UUID) {
        if let f = app.library.folder(folderID) { editingFolder = FolderEditing(folder: f, isNew: false) }
    }

    var selectedSites: [Site] {
        var out: [Site] = []
        for ref in selection {
            switch ref {
            case .site(let id): if let s = app.library.site(id) { out.append(s) }
            case .folder(let id): out += app.library.sites(inFolder: id)
            }
        }
        var seen = Set<UUID>()
        return out.filter { seen.insert($0.id).inserted }
    }

    /// Double-click / Return on a site: browser or terminal per settings.
    func activate(_ site: Site) {
        if app.settings.doubleClickAction == .terminal && site.protocolType.isSSH {
            app.terminal.open(site: site, path: nil)
        } else {
            app.tabs.open(site)
        }
    }

    func performDelete(_ request: DeleteRequest, keepFolderSites: Bool) {
        var siteIDs = Set<UUID>()
        for ref in request.items {
            switch ref {
            case .site(let id): siteIDs.insert(id)
            case .folder(let id): app.deleteFolder(id, keepSites: keepFolderSites)
            }
        }
        if !siteIDs.isEmpty { app.deleteSites(siteIDs) }
        selection = []
    }
}
