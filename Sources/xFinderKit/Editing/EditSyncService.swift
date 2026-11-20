import Foundation
import Combine
import Network
import Crypto

/// State of one remotely edited file.
public enum EditStatus: Equatable, Sendable {
    case downloading
    /// Local copy matches the server.
    case inSync
    /// Saved locally; waiting until the file is stable.
    case changed
    case uploading
    /// Server unreachable; retried automatically.
    case unreachable(String)
    /// An error retrying cannot fix (auth, permission, not found).
    case failed(String)
    /// The server file was changed by someone else.
    case conflict
    case downloadFailed(String)

    public var label: String {
        switch self {
        case .downloading: return "Downloading"
        case .inSync: return "Up to date"
        case .changed: return "Changed"
        case .uploading: return "Uploading"
        case .unreachable: return "Server unreachable"
        case .failed(let m): return "Upload failed: \(m)"
        case .conflict: return "Changed on the server"
        case .downloadFailed(let m): return "Download failed: \(m)"
        }
    }
}

public enum EditConflictChoice: Sendable {
    case replaceServerVersion
    case uploadAsCopy
    case discardMyChanges
    case decideLater
}

struct FileStamp: Equatable {
    var size: UInt64
    var modified: Date

    static func of(_ url: URL) -> FileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(size: (a[.size] as? NSNumber)?.uint64Value ?? 0, modified: a[.modificationDate] as? Date ?? .distantPast)
    }
}

/// A file opened for editing.
@MainActor
public final class EditSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let endpoint: RemoteEndpoint
    public let remotePath: String
    public let localURL: URL
    @Published public internal(set) var status: EditStatus = .downloading
    @Published public internal(set) var lastUpload: Date?
    @Published public internal(set) var nextRetry: Date?

    public var name: String { RemotePath.lastComponent(remotePath) }

    /// Server size/date when we last downloaded or uploaded.
    var remoteBaseline: (size: UInt64?, date: Date?)
    /// Local stamp the server currently matches.
    var syncedStamp: FileStamp?
    var lastSeenStamp: FileStamp?
    var stableSince: Date?
    var retryCount = 0
    var task: Task<Void, Never>?

    init(endpoint: RemoteEndpoint, remotePath: String, localURL: URL) {
        self.endpoint = endpoint
        self.remotePath = remotePath
        self.localURL = localURL
    }

    /// True when the local file has changes not on the server.
    public var hasUnsavedChanges: Bool {
        if status == .downloading { return false }
        guard let s = FileStamp.of(localURL) else { return false }
        return s != syncedStamp
    }
}

/// Downloads remote files for editing, watches them and uploads each save.
///
/// Size and modification time are checked every 0.5 s; a change is uploaded once
/// it has been stable for 0.8 s. Unreachable servers are retried after
/// `min(60, 10·2^(n-1))` seconds, immediately when the network returns or a tab
/// connects to that server.
@MainActor
public final class EditSyncService: ObservableObject {
    @Published public private(set) var sessions: [EditSession] = []

    public let pool: TransferConnectionPool
    public let editRoot: URL
    public var pollInterval: TimeInterval = 0.5
    public var stableInterval: TimeInterval = 0.8
    /// Asked when the server file changed underneath us.
    public var conflictHandler: (@MainActor (EditSession) async -> EditConflictChoice)?

    private var timer: Timer?
    private var monitor: NWPathMonitor?

    public init(pool: TransferConnectionPool, editRoot: URL) {
        self.pool = pool
        self.editRoot = editRoot
    }

    public static func retryDelay(attempt n: Int) -> TimeInterval {
        min(60, 10 * pow(2, Double(max(1, n) - 1)))
    }

    public var hasPendingUploads: Bool {
        sessions.contains { s in
            switch s.status {
            case .changed, .uploading, .unreachable, .failed, .conflict: return true
            default: return s.hasUnsavedChanges
            }
        }
    }

    public func session(endpointID: String, remotePath: String) -> EditSession? {
        sessions.first { $0.endpoint.id == endpointID && $0.remotePath == RemotePath.normalize(remotePath) }
    }

