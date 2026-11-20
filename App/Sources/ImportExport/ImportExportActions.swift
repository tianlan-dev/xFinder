import SwiftUI
import AppKit
import UniformTypeIdentifiers
import xFinderKit

/// File ▸ Import/Export for favorites and settings, Transmit and ~/.ssh/config.
@MainActor
final class ImportExportActions {
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    private func save(_ data: Data, suggested: String, title: String) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { show("Export failed", error) }
    }

    private func choose(_ title: String, types: [UTType]? = nil, directory: URL? = nil, showHidden: Bool = false) -> Data? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        if let types { panel.allowedContentTypes = types }
        if let directory { panel.directoryURL = directory }
        panel.showsHiddenFiles = showHidden
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try Data(contentsOf: url) } catch { show("Cannot read the file", error); return nil }
    }

    private func show(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        a.runModal()
    }

    private func report(_ title: String, _ r: ImportReport) {
        let a = NSAlert()
        a.messageText = title
        var text = r.summary
        if !r.notes.isEmpty { text += "\n\n" + r.notes.joined(separator: "\n") }
        if !r.skipped.isEmpty { text += "\n\nSkipped:\n" + r.skipped.joined(separator: "\n") }
        a.informativeText = text
        a.runModal()
    }

    // MARK: Favorites

    func exportFavorites() {
        do {
            let data = try FavoritesTransfer.export(library: app.library, keys: app.keys, accounts: app.accounts)
            save(data, suggested: "xFinder Favorites.json", title: "Export Favorites")
        } catch { show("Export failed", error) }
    }

    func importFavorites() {
        guard let data = choose("Import Favorites", types: [.json]) else { return }
        var lib = app.library, keys = app.keys, accounts = app.accounts
        do {
            let r = try FavoritesTransfer.importData(data, library: &lib, keys: &keys, accounts: &accounts)
            app.keys = keys
            app.accounts = accounts
            app.library = lib
            report("Favorites imported", r)
        } catch { show("Import failed", error) }
    }

    func importTransmit() {
        guard let data = choose("Import from Transmit") else { return }
        do {
            let parsed = try TransmitImporter.parse(data)
            var lib = app.library
            let r = TransmitImporter.importServers(parsed, library: &lib)
            app.library = lib
            report("Transmit favorites imported", r)
        } catch { show("Import failed", error) }
    }

    func importSSHConfig() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            show("Cannot read ~/.ssh/config", RemoteError.notFound(url.path))
            return
        }
        var lib = app.library, keys = app.keys
        let r = SSHConfigImporter.importEntries(SSHConfigImporter.parse(text), library: &lib, keys: &keys)
        app.keys = keys
        app.library = lib
        report("SSH config imported", r)
    }

    // MARK: Settings

    func exportSettings() {
        do {
            let data = try SettingsTransfer.export(settings: app.settings, keys: app.keys, accounts: app.accounts)
            save(data, suggested: "xFinder Settings.json", title: "Export Settings")
        } catch { show("Export failed", error) }
    }

    func importSettings() {
        guard let data = choose("Import Settings", types: [.json]) else { return }
        do {
            let preview = try SettingsTransfer.read(data)
            let a = NSAlert()
            a.messageText = "Replace your preferences?"
            a.informativeText = "Your preferences and Open With rules will be replaced. \(preview.keyCount) keys and \(preview.accountCount) accounts will be merged; existing ones stay unchanged."
            a.addButton(withTitle: "Import")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            var s = app.settings, keys = app.keys, accounts = app.accounts
            let r = SettingsTransfer.apply(preview, settings: &s, keys: &keys, accounts: &accounts)
            app.keys = keys
            app.accounts = accounts
            app.settings = s
            report("Settings imported", r)
        } catch { show("Import failed", error) }
    }
}
