import SwiftUI
import AppKit
import UniformTypeIdentifiers
import xFinderKit

/// App-side owner of remote edit sessions.
@MainActor
final class EditSyncCenter: ObservableObject {
    unowned let app: AppModel
    let service: EditSyncService
    private var cancellable: Any?

    init(app: AppModel) {
        self.app = app
        service = EditSyncService(pool: app.transfers.manager.pool, editRoot: app.paths.editDirectory)
        service.conflictHandler = { [weak self] s in await self?.askConflict(s) ?? .decideLater }
        cancellable = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var hasPendingUploads: Bool { service.hasPendingUploads }

    func serverConnected(siteID: UUID) {
        service.retryUnreachable(endpointID: "site:\(siteID.uuidString)")
    }

    /// Downloads and opens with `application`, a matching Open With rule, or the default app.
    func open(_ item: RemoteItem, in session: ConnectionSession, application: URL?) {
        Task {
            guard let ep = await app.transfers.registeredEndpoint(for: session) else {
                session.message = "Connect to the server first."
                return
            }
            do {
                let local = try await service.open(item.path, endpoint: ep)
                try openLocal(local, application: application)
            } catch {
                session.message = "Could not open “\(item.name)”: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
        }
    }

    private func openLocal(_ url: URL, application: URL?) throws {
        var appURL = application
        if appURL == nil, let rule = OpenWithResolver.rule(for: url.lastPathComponent, rules: app.settings.openWithRules) {
            appURL = URL(fileURLWithPath: rule.applicationPath)
        }
        if appURL == nil { appURL = NSWorkspace.shared.urlForApplication(toOpen: url) }
        if appURL == nil { appURL = chooseApplication(for: url) }
        guard let appURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// No default app: let the user pick one and optionally remember it.
    private func chooseApplication(for url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an application to open “\(url.lastPathComponent)”."
        let remember = NSButton(checkboxWithTitle: "Always open files like this with the chosen application", target: nil, action: nil)
        panel.accessoryView = remember
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        if remember.state == .on {
            let ext = url.pathExtension
            let rule = ext.isEmpty
                ? OpenWithRule(kind: .fileName, pattern: url.lastPathComponent, applicationPath: chosen.path)
                : OpenWithRule(kind: .extensions, pattern: ext, applicationPath: chosen.path)
            app.settings.openWithRules.append(rule)
        }
        return chosen
    }

    private func askConflict(_ s: EditSession) async -> EditConflictChoice {
        let alert = NSAlert()
        alert.messageText = "“\(s.name)” was changed on the server"
        alert.informativeText = "Someone else modified \(s.remotePath) on \(s.endpoint.label) since you opened it."
        alert.addButton(withTitle: "Replace Server Version")
        alert.addButton(withTitle: "Upload as a Copy")
        alert.addButton(withTitle: "Discard My Changes")
        alert.addButton(withTitle: "Decide Later")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replaceServerVersion
        case .alertSecondButtonReturn: return .uploadAsCopy
        case .alertThirdButtonReturn: return .discardMyChanges
        default: return .decideLater
        }
    }
}

/// Files being edited, shown in the Transfers window.
struct EditSessionsSection: View {
    @EnvironmentObject var editSync: EditSyncCenter

    var body: some View {
        if !editSync.service.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Edited files").font(.headline)
                    Spacer()
                    Button("Clean Up Unchanged") { editSync.service.cleanUpUnchanged() }
                }
                ForEach(editSync.service.sessions) { s in EditSessionRow(session: s) }
            }
            .padding(10)
            Divider()
        }
    }
}

struct EditSessionRow: View {
    @ObservedObject var session: EditSession
    @EnvironmentObject var editSync: EditSyncCenter

    var body: some View {
        HStack {
            Image(systemName: "pencil.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                Text(detail).font(.caption).foregroundStyle(color).lineLimit(2)
            }
            Spacer()
            switch session.status {
            case .unreachable, .failed:
                Button(isFailed ? "Retry" : "Try Now") { editSync.service.retryNow(session) }
            case .conflict:
                Menu("Resolve") {
                    Button("Replace Server Version") { Task { await editSync.service.resolveConflict(session, choice: .replaceServerVersion) } }
                    Button("Upload as a Copy") { Task { await editSync.service.resolveConflict(session, choice: .uploadAsCopy) } }
                    Button("Discard My Changes") { Task { await editSync.service.resolveConflict(session, choice: .discardMyChanges) } }
                }
                .fixedSize()
            default:
                EmptyView()
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([session.localURL]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show the local copy in Finder")
            Button { editSync.service.stopWatching(session) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Stop watching")
        }
    }

    var isFailed: Bool { if case .failed = session.status { return true }; return false }

    var color: Color {
        switch session.status {
        case .failed, .downloadFailed: return .red
        case .unreachable, .conflict: return .orange
        default: return .secondary
        }
    }

    var detail: String {
        var parts = ["\(session.endpoint.label):\(session.remotePath)", session.status.label]
        if let last = session.lastUpload { parts.append("Uploaded \(last.formatted(date: .omitted, time: .standard))") }
        if let next = session.nextRetry { parts.append("Next retry \(next.formatted(date: .omitted, time: .standard))") }
        return parts.joined(separator: " · ")
    }
}
