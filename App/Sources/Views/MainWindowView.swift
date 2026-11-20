import SwiftUI
import xFinderKit

/// The single main window: favorites sidebar + tabs + transfer status bar.
struct MainWindowView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var tabs: SessionTabs
    @EnvironmentObject var prompts: PromptCenter

    var body: some View {
        NavigationSplitView {
            SitesSidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            VStack(spacing: 0) {
                SessionTabBar()
                Divider()
                if let s = tabs.current {
                    SessionContainer(session: s)
                        .id(s.id)
                } else {
                    Spacer()
                }
                Divider()
                TransferStatusBar()
            }
            .modifier(DetailToolbar(tabs: tabs))
        }
        .sheet(item: Binding(get: { prompts.current }, set: { _ in })) { p in
            PromptSheet(prompt: p)
                .environmentObject(prompts)
                .interactiveDismissDisabled()
        }
        .task { app.updates.scheduleAutomaticCheck() }
    }
}

/// Shows Quick Connect for an empty tab, else the browser.
struct SessionContainer: View {
    @ObservedObject var session: ConnectionSession

    var body: some View {
        if session.site == nil {
            StartView(session: session)
        } else {
            BrowserView(session: session)
        }
    }
}

/// Unified title bar of the detail column: navigation, server title with the
/// current path below it, and the browser actions.
struct DetailToolbar: ViewModifier {
    @ObservedObject var tabs: SessionTabs

    func body(content: Content) -> some View {
        if let s = tabs.current {
            content.modifier(SessionToolbar(session: s))
        } else {
            content.navigationTitle("xFinder")
        }
    }
}

struct SessionToolbar: ViewModifier {
    @ObservedObject var session: ConnectionSession
    @EnvironmentObject var app: AppModel

    var connected: Bool { session.isConnected }

    func body(content: Content) -> some View {
        content
            .navigationTitle(session.site == nil ? "New Tab" : session.title)
            .navigationSubtitle(session.site == nil ? "" : session.currentPath)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { session.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!session.canGoBack).help("Back (⌘[)")
                    Button { session.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                        .disabled(!session.canGoForward).help("Forward (⌘])")
                    Button { session.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.up") }
                        .disabled(!connected || session.currentPath == "/").help("Enclosing Folder (⌘↑)")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if session.isLoading { ProgressView().controlSize(.small) }
                    Button { app.browserActions.openTerminalHere() } label: { Label("Open in Terminal", systemImage: "terminal") }
                        .disabled(!(session.site?.protocolType.isSSH ?? false)).help("Open in Terminal (⌥⌘T)")
                    Button { session.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(!connected).help("Refresh (⌘R)")
                    Button { session.sheet = .newFolder(parent: session.currentPath) } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(!connected || !session.capabilities.contains(.mkdir)).help("New Folder (⇧⌘N)")
                    Button { app.browserActions.chooseAndUpload() } label: { Label("Upload", systemImage: "tray.and.arrow.up") }
                        .disabled(!connected).help("Upload (⌘U)")
                    Button { app.browserActions.downloadSelection(to: nil) } label: {
                        Label("Download", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!connected || session.selection.isEmpty).help("Download to \(app.downloadFolderName) (⇧⌘D)")
                    Button { session.sheet = .goToFolder } label: { Label("Go to Folder", systemImage: "arrow.right.circle") }
                        .disabled(!connected).help("Go to Folder (⇧⌘G)")
                    Button { session.showHidden.toggle() } label: {
                        Label {
                            Text(session.showHidden ? "Hide Hidden Files" : "Show Hidden Files")
                        } icon: {
                            HiddenFilesIcon(on: session.showHidden)
                        }
                    }
                    .help(session.showHidden ? "Hide Hidden Files (⇧⌘.)" : "Show Hidden Files (⇧⌘.)")
                    Button { session.disconnect() } label: { Label("Disconnect", systemImage: "eject") }
                        .disabled(!connected && session.status != .connecting).help("Disconnect")
                }
            }
            .background(BrowserShortcuts(session: session))
    }
}

/// Eye icon; drawn as a filled accent circle with a white eye when on.
struct HiddenFilesIcon: View {
    let on: Bool
    var body: some View {
        if on {
            Image(systemName: "eye.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
        } else {
            Image(systemName: "eye")
        }
    }
}

/// Keyboard shortcuts of the browser that have no menu item.
struct BrowserShortcuts: View {
    @ObservedObject var session: ConnectionSession
    @EnvironmentObject var app: AppModel

    var body: some View {
        let connected = session.isConnected
        ZStack {
            shortcut("[", .command, enabled: session.canGoBack) { session.goBack() }
            shortcut("]", .command, enabled: session.canGoForward) { session.goForward() }
            shortcut(.upArrow, .command, enabled: connected) { session.goUp() }
            shortcut(.downArrow, .command, enabled: connected) { app.browserActions.openSelection() }
            shortcut("o", .command, enabled: connected) { app.browserActions.openSelection() }
            shortcut("r", .command, enabled: connected) { session.refresh() }
            shortcut("g", [.command, .shift], enabled: connected) { session.sheet = .goToFolder }
            shortcut("n", [.command, .shift], enabled: connected) { session.sheet = .newFolder(parent: session.currentPath) }
            shortcut("u", .command, enabled: connected) { app.browserActions.chooseAndUpload() }
            shortcut("d", [.command, .shift], enabled: connected) { app.browserActions.downloadSelection(to: nil) }
            shortcut("d", .command, enabled: connected) { app.browserActions.duplicateSelection() }
            shortcut("i", .command, enabled: connected) { app.browserActions.getInfo() }
            shortcut(.delete, .command, enabled: connected && app.fileListFocused) { app.browserActions.confirmDeleteSelection() }
            shortcut(".", [.command, .shift], enabled: true) { session.showHidden.toggle() }
            shortcut("t", [.command, .option], enabled: session.site?.protocolType.isSSH ?? false) { app.browserActions.openTerminalHere() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!enabled)
    }
}
