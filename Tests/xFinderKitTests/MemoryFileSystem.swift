import Foundation
@testable import xFinderKit

/// In-memory RemoteFileSystem for engine tests.
final class MemoryFileSystem: RemoteFileSystem, @unchecked Sendable {
    struct Node {
        var isDirectory: Bool
        var data = Data()
        var mtime = Date(timeIntervalSince1970: 1_700_000_000)
        var mode: UInt32 = 0o644
    }

    let capabilities: RemoteCapabilities
    let homeDirectory = "/"
    private let lock = NSLock()
    private var nodes: [String: Node] = ["/": Node(isDirectory: true, mode: 0o755)]
    var connected = false
    var isConnected: Bool { connected }
    var connectCount = Locked(0)
    var copyCount = Locked(0)
    /// Artificial delay per upload/download chunk.
    var chunkDelay: UInt64 = 0

    init(capabilities: RemoteCapabilities = .sftp) { self.capabilities = capabilities }

    func connect() async throws { connected = true; connectCount.withLock { $0 += 1 } }
    func disconnect() async { connected = false }

    func sync<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    func put(_ path: String, _ data: Data, mtime: Date? = nil) {
        sync {
            var n = Node(isDirectory: false, data: data)
            if let mtime { n.mtime = mtime }
            nodes[RemotePath.normalize(path)] = n
        }
    }
    func mkdir(_ path: String) { sync { nodes[RemotePath.normalize(path)] = Node(isDirectory: true, mode: 0o755) } }
    func data(_ path: String) -> Data? { sync { nodes[RemotePath.normalize(path)]?.data } }
    func node(_ path: String) -> Node? { sync { nodes[RemotePath.normalize(path)] } }
    var allPaths: [String] { sync { nodes.keys.sorted() } }

    private func item(_ path: String, _ n: Node) -> RemoteItem {
        RemoteItem(name: RemotePath.lastComponent(path), path: path, type: n.isDirectory ? .directory : .file,
                   size: n.isDirectory ? nil : UInt64(n.data.count), modificationDate: n.mtime, permissions: n.mode)
    }

    func list(_ path: String) async throws -> [RemoteItem] {
        let p = RemotePath.normalize(path)
        return try sync {
            guard nodes[p]?.isDirectory == true else { throw RemoteError.notFound(p) }
            return nodes.filter { $0.key != p && RemotePath.parent($0.key) == p }.map { item($0.key, $0.value) }
        }
    }

    func stat(_ path: String) async throws -> RemoteItem {
        let p = RemotePath.normalize(path)
        return try sync {
            guard let n = nodes[p] else { throw RemoteError.notFound(p) }
            return item(p, n)
        }
    }

    func symlinkTarget(_ path: String) async throws -> String { throw RemoteError.unsupported("symlink") }

    func rename(_ from: String, to: String) async throws {
        let f = RemotePath.normalize(from), t = RemotePath.normalize(to)
        try sync {
            guard nodes[f] != nil else { throw RemoteError.notFound(f) }
            guard nodes[t] == nil else { throw RemoteError.alreadyExists(t) }
            for (k, v) in nodes where k == f || RemotePath.isSameOrDescendant(k, of: f) {
                nodes.removeValue(forKey: k)
                nodes[t + k.dropFirst(f.count)] = v
            }
        }
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        let p = RemotePath.normalize(path)
        try sync {
            guard nodes[p] != nil else { throw RemoteError.notFound(p) }
            for k in nodes.keys where k == p || RemotePath.isSameOrDescendant(k, of: p) { nodes.removeValue(forKey: k) }
        }
    }

    func createDirectory(_ path: String) async throws {
        let p = RemotePath.normalize(path)
        try sync {
            guard nodes[RemotePath.parent(p)]?.isDirectory == true else { throw RemoteError.parentMissing(p) }
            guard nodes[p] == nil else { throw RemoteError.alreadyExists(p) }
            nodes[p] = Node(isDirectory: true, mode: 0o755)
        }
    }

    func setPermissions(_ path: String, mode: UInt32) async throws {
        try sync {
            guard nodes[RemotePath.normalize(path)] != nil else { throw RemoteError.notFound(path) }
            nodes[RemotePath.normalize(path)]!.mode = mode
        }
    }

    func setModificationDate(_ path: String, date: Date) async throws {
        try sync {
            guard nodes[RemotePath.normalize(path)] != nil else { throw RemoteError.notFound(path) }
            nodes[RemotePath.normalize(path)]!.mtime = date
        }
    }

    func copyItem(_ from: String, to: String) async throws {
        guard capabilities.contains(.serverCopy) else { throw RemoteError.unsupported("copy") }
        copyCount.withLock { $0 += 1 }
        let f = RemotePath.normalize(from), t = RemotePath.normalize(to)
        try sync {
            guard nodes[f] != nil else { throw RemoteError.notFound(f) }
            for (k, v) in nodes where k == f || RemotePath.isSameOrDescendant(k, of: f) {
                nodes[t + k.dropFirst(f.count)] = v
            }
        }
    }

    func download(_ remotePath: String, to localURL: URL, offset: UInt64, progress: @escaping TransferProgressHandler) async throws {
        guard let d = data(remotePath) else { throw RemoteError.notFound(remotePath) }
        var out = offset > 0 ? ((try? Data(contentsOf: localURL)) ?? Data()).prefix(Int(offset)) : Data()
        var pos = Int(offset)
        while pos < d.count {
            try Task.checkCancellation()
            if chunkDelay > 0 { try await Task.sleep(nanoseconds: chunkDelay) }
            let end = min(d.count, pos + 4096)
            out.append(d[pos..<end])
            pos = end
            progress(UInt64(pos))
        }
        try out.write(to: localURL)
    }

    func upload(_ localURL: URL, to remotePath: String, offset: UInt64, progress: @escaping TransferProgressHandler) async throws {
        let d = try Data(contentsOf: localURL)
        let p = RemotePath.normalize(remotePath)
        var existing = offset > 0 ? (self.data(p) ?? Data()).prefix(Int(offset)) : Data()
        var pos = Int(offset)
        while pos < d.count {
            try Task.checkCancellation()
            if chunkDelay > 0 { try await Task.sleep(nanoseconds: chunkDelay) }
            let end = min(d.count, pos + 4096)
            existing.append(d[pos..<end])
            pos = end
            sync { nodes[p] = Node(isDirectory: false, data: existing) }
            progress(UInt64(pos))
        }
        if d.isEmpty || pos == Int(offset) { let e = existing; sync { nodes[p] = Node(isDirectory: false, data: e) } }
    }

    func makeTransferConnection() async throws -> RemoteFileSystem { self }
}
