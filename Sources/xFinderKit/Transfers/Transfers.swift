import Foundation
import Combine

/// A remote server as seen by the transfer engine. `id` keys the connection pool.
public struct RemoteEndpoint: Hashable, Sendable {
    public var id: String
    public var label: String
    public var capabilities: RemoteCapabilities

    public init(id: String, label: String, capabilities: RemoteCapabilities) {
        self.id = id
        self.label = label
        self.capabilities = capabilities
    }
}

/// One side of a transfer.
public enum TransferLocation: Hashable, Sendable {
    case local(URL)
    case remote(RemoteEndpoint, String)

    public var path: String {
        switch self {
        case .local(let u): return u.path
        case .remote(_, let p): return p
        }
    }

    public var name: String {
        switch self {
        case .local(let u): return u.lastPathComponent
        case .remote(_, let p): return RemotePath.lastComponent(p)
        }
    }

    public var displayPath: String {
        switch self {
        case .local(let u): return (u.path as NSString).abbreviatingWithTildeInPath
        case .remote(let e, let p): return "\(e.label):\(p)"
        }
    }

    public var endpoint: RemoteEndpoint? {
        if case .remote(let e, _) = self { return e }
        return nil
    }
}

public enum TransferKind: String, Sendable {
    case upload
    case download
    /// Remote to remote via a local staging file.
    case copy
    /// Remote to remote on the same server without moving data.
    case serverCopy
}

