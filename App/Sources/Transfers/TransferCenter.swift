import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import xFinderKit

/// App-side owner of the transfer queue: maps tabs to endpoints, asks about
/// conflicts and refreshes listings when transfers finish.
@MainActor
final class TransferCenter: ObservableObject {
    unowned let app: AppModel
    let manager: TransferManager
    /// Endpoints for tabs seen so far, so pasting still works after the source tab closed.
    private var endpointsBySession: [UUID: RemoteEndpoint] = [:]
    private var pendingRefresh: [String: Set<String>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var factories: [String: TransferConnectionPool.Factory] = [:]

    init(app: AppModel) {
        self.app = app
        manager = TransferManager(stagingRoot: app.paths.stagingDirectory)
        manager.maxConcurrent = app.settings.maxConcurrentTransfers
        manager.conflictPolicy = app.settings.conflictPolicy
        manager.conflictHandler = { [weak self] conflict in
            await self?.askConflict(conflict) ?? ConflictAnswer(.skip)
        }
        manager.onItemFinished = { [weak self] item in self?.itemFinished(item) }
        manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        app.$settings.sink { [weak self] s in
            self?.manager.maxConcurrent = s.maxConcurrentTransfers
            self?.manager.conflictPolicy = s.conflictPolicy
        }.store(in: &cancellables)
    }

    var hasActiveTransfers: Bool { manager.hasActiveTransfers }
    var summary: String { manager.summary }

    // MARK: Endpoints

    /// Registers the tab's connection as a template for transfer connections.
    func endpoint(for session: ConnectionSession) -> RemoteEndpoint? {
        guard let site = session.site, let fs = session.fileSystem, session.isConnected else {
            return endpointsBySession[session.id]
        }
        let endpoint = RemoteEndpoint(id: "site:\(site.id.uuidString)", label: site.displayName.isEmpty ? site.host : site.displayName,
                                      capabilities: fs.capabilities)
        endpointsBySession[session.id] = endpoint
        factories[endpoint.id] = { try await fs.makeTransferConnection() }
        return endpoint
    }

    /// Endpoint for a tab with its connection factory registered in the shared pool.
    func registeredEndpoint(for session: ConnectionSession) async -> RemoteEndpoint? {
        guard let ep = endpoint(for: session) else { return nil }
        if let f = factories[ep.id] { await manager.pool.register(ep.id, factory: f) }
        return ep
    }

    private func requireEndpoint(_ session: ConnectionSession) -> RemoteEndpoint? {
        if let e = endpoint(for: session) { return e }
        session.message = "Connect to the server first."
        return nil
    }

    private func enqueue(_ request: TransferRequest, session: ConnectionSession) {
        let pool = manager.pool
        let factories = factories
        Task { @MainActor in
            for (id, factory) in factories { await pool.register(id, factory: factory) }
            do { try manager.enqueue(request) } catch {
                session.message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    // MARK: Entry points

    func upload(_ urls: [URL], to folder: String, session: ConnectionSession) {
        guard !urls.isEmpty, let ep = requireEndpoint(session) else { return }
        enqueue(.upload(urls, to: ep, directory: folder), session: session)
    }

    func download(_ items: [RemoteItem], to directory: URL, session: ConnectionSession) {
        guard !items.isEmpty, let ep = requireEndpoint(session) else { return }
        enqueue(.download(items, from: ep, to: directory), session: session)
    }

    func duplicate(_ items: [RemoteItem], session: ConnectionSession) {
        guard !items.isEmpty, let ep = requireEndpoint(session) else { return }
        let groups = Dictionary(grouping: items) { RemotePath.parent($0.path) }
        for (parent, group) in groups.sorted(by: { $0.key < $1.key }) {
            enqueue(.copy(group, from: ep, to: ep, directory: parent, duplicate: true), session: session)
        }
    }

    func pasteRemote(_ payload: RemoteDragPayload, into folder: String, target: ConnectionSession) {
        guard let dest = requireEndpoint(target) else { return }
        let sourceEndpoint: RemoteEndpoint?
        if let s = app.tabs.session(for: payload.sessionID) {
            sourceEndpoint = endpoint(for: s)
        } else {
            sourceEndpoint = endpointsBySession[payload.sessionID]
        }
        guard let src = sourceEndpoint else {
            target.message = "The server the items were copied from is no longer connected."
            return
        }
        let items = payload.entries.map {
            RemoteItem(name: $0.name, path: $0.path, type: $0.isDirectory ? .directory : .file, size: $0.size)
        }
        enqueue(.copy(items, from: src, to: dest, directory: folder, duplicate: false), session: target)
    }

    func handleRemoteDrop(_ payload: RemoteDragPayload, into folder: String, target: ConnectionSession, copy: Bool) {
        if !copy, payload.sessionID == target.id {
            let paths = payload.entries.map(\.path).filter { RemotePath.parent($0) != RemotePath.normalize(folder) }
            guard !paths.isEmpty else { return }
            Task { await target.move(paths, into: folder) }
        } else {
            pasteRemote(payload, into: folder, target: target)
        }
    }

    // MARK: Finder drag-out

    func filePromiseProvider(for item: RemoteItem, session: ConnectionSession) -> NSPasteboardWriting? {
        guard session.isConnected else { return nil }
        if item.type == .symlink {
            // Links can be moved within the app but are not downloaded.
            let pbItem = NSPasteboardItem()
            pbItem.setData(RemoteDragPayload(session: session, items: [item]).data(), forType: RemoteDragPayload.pasteboardType)
            return pbItem
        }
        let type: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        let delegate = PromiseDelegate(center: self, item: item, sessionID: session.id)
        let provider = RetainingPromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.retainedDelegate = delegate
        let payload = RemoteDragPayload(session: session, items: [item])
        provider.userInfo = payload.data()
        return provider
    }

    fileprivate func fulfillPromise(item: RemoteItem, sessionID: UUID, destination: URL) {
        guard let session = app.tabs.session(for: sessionID), let ep = endpoint(for: session) else { return }
        // Finder picks the file name; download into its folder under that name.
        var renamed = item
        renamed.name = destination.lastPathComponent
        let dir = destination.deletingLastPathComponent()
        if renamed.name == item.name {
            enqueue(.download([item], from: ep, to: dir), session: session)
        } else {
            enqueue(.download([renamed], from: ep, to: dir), session: session)
        }
    }

    // MARK: Conflicts

    private func askConflict(_ c: TransferConflict) async -> ConflictAnswer {
        let alert = NSAlert()
        alert.messageText = "“\(c.name)” already exists"
        func describe(_ size: UInt64?, _ date: Date?, newer: Bool) -> String {
            var parts: [String] = []
            if let size { parts.append(TransferFormat.bytes(size)) }
            if let date { parts.append(date.formatted(date: .abbreviated, time: .standard)) }
            if newer { parts.append("(newer)") }
            return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")
        }
        alert.informativeText = """
        Destination: \(c.destination)
        New item: \(describe(c.sourceSize, c.sourceDate, newer: c.newer == .source))
        Existing item: \(describe(c.destinationSize, c.destinationDate, newer: c.newer == .destination))
        """
        var decisions: [ConflictDecision] = [.replace, .keepBoth, .skip]
        if c.canResume { decisions.append(.resume) }
        decisions.append(.stop)
        for d in decisions {
            switch d {
            case .replace: alert.addButton(withTitle: "Replace")
            case .keepBoth: alert.addButton(withTitle: "Keep Both")
            case .skip: alert.addButton(withTitle: "Skip")
            case .resume: alert.addButton(withTitle: "Resume")
            case .stop: alert.addButton(withTitle: c.isCopy ? "Stop" : "Cancel All")
            }
        }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all remaining conflicts"
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            response = await withCheckedContinuation { cont in
                alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
            }
        } else {
            NSApp.activate()
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let decision = decisions.indices.contains(index) ? decisions[index] : .stop
        return ConflictAnswer(decision, applyToAll: alert.suppressionButton?.state == .on)
    }

    // MARK: Refresh after transfers

    private func itemFinished(_ item: TransferItem) {
        guard item.state == .completed || item.kind == .serverCopy,
              case .remote(let ep, let path) = item.destination else { return }
        pendingRefresh[ep.id, default: []].insert(RemotePath.parent(path))
        if item.kind == .serverCopy { pendingRefresh[ep.id, default: []].insert(path) }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let pending = self.pendingRefresh
            self.pendingRefresh = [:]
            for session in self.app.tabs.sessions where session.isConnected {
                guard let site = session.site, let folders = pending["site:\(site.id.uuidString)"] else { continue }
                if folders.contains(where: { $0 == session.currentPath || session.expanded.contains($0)
                    || RemotePath.isSameOrDescendant($0, of: session.currentPath) && RemotePath.parent($0) == session.currentPath }) {
                    session.refresh()
                }
            }
        }
    }
}

/// NSFilePromiseProvider does not retain its delegate.
final class RetainingPromiseProvider: NSFilePromiseProvider {
    var retainedDelegate: AnyObject?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [RemoteDragPayload.pasteboardType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == RemoteDragPayload.pasteboardType { return userInfo as? Data }
        return super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == RemoteDragPayload.pasteboardType { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    weak var center: TransferCenter?
    let item: RemoteItem
    let sessionID: UUID

    init(center: TransferCenter, item: RemoteItem, sessionID: UUID) {
        self.center = center
        self.item = item
        self.sessionID = sessionID
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let item = item, sessionID = sessionID
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.center?.fulfillPromise(item: item, sessionID: sessionID, destination: url)
            }
            // The download continues in the transfer queue with visible progress.
            completionHandler(nil)
        }
    }
}
