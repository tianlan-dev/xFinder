import SwiftUI
import xFinderKit

@main
struct xFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        Window("xFinder", id: "main") {
            MainWindowView()
                .environmentObject(app)
                .environmentObject(app.tabs)
                .environmentObject(app.prompts)
                .environmentObject(app.transfers)
                .frame(minWidth: 820, minHeight: 480)
        }
        .commands { AppCommands(app: app) }

        Window("Transfers", id: "transfers") {
            TransfersView()
                .environmentObject(app)
                .environmentObject(app.transfers)
                .environmentObject(app.editSync)
                .frame(minWidth: 560, minHeight: 300)
        }
        .keyboardShortcut("l", modifiers: [.command, .option])

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Confirms quitting while transfers run or edited files are not uploaded yet.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let app = MainActor.assumeIsolated { AppModel.shared }
        let (busy, pending) = MainActor.assumeIsolated { (app.transfers.hasActiveTransfers, app.editSync.hasPendingUploads) }
        if MainActor.assumeIsolated({ app.skipQuitConfirmation }) { return .terminateNow }
        guard busy || pending else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit xFinder?"
        var lines: [String] = []
        if busy { lines.append("Transfers are still in progress and will be stopped.") }
        if pending { lines.append("Some edited files have not been uploaded yet.") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
