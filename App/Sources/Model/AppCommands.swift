import SwiftUI
import xFinderKit

/// Menu bar commands and keyboard shortcuts.
struct AppCommands: Commands {
    @ObservedObject var app: AppModel
    @ObservedObject var tabs: SessionTabs

    init(app: AppModel) {
        self.app = app
        self.tabs = app.tabs
    }
    @Environment(\.openWindow) private var openWindow


    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { app.updates.checkNow(userInitiated: true) }
        }

        // File: New Tab, Close Tab/Window, favorites and settings import/export.
        // Browser shortcuts (⌘R, ⌘U, ⇧⌘G, …) live in BrowserShortcuts and the toolbar.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { app.tabs.newTab(after: app.tabs.current) }
                .keyboardShortcut("t", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { app.tabs.closeCurrent() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Import Favorites…") { app.importExport.importFavorites() }
            Button("Export Favorites…") { app.importExport.exportFavorites() }
            Divider()
            Button("Import Settings…") { app.importExport.importSettings() }
            Button("Export Settings…") { app.importExport.exportSettings() }
        }

        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}

        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { app.tabs.selectNext(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { app.tabs.selectNext(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1..<10) { i in
                Button("Tab \(i)") { app.tabs.select(index: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
            }
            Divider()
            Button("Transfers") { openWindow(id: "transfers") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
        }
    }
}
