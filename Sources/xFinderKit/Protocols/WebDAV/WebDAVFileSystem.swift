import Foundation

/// WebDAV over HTTP(S): PROPFIND, MOVE, COPY, DELETE, MKCOL, GET (Range) and PUT.
public final class WebDAVFileSystem: RemoteFileSystem, @unchecked Sendable {
    public let config: ConnectionConfig
    let environment: ConnectionEnvironment
    private let transport: HTTPTransport
    private let password = Locked<String?>(nil)
    private let connected = Locked(false)

    public init(config: ConnectionConfig, environment: ConnectionEnvironment, cachedPassword: String? = nil) {
        self.config = config
        self.environment = environment
        transport = HTTPTransport(trust: environment.tlsTrust, host: config.host, port: config.port)
        password.value = cachedPassword
    }

    deinit { transport.invalidate() }

    public var capabilities: RemoteCapabilities { .webDAV }
    public var homeDirectory: String { "/" }
    public var isConnected: Bool { connected.value }

    var isSecure: Bool { config.site.protocolType == .webdavs }

    var basePath: String {
        var b = config.site.webDAVBasePath.trimmingCharacters(in: .whitespaces)
        if b.isEmpty { b = "/" }
        if !b.hasPrefix("/") { b = "/" + b }
        return RemotePath.normalize(b)
    }

    /// Absolute URL for an xFinder path.
    func url(_ path: String, directory: Bool = false) -> URL {
        var c = URLComponents()
        c.scheme = isSecure ? "https" : "http"
        c.host = config.host.hasPrefix("[") ? String(config.host.dropFirst().dropLast()) : config.host
        if config.port != (isSecure ? 443 : 80) { c.port = config.port }
        var full = RemotePath.join(basePath, RemotePath.normalize(path).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        if full.isEmpty { full = "/" }
        if directory && !full.hasSuffix("/") { full += "/" }
        c.percentEncodedPath = URLEncoding.path(full)
        return c.url!
    }

    func request(_ method: String, _ path: String, directory: Bool = false) -> URLRequest {
        var r = URLRequest(url: url(path, directory: directory))
        r.httpMethod = method
        r.timeoutInterval = HTTPTransport.timeout
        return r
    }

    // MARK: Connection

    public func connect() async throws {
        let user = config.username
        let check: () async throws -> Void = {
            var r = self.request("PROPFIND", "/", directory: true)
            r.setValue("0", forHTTPHeaderField: "Depth")
            r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(WebDAVParsing.propfindBody.utf8)
            let (_, resp) = try await self.transport.data(r)
            if resp.statusCode == 404 {
                throw RemoteError.notFound("Base path \(self.basePath) does not exist on the server.")
            }
            if resp.statusCode == 405 || resp.statusCode == 501 {
                throw RemoteError.unsupported("The server does not support WebDAV at \(self.basePath).")
            }
            if let e = WebDAVParsing.error(status: resp.statusCode, path: self.basePath) { throw e }
        }
        if user.isEmpty {
            transport.credential.value = nil
            try await check()
        } else {
            let (_, secret) = try await PasswordLogin.run(config: config, environment: environment, cached: password.value) { pw in
                self.transport.credential.value = URLCredential(user: user, password: pw, persistence: .forSession)
                try await check()
            }
            password.value = secret
        }
        connected.value = true
    }

    public func disconnect() async {
        connected.value = false
    }

    public func makeTransferConnection() async throws -> RemoteFileSystem {
        let fs = WebDAVFileSystem(config: config, environment: environment, cachedPassword: password.value)
        try await fs.connect()
        return fs
    }

    private func checked(_ r: URLRequest, path: String) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await transport.data(r)
        if let e = WebDAVParsing.error(status: resp.statusCode, path: path) { throw e }
        return (data, resp)
    }

    // MARK: Listing

