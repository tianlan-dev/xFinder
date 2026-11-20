import SwiftUI
import AppKit
import UniformTypeIdentifiers
import xFinderKit

/// Commands acting on the current tab's browser (menus, toolbar, context menus).
@MainActor
final class BrowserActions {
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    var session: ConnectionSession? { app.tabs.current }

    func openSelection() {
        guard let s = session else { return }
        let items = s.selectedItems
        if items.count == 1, items[0].isDirectoryLike {
            s.navigate(to: items[0].type == .symlink ? (items[0].symlinkTarget ?? items[0].path) : items[0].path)
            return
        }
        for item in items where !item.isDirectoryLike {
            app.editSync.open(item, in: s, application: nil)
        }
    }

    func open(_ item: RemoteItem, in s: ConnectionSession) {
        if item.isDirectoryLike {
            s.navigate(to: item.type == .symlink ? (item.symlinkTarget ?? item.path) : item.path)
        } else {
            app.editSync.open(item, in: s, application: nil)
        }
    }

    func getInfo() {
        guard let s = session, let item = s.selectedItems.first else { return }
        s.sheet = .info(item)
    }

    func confirmDeleteSelection() {
        guard let s = session, !s.selectedItems.isEmpty else { return }
        s.sheet = .confirmDelete(s.selectedItems)
    }

    func copyPath() {
        guard let s = session else { return }
        let paths = s.selectedItems.map(\.path)
        let text = paths.isEmpty ? s.currentPath : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func chooseAndUpload(into folder: String? = nil) {
        guard let s = session, s.isConnected else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(folder ?? s.currentPath)"
        guard panel.runModal() == .OK else { return }
        app.transfers.upload(panel.urls, to: folder ?? s.currentPath, session: s)
    }

    func downloadSelection(to directory: URL?) {
        guard let s = session, s.isConnected else { return }
        let items = s.selectedItems
        guard !items.isEmpty else { return }
        app.transfers.download(items, to: directory ?? app.settings.downloadDirectoryURL, session: s)
    }

    func downloadSelectionChoosingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadSelection(to: url)
    }

    func duplicateSelection() {
        guard let s = session else { return }
        app.transfers.duplicate(s.selectedItems, session: s)
    }

    func openTerminalHere() {
        guard let s = session, let site = s.site else { return }
        app.terminal.open(site: site, path: s.isConnected ? s.currentPath : nil)
    }
}
