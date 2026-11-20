import Foundation

/// FTP and FTPS (explicit AUTH TLS or implicit TLS).
public final class FTPFileSystem: RemoteFileSystem, @unchecked Sendable {
    public static let uploadChunkSize = 256 * 1024

    public let config: ConnectionConfig
    let environment: ConnectionEnvironment
    private let connection = Locked<FTPConnection?>(nil)
    private let password = Locked<String?>(nil)
    private let homePath = Locked("/")
    private let mutex = AsyncMutex()

    public init(config: ConnectionConfig, environment: ConnectionEnvironment, cachedPassword: String? = nil) {
        self.config = config
        self.environment = environment
        password.value = cachedPassword
    }

    public var capabilities: RemoteCapabilities { .ftp }
    public var homeDirectory: String { homePath.value }
    public var isConnected: Bool { connection.value?.isOpen ?? false }

    var security: FTPSecurity {
        switch config.site.protocolType {
        case .ftpsExplicit: return .explicit
        case .ftpsImplicit: return .implicit
        default: return .none
        }
    }

    private func makeConnection(_ pw: String) -> FTPConnection {
        FTPConnection(host: config.host, port: config.port, security: security, trust: environment.tlsTrust,
                      username: config.username, password: pw)
    }

    public func connect() async throws {
        try await mutex.run {
            let c: FTPConnection
            if config.username.isEmpty {
                c = makeConnection("")
                try await c.open()
            } else {
                let (conn, pw) = try await PasswordLogin.run(config: config, environment: environment, cached: password.value) { pw in
                    let c = self.makeConnection(pw)
                    try await c.open()
                    return c
                }
                password.value = pw
                c = conn
            }
            connection.value = c
            homePath.value = c.home
        }
    }

    public func disconnect() async {
        let c = connection.value
        connection.value = nil
        await c?.quit()
    }

    public func makeTransferConnection() async throws -> RemoteFileSystem {
        let fs = FTPFileSystem(config: config, environment: environment, cachedPassword: password.value ?? "")
        try await fs.connect()
        return fs
    }

    /// Serializes control commands; reconnects and retries once after a lost
    /// connection or timeout (not for transfers).
    private func perform<T>(retry: Bool = true, _ body: (FTPConnection) async throws -> T) async throws -> T {
        try await mutex.run {
            func current() async throws -> FTPConnection {
                if let c = connection.value, c.isOpen { return c }
                let c = makeConnection(password.value ?? "")
                try await c.open()
                connection.value = c
                return c
            }
            do {
                return try await body(try await current())
            } catch let e as RemoteError where retry && e.isConnectivity {
                connection.value?.close()
                connection.value = nil
                return try await body(try await current())
            } catch is CancellationError {
                connection.value?.close()
                throw CancellationError()
            }
        }
    }

    private func expect(_ c: FTPConnection, _ cmd: String, path: String, codes: Set<Int>? = nil) async throws -> FTPReply {
        let r = try await c.command(cmd)
        if let codes { guard codes.contains(r.code) else { throw FTPParsing.error(r, path: path) } }
        else if !r.isSuccess { throw FTPParsing.error(r, path: path) }
        return r
    }

    private static func readAll(_ data: FTPStream) async throws -> Data {
        var out = Data()
        while let chunk = try await data.read(maxLength: 65536) {
            out.append(chunk)
            try Task.checkCancellation()
        }
        return out
    }

    private static func lines(_ d: Data) -> [String] {
        let s = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        return s.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
    }

    // MARK: Listing

    private func rawList(_ c: FTPConnection, _ dir: String, forceLIST: Bool = false) async throws -> [RemoteItem] {
        if c.supportsMLSD && !forceLIST {
            var data = Data()
            do {
                try await c.transfer("MLSD \(dir)", path: dir) { data = try await Self.readAll($0) }
                return Self.lines(data).compactMap { FTPParsing.mlsdEntry($0, directory: dir) }
            } catch RemoteError.unsupported {
                // Fall through to LIST.
            }
        }
        _ = try await expect(c, "CWD \(dir)", path: dir)
        var data = Data()
        do {
            try await c.transfer("LIST -a", path: dir) { data = try await Self.readAll($0) }
        } catch RemoteError.unsupported {
            try await c.transfer("LIST", path: dir) { data = try await Self.readAll($0) }
        }
        return Self.lines(data).compactMap { FTPParsing.listEntry($0, directory: dir) }
    }

    /// Determines whether symlinks point at folders by trying to change into them.
    private func resolveLinks(_ c: FTPConnection, _ items: [RemoteItem]) async throws -> [RemoteItem] {
        var out = items
        for i in out.indices where out[i].type == .symlink {
            let r = try await c.command("CWD \(out[i].path)")
            out[i].symlinkTargetIsDirectory = r.isSuccess
        }
        return out
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let dir = RemotePath.normalize(path)
        return try await perform { c in
            try await resolveLinks(c, try await rawList(c, dir))
        }
    }