    private func propfind(_ path: String, depth: String, directory: Bool) async throws -> [WebDAVEntry] {
        var r = request("PROPFIND", path, directory: directory)
        r.setValue(depth, forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(WebDAVParsing.propfindBody.utf8)
        let (data, resp) = try await checked(r, path: path)
        guard resp.statusCode == 207 else {
            throw RemoteError.invalidResponse("Expected a multistatus response, got HTTP \(resp.statusCode).")
        }
        return try WebDAVParsing.parseMultistatus(data)
    }

    private func item(_ e: WebDAVEntry) -> RemoteItem? {
        guard let rel = WebDAVParsing.relativePath(WebDAVParsing.hrefPath(e.href), basePath: basePath) else { return nil }
        return RemoteItem(name: RemotePath.lastComponent(rel), path: rel, type: e.isCollection ? .directory : .file,
                          size: e.isCollection ? nil : e.size, modificationDate: e.modificationDate)
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let dir = RemotePath.normalize(path)
        let entries = try await propfind(dir, depth: "1", directory: true)
        return entries.compactMap(item).filter { $0.path != dir && RemotePath.parent($0.path) == dir }
    }

    public func stat(_ path: String) async throws -> RemoteItem {
        let p = RemotePath.normalize(path)
        if p == "/" { return RemoteItem(name: "/", path: "/", type: .directory) }
        let entries = try await propfind(p, depth: "0", directory: false)
        guard let e = entries.first(where: { (200..<300).contains($0.status) }), var it = item(e) else {
            throw RemoteError.notFound(p)
        }
        it.path = p
        it.name = RemotePath.lastComponent(p)
        return it
    }

    public func symlinkTarget(_ path: String) async throws -> String { throw RemoteError.unsupported("WebDAV has no symbolic links.") }

    // MARK: Operations

    public func rename(_ from: String, to: String) async throws {
        let isDir = (try? await stat(from))?.isDirectory ?? false
        var r = request("MOVE", from, directory: isDir)
        r.setValue(url(to, directory: isDir).absoluteString, forHTTPHeaderField: "Destination")
        r.setValue("F", forHTTPHeaderField: "Overwrite")
        _ = try await checked(r, path: to)
    }

    public func delete(_ path: String, isDirectory: Bool) async throws {
        let r = request("DELETE", path, directory: isDirectory)
        _ = try await checked(r, path: path)
    }

    public func createDirectory(_ path: String) async throws {
        let r = request("MKCOL", path, directory: true)
        _ = try await checked(r, path: path)
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        throw RemoteError.unsupported("WebDAV does not support changing permissions.")
    }

    /// The server sets modification times; nothing to do.
    public func setModificationDate(_ path: String, date: Date) async throws {}

    public func copyItem(_ from: String, to: String) async throws {
        let isDir = (try? await stat(from))?.isDirectory ?? false
        var r = request("COPY", from, directory: isDir)
        r.setValue(url(to, directory: isDir).absoluteString, forHTTPHeaderField: "Destination")
        r.setValue("infinity", forHTTPHeaderField: "Depth")
        r.setValue("F", forHTTPHeaderField: "Overwrite")
        _ = try await checked(r, path: to)
    }

    // MARK: Transfers

    public func download(_ remotePath: String, to localURL: URL, offset: UInt64,
                         progress: @escaping TransferProgressHandler) async throws {
        var r = request("GET", remotePath)
        if offset > 0 { r.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (resp, body) = try await transport.stream(r, progress: progress) { resp in
            try Self.openForDownload(resp, localURL: localURL, offset: offset)
        }
        if offset > 0 && resp.statusCode == 416 { progress(offset); return }  // already complete
        if let e = WebDAVParsing.error(status: resp.statusCode, path: remotePath) {
            _ = body
            throw e
        }
    }

    /// 206 appends, 200 replaces; other statuses are buffered for the error.
    static func openForDownload(_ resp: HTTPURLResponse, localURL: URL, offset: UInt64) throws -> (FileHandle, UInt64)? {
        let fm = FileManager.default
        switch resp.statusCode {
        case 206 where offset > 0:
            if !fm.fileExists(atPath: localURL.path) { fm.createFile(atPath: localURL.path, contents: nil) }
            let h = try FileHandle(forWritingTo: localURL)
            try h.truncate(atOffset: offset)
            try h.seek(toOffset: offset)
            return (h, offset)
        case 200, 206:
            guard fm.createFile(atPath: localURL.path, contents: nil) else { throw RemoteError.localIO("Cannot create \(localURL.path)") }
            return (try FileHandle(forWritingTo: localURL), 0)
        default:
            return nil
        }
    }

    public func upload(_ localURL: URL, to remotePath: String, offset: UInt64,
                       progress: @escaping TransferProgressHandler) async throws {
        // WebDAV cannot continue uploads; always send the whole file.
        var r = request("PUT", remotePath)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await transport.upload(r, fromFile: localURL, progress: progress)
        if let e = WebDAVParsing.error(status: resp.statusCode, path: remotePath) { throw e }
    }
}
