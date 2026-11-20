import Foundation

/// Kind of a remote directory entry.
public enum RemoteItemType: String, Codable, Sendable, Hashable {
    case file
    case directory
    case symlink
    case other
}

/// A single entry returned by `RemoteFileSystem.list` / `stat`.
public struct RemoteItem: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var type: RemoteItemType
    public var size: UInt64?
    public var modificationDate: Date?
    /// POSIX permission bits (`mode & 0o7777`), when known.
    public var permissions: UInt32?
    public var owner: String?
    public var group: String?
    /// For symlinks: the target as reported by the protocol (absolute for SFTP,
    /// LIST text for FTP, nil when unknown).
    public var symlinkTarget: String?
    /// For symlinks: whether the target is a directory, when known.
    public var symlinkTargetIsDirectory: Bool?

    public init(name: String, path: String, type: RemoteItemType, size: UInt64? = nil,
                modificationDate: Date? = nil, permissions: UInt32? = nil,
                owner: String? = nil, group: String? = nil,
                symlinkTarget: String? = nil, symlinkTargetIsDirectory: Bool? = nil) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.symlinkTarget = symlinkTarget
        self.symlinkTargetIsDirectory = symlinkTargetIsDirectory
    }

    public var isDirectory: Bool { type == .directory }
    /// True for directories and for symlinks known to point at directories.
    public var isDirectoryLike: Bool {
        type == .directory || (type == .symlink && symlinkTargetIsDirectory == true)
    }
    public var isHidden: Bool { name.hasPrefix(".") }

    /// `rwxr-xr-x` style string (without the type character).
    public var symbolicPermissions: String? {
        permissions.map { PermissionFormatter.symbolic($0) }
    }
}

public enum PermissionFormatter {
    public static func symbolic(_ mode: UInt32) -> String {
        let chars: [Character] = ["r", "w", "x"]
        var out = ""
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (mode >> UInt32(shift)) & 0o7
            for (i, c) in chars.enumerated() {
                out.append(bits & (0o4 >> UInt32(i)) != 0 ? c : "-")
            }
        }
        var arr = Array(out)
        if mode & 0o4000 != 0 { arr[2] = arr[2] == "x" ? "s" : "S" }
        if mode & 0o2000 != 0 { arr[5] = arr[5] == "x" ? "s" : "S" }
        if mode & 0o1000 != 0 { arr[8] = arr[8] == "x" ? "t" : "T" }
        return String(arr)
    }

    public static func octal(_ mode: UInt32) -> String {
        String(format: "%04o", mode & 0o7777)
    }
}

/// Features a protocol implementation supports. The UI uses these to enable
/// commands or pick fallbacks.
public struct RemoteCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shell        = RemoteCapabilities(rawValue: 1 << 0)
    public static let rename       = RemoteCapabilities(rawValue: 1 << 1)
    public static let delete       = RemoteCapabilities(rawValue: 1 << 2)
    public static let mkdir        = RemoteCapabilities(rawValue: 1 << 3)
    public static let chmod        = RemoteCapabilities(rawValue: 1 << 4)
    public static let resume       = RemoteCapabilities(rawValue: 1 << 5)
    public static let serverCopy   = RemoteCapabilities(rawValue: 1 << 6)
    public static let atomicUpload = RemoteCapabilities(rawValue: 1 << 7)
    /// Downloads can continue from an offset (HTTP Range) even without full resume.
    public static let rangeDownload = RemoteCapabilities(rawValue: 1 << 8)

    public static let sftp: RemoteCapabilities = [.shell, .rename, .delete, .mkdir, .chmod, .resume, .serverCopy]
    /// SCP (shell): no resume, no atomic upload.
    public static let scp: RemoteCapabilities = [.shell, .rename, .delete, .mkdir, .chmod, .serverCopy]
    public static let ftp: RemoteCapabilities = [.rename, .delete, .mkdir, .chmod, .resume]
    public static let webDAV: RemoteCapabilities = [.rename, .delete, .mkdir, .serverCopy, .rangeDownload]
    public static let s3: RemoteCapabilities = [.rename, .delete, .mkdir, .serverCopy, .atomicUpload, .rangeDownload]

    public var canResumeDownload: Bool { contains(.resume) || contains(.rangeDownload) }
    public var canResumeUpload: Bool { contains(.resume) }
}