    public func stat(_ path: String) async throws -> RemoteItem {
        let p = RemotePath.normalize(path)
        if p == "/" { return RemoteItem(name: "/", path: "/", type: .directory) }
        return try await perform { c in
            if c.supportsMLSD {
                let r = try await c.command("MLST \(p)")
                if r.isSuccess, let line = r.lines.dropFirst().first(where: { $0.hasPrefix(" ") }),
                   var item = FTPParsing.mlsdEntry(line, directory: RemotePath.parent(p)) {
                    item.path = p
                    item.name = RemotePath.lastComponent(p)
                    return try await resolveLinks(c, [item])[0]
                }
                if r.code == 550 || r.code == 450 { throw FTPParsing.error(r, path: p) }
            }
            let parent = RemotePath.parent(p)
            let items = try await rawList(c, parent)
            guard let item = items.first(where: { $0.name == RemotePath.lastComponent(p) }) else {
                throw RemoteError.notFound(p)
            }
            return try await resolveLinks(c, [item])[0]
        }
    }

    public func symlinkTarget(_ path: String) async throws -> String {
        let p = RemotePath.normalize(path)
        return try await perform { c in
            let items = try await rawList(c, RemotePath.parent(p), forceLIST: true)
            guard let item = items.first(where: { $0.name == RemotePath.lastComponent(p) }) else { throw RemoteError.notFound(p) }
            guard let t = item.symlinkTarget else { throw RemoteError.unsupported("The server does not report link targets.") }
            return t
        }
    }

    // MARK: Operations

    public func rename(_ from: String, to: String) async throws {
        try await perform { c in
            _ = try await expect(c, "RNFR \(from)", path: from, codes: [350])
            _ = try await expect(c, "RNTO \(to)", path: to)
        }
    }

    public func delete(_ path: String, isDirectory: Bool) async throws {
        try await perform { c in try await deleteRecursive(c, RemotePath.normalize(path), isDirectory: isDirectory) }
    }

    private func deleteRecursive(_ c: FTPConnection, _ path: String, isDirectory: Bool) async throws {
        if isDirectory {
            for child in try await rawList(c, path) {
                try Task.checkCancellation()
                try await deleteRecursive(c, child.path, isDirectory: child.type == .directory)
            }
            _ = try await expect(c, "CWD /", path: "/")
            _ = try await expect(c, "RMD \(path)", path: path)
        } else {
            _ = try await expect(c, "DELE \(path)", path: path)
        }
    }

    public func createDirectory(_ path: String) async throws {
        try await perform { c in _ = try await expect(c, "MKD \(path)", path: path) }
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        try await perform { c in
            let r = try await c.command("SITE CHMOD \(String(mode & 0o7777, radix: 8)) \(path)")
            guard r.isSuccess else {
                if [500, 501, 502, 504].contains(r.code) { throw RemoteError.unsupported("The server does not support SITE CHMOD.") }
                throw FTPParsing.error(r, path: path)
            }
        }
    }

    /// Only possible when the server supports MFMT.
    public func setModificationDate(_ path: String, date: Date) async throws {
        try await perform { c in
            guard c.supportsMFMT else { return }
            _ = try await c.command("MFMT \(FTPParsing.formatTimeval(date)) \(path)")
        }
    }

    public func copyItem(_ from: String, to: String) async throws {
        throw RemoteError.unsupported("FTP has no server-side copy.")
    }

    // MARK: Transfers

    public func download(_ remotePath: String, to localURL: URL, offset: UInt64,
                         progress: @escaping TransferProgressHandler) async throws {
        try await perform(retry: false) { c in
            var start = offset
            if start > 0 {
                let r = try await c.command("REST \(start)")
                if r.code != 350 { start = 0 }
            }
            let fm = FileManager.default
            if start == 0 || !fm.fileExists(atPath: localURL.path) {
                guard fm.createFile(atPath: localURL.path, contents: nil) else { throw RemoteError.localIO("Cannot create \(localURL.path)") }
                start = 0
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: localURL)
                try handle.truncate(atOffset: start)
                try handle.seek(toOffset: start)
            } catch { throw RemoteError.localIO(error.localizedDescription) }
            defer { try? handle.close() }
            var position = start
            progress(position)
            try await c.transfer("RETR \(remotePath)", path: remotePath) { data in
                while let chunk = try await data.read(maxLength: 256 * 1024) {
                    try Task.checkCancellation()
                    do { try handle.write(contentsOf: chunk) } catch { throw RemoteError.localIO(error.localizedDescription) }
                    position += UInt64(chunk.count)
                    progress(position)
                }
            }
        }
    }

    public func upload(_ localURL: URL, to remotePath: String, offset: UInt64,
                       progress: @escaping TransferProgressHandler) async throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: localURL) } catch { throw RemoteError.localIO(error.localizedDescription) }
        defer { try? handle.close() }
        try await perform(retry: false) { c in
            var position = offset
            do { try handle.seek(toOffset: offset) } catch { throw RemoteError.localIO(error.localizedDescription) }
            progress(position)
            try await c.transfer(offset > 0 ? "APPE \(remotePath)" : "STOR \(remotePath)", path: remotePath) { data in
                while true {
                    try Task.checkCancellation()
                    let chunk: Data
                    do { chunk = try handle.read(upToCount: Self.uploadChunkSize) ?? Data() } catch { throw RemoteError.localIO(error.localizedDescription) }
                    if chunk.isEmpty { break }
                    try await data.write(chunk)
                    position += UInt64(chunk.count)
                    progress(position)
                }
                await data.finishWriting()
            }
        }
    }
}