    /// Local path for a remote file: Edit/<server hash>/<remote path>.
    public func localURL(endpointID: String, remotePath: String) -> URL {
        let digest = SHA256.hash(data: Data(endpointID.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        var url = editRoot.appendingPathComponent(digest, isDirectory: true)
        for comp in RemotePath.normalize(remotePath).split(separator: "/") {
            url.appendPathComponent(String(comp).replacingOccurrences(of: ":", with: "_"))
        }
        return url
    }

    // MARK: Opening

    /// Downloads (unless a local copy with pending changes exists) and starts watching.
    /// Returns the local file to open.
    public func open(_ remotePath: String, endpoint: RemoteEndpoint) async throws -> URL {
        let path = RemotePath.normalize(remotePath)
        if let existing = session(endpointID: endpoint.id, remotePath: path) {
            if existing.hasUnsavedChanges || existing.status != .inSync {
                return existing.localURL  // never overwrite un-uploaded changes
            }
            try await download(existing)
            return existing.localURL
        }
        let s = EditSession(endpoint: endpoint, remotePath: path, localURL: localURL(endpointID: endpoint.id, remotePath: path))
        sessions.append(s)
        do {
            try await download(s)
        } catch {
            s.status = .downloadFailed(Self.describe(error))
            throw error
        }
        startTimers()
        return s.localURL
    }

    private func download(_ s: EditSession) async throws {
        s.status = .downloading
        let fm = FileManager.default
        try fm.createDirectory(at: s.localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = s.localURL.deletingLastPathComponent().appendingPathComponent(TransferNaming.localTemporaryName(s.localURL.lastPathComponent))
        let item: RemoteItem = try await withConnection(s.endpoint) { conn in
            let item = try await conn.stat(s.remotePath)
            try await conn.download(s.remotePath, to: temp, offset: 0) { _ in }
            return item
        }
        if fm.fileExists(atPath: s.localURL.path) {
            _ = try fm.replaceItemAt(s.localURL, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: s.localURL)
        }
        s.remoteBaseline = (item.size, item.modificationDate)
        s.syncedStamp = FileStamp.of(s.localURL)
        s.lastSeenStamp = s.syncedStamp
        s.stableSince = nil
        s.status = .inSync
    }

    // MARK: Watching

    private func startTimers() {
        if timer == nil {
            let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        if monitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.retryUnreachable(endpointID: nil) } }
            }
            m.start(queue: DispatchQueue(label: "xfinder.edit.path"))
            monitor = m
        }
    }

    func poll(now: Date = Date()) {
        for s in sessions {
            switch s.status {
            case .inSync, .changed, .failed:
                break
            case .unreachable:
                if let next = s.nextRetry, next <= now { upload(s) }
                continue
            default:
                continue
            }
            guard let stamp = FileStamp.of(s.localURL) else { continue }
            if stamp != s.lastSeenStamp {
                s.lastSeenStamp = stamp
                s.stableSince = now
                if stamp != s.syncedStamp { s.status = .changed }
                continue
            }
            if s.status == .changed, let since = s.stableSince, now.timeIntervalSince(since) >= stableInterval {
                upload(s)
            }
        }
    }

    // MARK: Uploading

    public func retryNow(_ s: EditSession) {
        s.retryCount = 0
        upload(s)
    }

    /// Called when the network comes back or a tab connects to the server.
    public func retryUnreachable(endpointID: String?) {
        for s in sessions {
            guard case .unreachable = s.status else { continue }
            if let id = endpointID, s.endpoint.id != id { continue }
            upload(s)
        }
    }

    func upload(_ s: EditSession, force: Bool = false) {
        guard s.task == nil else { return }
        s.status = .uploading
        s.nextRetry = nil
        s.task = Task { [weak self] in
            guard let self else { return }
            await self.performUpload(s, force: force)
            s.task = nil
        }
    }