/// Errors surfaced by protocol implementations, normalized across protocols.
public enum RemoteError: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case connectionFailed(String)
    case timeout
    case authenticationFailed(String)
    case cancelledByUser
    case hostKeyRejected
    case notFound(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case parentMissing(String)
    case locked(String)
    case insufficientStorage
    case unsupported(String)
    case invalidResponse(String)
    case clockSkew
    case protocolError(String)
    case localIO(String)
    /// SSH login worked, but the server refused the "sftp" subsystem.
    case sftpUnavailable

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .timeout: return "The operation timed out."
        case .authenticationFailed(let m): return m.isEmpty ? "Authentication failed." : "Authentication failed: \(m)"
        case .cancelledByUser: return "Cancelled."
        case .hostKeyRejected: return "The server's identity was not accepted."
        case .notFound(let p): return "No such file or folder: \(p)"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .alreadyExists(let p): return "An item with this name already exists: \(p)"
        case .parentMissing(let p): return "The parent folder does not exist: \(p)"
        case .locked(let p): return "The item is locked: \(p)"
        case .insufficientStorage: return "The server has insufficient storage."
        case .unsupported(let m): return "Not supported: \(m)"
        case .invalidResponse(let m): return "Invalid server response: \(m)"
        case .clockSkew: return "The request was rejected because this Mac's clock differs too much from the server's time. Check the date and time settings."
        case .protocolError(let m): return m
        case .localIO(let m): return "Local file error: \(m)"
        case .sftpUnavailable:
            return "Signed in, but the server does not offer SFTP (its \"sftp\" subsystem request was refused). "
                + "Switch this server to SCP (shell), or enable SFTP on the server, for example add "
                + "\"Subsystem sftp internal-sftp\" to sshd_config or turn on the SFTP option of the "
                + "SSH add-on or appliance you use."
        }
    }

    /// Errors that a retry is unlikely to fix (used by edit sync / transfers).
    public var isPermanent: Bool {
        switch self {
        case .authenticationFailed, .permissionDenied, .notFound, .parentMissing, .hostKeyRejected, .cancelledByUser, .unsupported,
             .sftpUnavailable:
            return true
        default:
            return false
        }
    }

    /// Errors that indicate the server could not be reached.
    public var isConnectivity: Bool {
        switch self {
        case .notConnected, .connectionFailed, .timeout: return true
        default: return false
        }
    }
}

/// Progress callback: total bytes transferred so far (including the start offset).
public typealias TransferProgressHandler = @Sendable (UInt64) -> Void

/// Unified interface over SFTP, FTP/FTPS, WebDAV and S3.
public protocol RemoteFileSystem: AnyObject, Sendable {
    var capabilities: RemoteCapabilities { get }
    /// The home / initial directory reported after connecting.
    var homeDirectory: String { get }
    var isConnected: Bool { get }

    func connect() async throws
    func disconnect() async

    func list(_ path: String) async throws -> [RemoteItem]
    func stat(_ path: String) async throws -> RemoteItem
    func symlinkTarget(_ path: String) async throws -> String
    func rename(_ from: String, to: String) async throws
    /// Deletes a file, or a directory recursively.
    func delete(_ path: String, isDirectory: Bool) async throws
    func createDirectory(_ path: String) async throws
    func setPermissions(_ path: String, mode: UInt32) async throws
    func setModificationDate(_ path: String, date: Date) async throws
    /// Server-side copy. Throws `RemoteError.unsupported` when not possible.
    func copyItem(_ from: String, to: String) async throws

    /// Downloads `remotePath` into `localURL`. When `offset > 0` the local file is
    /// appended to (resume); otherwise it is truncated.
    func download(_ remotePath: String, to localURL: URL, offset: UInt64,
                  progress: @escaping TransferProgressHandler) async throws
    /// Uploads `localURL` to `remotePath`. `offset > 0` continues an earlier upload.
    func upload(_ localURL: URL, to remotePath: String, offset: UInt64,
                progress: @escaping TransferProgressHandler) async throws

    /// Opens a new, independent connection reusing the credentials that already
    /// succeeded on this one (for the transfer queue).
    func makeTransferConnection() async throws -> RemoteFileSystem
}

public extension RemoteFileSystem {
    func exists(_ path: String) async -> RemoteItem? {
        try? await stat(path)
    }
}

/// POSIX-style path helpers for remote paths.
public enum RemotePath {
    public static func join(_ base: String, _ name: String) -> String {
        if name.hasPrefix("/") { return normalize(name) }
        if base.isEmpty { return normalize(name) }
        return normalize(base.hasSuffix("/") ? base + name : base + "/" + name)
    }

    public static func parent(_ path: String) -> String {
        let n = normalize(path)
        if n == "/" { return "/" }
        guard let idx = n.lastIndex(of: "/") else { return "." }
        let p = String(n[..<idx])
        return p.isEmpty ? "/" : p
    }

    public static func lastComponent(_ path: String) -> String {
        let n = normalize(path)
        if n == "/" { return "/" }
        return n.split(separator: "/").last.map(String.init) ?? n
    }

    /// Collapses duplicate slashes, `.` and `..` components. Keeps relative paths relative.
    public static func normalize(_ path: String) -> String {
        if path.isEmpty { return path }
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                if let last = parts.last, last != ".." { parts.removeLast(); continue }
                if absolute { continue }
            }
            parts.append(comp)
        }
        let joined = parts.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// Breadcrumb components: ["/", "/a", "/a/b"].
    public static func ancestors(_ path: String) -> [String] {
        let n = normalize(path)
        guard n.hasPrefix("/") else { return [n] }
        var result = ["/"]
        var current = ""
        for comp in n.split(separator: "/") {
            current += "/" + comp
            result.append(current)
        }
        return result
    }

    /// True when `path` equals `ancestor` or lies inside it.
    public static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        let p = normalize(path), a = normalize(ancestor)
        if p == a { return true }
        let prefix = a.hasSuffix("/") ? a : a + "/"
        return p.hasPrefix(prefix)
    }

    /// Validates a single file name for rename / new folder.
    public static func validateName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "The name cannot be empty." }
        if name == "." || name == ".." { return "\"\(name)\" is not a valid name." }
        if name.contains("/") { return "Names cannot contain \"/\"." }
        if name.contains("\0") { return "Names cannot contain NUL characters." }
        if name.utf8.count > 255 { return "The name is too long." }
        return nil
    }
}
