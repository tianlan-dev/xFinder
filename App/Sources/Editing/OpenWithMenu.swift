import AppKit
import UniformTypeIdentifiers
import xFinderKit

/// "Open With ▸" submenu for a remote file.
@MainActor
enum OpenWithMenu {
    static func build(for item: RemoteItem, session: ConnectionSession, app: AppModel) -> NSMenu {
        let menu = NSMenu()
        let ext = (item.name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
        if let rule = OpenWithResolver.rule(for: item.name, rules: app.settings.openWithRules) {
            let ruleURL = URL(fileURLWithPath: rule.applicationPath)
            apps.removeAll { $0 == ruleURL }
            apps.insert(ruleURL, at: 0)
        }
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: type)
        for url in apps.prefix(20) {
            var title = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            if url == defaultApp { title += " (default)" }
            let mi = ClosureMenuItem(title: title) { app.editSync.open(item, in: session, application: url) }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            menu.addItem(mi)
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "Other…") {
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.prompt = "Open"
            if panel.runModal() == .OK, let url = panel.url {
                app.editSync.open(item, in: session, application: url)
            }
        })
        return menu
    }
}