    private func performUpload(_ s: EditSession, force: Bool) async {
        guard let stamp = FileStamp.of(s.localURL) else {
            s.status = .failed("The local copy is missing.")
            return
        }
        do {
            let conflict: Bool = try await withConnection(s.endpoint) { conn in
                if !force, let current = try? await conn.stat(s.remotePath) {
                    let (size, date) = s.remoteBaseline
                    let changed = (size != nil && current.size != size)
                        || (date != nil && current.modificationDate != nil && abs(current.modificationDate!.timeIntervalSince(date!)) > 1)
                    if changed { return true }
                }
                try await Self.safeUpload(conn, local: s.localURL, to: s.remotePath, capabilities: s.endpoint.capabilities)
                let after = try? await conn.stat(s.remotePath)
                s.remoteBaseline = (after?.size, after?.modificationDate)
                return false
            }
            if conflict {
                s.status = .conflict
                // Ask after this upload task has finished so a "replace" answer can start a new one.
                Task { [weak self] in await self?.askConflict(s) }
                return
            }
            s.syncedStamp = stamp
            s.lastUpload = Date()
            s.retryCount = 0
            // Saved again while uploading?
            s.status = FileStamp.of(s.localURL) == stamp ? .inSync : .changed
        } catch {
            let message = Self.describe(error)
            if let e = error as? RemoteError, e.isPermanent {
                s.status = .failed(message)
            } else {
                s.retryCount += 1
                s.status = .unreachable(message)
                s.nextRetry = Date().addingTimeInterval(Self.retryDelay(attempt: s.retryCount))
            }
        }
    }

    /// Upload through a temporary `.name.rfpart` file, keeping permissions.
    static func safeUpload(_ conn: RemoteFileSystem, local: URL, to path: String, capabilities: RemoteCapabilities) async throws {
        if capabilities.contains(.atomicUpload) {
            try await conn.upload(local, to: path, offset: 0) { _ in }
            return
        }
        let temp = RemotePath.join(RemotePath.parent(path), TransferNaming.remoteTemporaryName(RemotePath.lastComponent(path)))
        let original = try? await conn.stat(path)
        try await conn.upload(local, to: temp, offset: 0) { _ in }
        do {
            try await conn.rename(temp, to: path)
        } catch {
            guard original != nil else { try? await conn.delete(temp, isDirectory: false); throw error }
            try await conn.delete(path, isDirectory: false)
            try await conn.rename(temp, to: path)
        }
        if capabilities.contains(.chmod), let mode = original?.permissions {
            try? await conn.setPermissions(path, mode: mode)
        }
    }

    private func askConflict(_ s: EditSession) async {
        let choice = await conflictHandler?(s) ?? .decideLater
        await resolveConflict(s, choice: choice)
    }

    public func resolveConflict(_ s: EditSession, choice: EditConflictChoice) async {
        switch choice {
        case .replaceServerVersion:
            upload(s, force: true)
        case .uploadAsCopy:
            do {
                try await withConnection(s.endpoint) { conn in
                    let parent = RemotePath.parent(s.remotePath)
                    let names = Set(try await conn.list(parent).map(\.name))
                    let copy = TransferNaming.duplicateName(s.name, isDirectory: false, existing: names)
                    try await Self.safeUpload(conn, local: s.localURL, to: RemotePath.join(parent, copy), capabilities: s.endpoint.capabilities)
                }
                try await download(s)
            } catch {
                s.status = .failed(Self.describe(error))
            }
        case .discardMyChanges:
            do { try await download(s) } catch { s.status = .downloadFailed(Self.describe(error)) }
        case .decideLater:
            s.status = .conflict
        }
    }

    // MARK: Housekeeping

    public func stopWatching(_ s: EditSession) {
        s.task?.cancel()
        sessions.removeAll { $0.id == s.id }
        if !s.hasUnsavedChanges { try? FileManager.default.removeItem(at: s.localURL) }
        stopTimersIfIdle()
    }

    /// Removes sessions whose local copy has no changes, and their files.
    public func cleanUpUnchanged() {
        for s in sessions where s.status == .inSync && !s.hasUnsavedChanges {
            stopWatching(s)
        }
    }

    private func stopTimersIfIdle() {
        guard sessions.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        monitor?.cancel()
        monitor = nil
    }

    private func withConnection<T>(_ endpoint: RemoteEndpoint, _ body: (RemoteFileSystem) async throws -> T) async throws -> T {
        let conn = try await pool.acquire(endpoint.id)
        do {
            let r = try await body(conn)
            await pool.release(endpoint.id, conn)
            return r
        } catch {
            await pool.release(endpoint.id, conn, reusable: !((error as? RemoteError)?.isConnectivity ?? true))
            throw error
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