public enum TransferState: Equatable, Sendable {
    case queued
    case running
    case paused
    case completed
    case skipped(String)
    case cancelled
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .completed, .skipped, .cancelled, .failed: return true
        default: return false
        }
    }

    public var isPending: Bool { self == .queued || self == .running }

    public var label: String {
        switch self {
        case .queued: return "Waiting"
        case .running: return "Transferring"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .skipped(let why): return why.isEmpty ? "Skipped" : "Skipped: \(why)"
        case .cancelled: return "Cancelled"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

/// Answer to "the destination already exists".
public enum ConflictDecision: String, Sendable, CaseIterable {
    case replace
    case skip
    case keepBoth
    case resume
    /// Cancel the whole batch.
    case stop
}

public struct ConflictAnswer: Sendable, Equatable {
    public var decision: ConflictDecision
    public var applyToAll: Bool
    public init(_ decision: ConflictDecision, applyToAll: Bool = false) {
        self.decision = decision
        self.applyToAll = applyToAll
    }
}

/// Information shown in the conflict dialog.
public struct TransferConflict: Sendable, Identifiable {
    public let id = UUID()
    public var name: String
    public var destination: String
    public var sourceSize: UInt64?
    public var sourceDate: Date?
    public var destinationSize: UInt64?
    public var destinationDate: Date?
    public var canResume: Bool
    /// True for copy/paste (Replace / Keep Both / Skip / Stop).
    public var isCopy: Bool

    public enum Newer: Sendable { case source, destination, same, unknown }
    public var newer: Newer {
        guard let s = sourceDate, let d = destinationDate else { return .unknown }
        if abs(s.timeIntervalSince(d)) <= 1 { return .same }
        return s > d ? .source : .destination
    }
}

/// Metadata about a transfer source captured while scanning.
public struct TransferSourceInfo: Sendable, Hashable {
    public var size: UInt64?
    public var modificationDate: Date?
    public var permissions: UInt32?
    public var isDirectory: Bool
    public init(size: UInt64?, modificationDate: Date?, permissions: UInt32?, isDirectory: Bool = false) {
        self.size = size
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.isDirectory = isDirectory
    }
}

/// A single file (or server-side copy of a folder) in the queue.
@MainActor
public final class TransferItem: ObservableObject, Identifiable {
    public let id = UUID()
    public let batchID: UUID
    public let kind: TransferKind
    public let source: TransferLocation
    public let sourceInfo: TransferSourceInfo
    @Published public internal(set) var destination: TransferLocation
    @Published public internal(set) var state: TransferState = .queued
    @Published public internal(set) var transferredBytes: UInt64 = 0
    @Published public internal(set) var bytesPerSecond: Double = 0
    @Published public internal(set) var finishedAt: Date?

    /// Bytes to move; staged copies move the data twice.
    public var totalBytes: UInt64? {
        guard let s = sourceInfo.size else { return nil }
        return kind == .copy ? s * 2 : s
    }

    public var fractionCompleted: Double? {
        guard let t = totalBytes, t > 0 else { return state == .completed ? 1 : nil }
        return min(1, Double(transferredBytes) / Double(t))
    }

    public var remainingSeconds: Double? {
        guard state == .running, bytesPerSecond > 1, let t = totalBytes, t > transferredBytes else { return nil }
        return Double(t - transferredBytes) / bytesPerSecond
    }

    public var name: String { destination.name }

    // Engine bookkeeping
    let progressBox = Locked<UInt64>(0)
    var lastSample: UInt64 = 0
    var task: Task<Void, Never>?
    /// Temporary path written while transferring (remote or local).
    var temporaryPath: String?
    var stagingURL: URL?
    /// When set, the conflict question was already answered for this item.
    var resolvedDecision: ConflictDecision?
    /// Set while pausing/cancelling so the running task knows why it stopped.
    var stopReason: TransferState?

    init(batchID: UUID, kind: TransferKind, source: TransferLocation, destination: TransferLocation,
         sourceInfo: TransferSourceInfo) {
        self.batchID = batchID
        self.kind = kind
        self.source = source
        self.destination = destination
        self.sourceInfo = sourceInfo
    }
}

/// One user action (upload, download, copy). Expands into items after scanning.
@MainActor
public final class TransferBatch: ObservableObject, Identifiable {
    public let id = UUID()
    public let title: String
    public let createdAt = Date()
    public let isCopy: Bool
    @Published public internal(set) var items: [TransferItem] = []
    @Published public internal(set) var isScanning = true
    @Published public internal(set) var scanError: String?
    @Published public internal(set) var isCancelled = false
    /// "Apply to all" answer for later conflicts.
    var applyToAll: ConflictDecision?
    var stagingDirectory: URL?
    var scanTask: Task<Void, Never>?

    init(title: String, isCopy: Bool) {
        self.title = title
        self.isCopy = isCopy
    }

    public var isFinished: Bool { !isScanning && items.allSatisfy { $0.state.isFinished } }
}

/// What to transfer.
public enum TransferRequest: Sendable {
    case upload([URL], to: RemoteEndpoint, directory: String)
    case download([RemoteItem], from: RemoteEndpoint, to: URL)
    /// Paste / cross-server drop. `duplicate` names copies "name copy.ext".
    case copy([RemoteItem], from: RemoteEndpoint, to: RemoteEndpoint, directory: String, duplicate: Bool)
}

public enum TransferRequestError: Error, LocalizedError, Equatable {
    case copyIntoItself(String)
    case nothingToTransfer

    public var errorDescription: String? {
        switch self {
        case .copyIntoItself(let n): return "“\(n)” cannot be copied into itself or one of its own folders."
        case .nothingToTransfer: return "Nothing to transfer."
        }
    }
}

/// Name helpers for Keep Both and Duplicate.
public enum TransferNaming {
    static func split(_ name: String, isDirectory: Bool) -> (String, String) {
        if isDirectory { return (name, "") }
        // ".bashrc" has no extension; ".config.json" has "json".
        let body = name.hasPrefix(".") ? String(name.dropFirst()) : name
        guard let dot = body.lastIndex(of: "."), dot != body.startIndex, body.index(after: dot) != body.endIndex else {
            return (name, "")
        }
        let prefix = name.hasPrefix(".") ? "." : ""
        return (prefix + String(body[..<dot]), String(body[dot...]))
    }

    /// "name 2.ext", "name 3.ext", … (Keep Both).
    public static func keepBothName(_ name: String, isDirectory: Bool, existing: Set<String>) -> String {
        let (base, ext) = split(name, isDirectory: isDirectory)
        var n = 2
        while true {
            let candidate = "\(base) \(n)\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// "name copy.ext", "name copy 2.ext", … (Duplicate).
    public static func duplicateName(_ name: String, isDirectory: Bool, existing: Set<String>) -> String {
        let (base, ext) = split(name, isDirectory: isDirectory)
        let first = "\(base) copy\(ext)"
        if !existing.contains(first) { return first }
        var n = 2
        while true {
            let candidate = "\(base) copy \(n)\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    public static func remoteTemporaryName(_ name: String) -> String { ".\(name).rfpart" }
    public static func localTemporaryName(_ name: String) -> String { "\(name).rfdownload" }
}

/// Formats byte counts and durations for the queue UI.
public enum TransferFormat {
    public static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }
    public static func speed(_ bps: Double) -> String { bytes(UInt64(max(0, bps))) + "/s" }
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }
}
