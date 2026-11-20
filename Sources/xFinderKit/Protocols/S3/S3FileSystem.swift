import Foundation

/// Amazon S3 and compatible services (MinIO, Wasabi, R2, Ceph, …).
/// Username = Access Key ID, password = Secret Access Key.
public final class S3FileSystem: RemoteFileSystem, @unchecked Sendable {
    public static let defaultRegion = "us-east-1"
    public static let maxSingleUpload: UInt64 = 5 * 1024 * 1024 * 1024

    public let config: ConnectionConfig
    let environment: ConnectionEnvironment
    private let transport: HTTPTransport
    private let secret = Locked<String?>(nil)
    private let region: Locked<String>
    private let connected = Locked(false)

    public init(config: ConnectionConfig, environment: ConnectionEnvironment, cachedSecret: String? = nil) {
        self.config = config
        self.environment = environment
        let r = config.site.s3Region.trimmingCharacters(in: .whitespaces)
        region = Locked(r.isEmpty ? Self.defaultRegion : r)
        transport = HTTPTransport(trust: environment.tlsTrust, host: config.host.isEmpty ? "s3.amazonaws.com" : config.host,
                                  port: config.port, followRedirects: false)
        secret.value = cachedSecret
    }

    deinit { transport.invalidate() }

    public var capabilities: RemoteCapabilities { .s3 }
    public var homeDirectory: String { "/" }
    public var isConnected: Bool { connected.value }
    public var currentRegion: String { region.value }

    var bucket: String { config.site.s3Bucket.trimmingCharacters(in: .whitespaces) }

    public static func isAWS(host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h.isEmpty || h == "amazonaws.com" || h.hasSuffix(".amazonaws.com")
    }

    var isAWS: Bool { Self.isAWS(host: config.host) }

    /// Builds the URL for an object key ("" = bucket root).
    public static func url(bucket: String, key: String, query: [URLQueryItem], host: String, port: Int?,
                           region: String, plainHTTP: Bool) -> URL {
        var c = URLComponents()
        let aws = isAWS(host: host)
        c.scheme = (!aws && plainHTTP) ? "http" : "https"
        let pathStyle = !aws || bucket.contains(".")
        if aws {
            let base = "s3.\(region).amazonaws.com"
            c.host = pathStyle ? base : "\(bucket).\(base)"
        } else {
            c.host = host
            if let port, port != (c.scheme == "https" ? 443 : 80) { c.port = port }
        }
        let path = pathStyle ? "/\(bucket)/\(key)" : "/\(key)"
        c.percentEncodedPath = URLEncoding.path(path)
        if !query.isEmpty { c.percentEncodedQuery = S3Signer.canonicalQuery(query) }
        return c.url!
    }

    static func key(_ path: String) -> String {
        let n = RemotePath.normalize(path.isEmpty ? "/" : path)
        return n == "/" ? "" : String(n.drop(while: { $0 == "/" }))
    }

    private func signedRequest(_ method: String, key: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
                               secretKey: String) -> URLRequest {
        let url = Self.url(bucket: bucket, key: key, query: query, host: config.host, port: config.site.port,
                           region: region.value, plainHTTP: config.site.s3UsePlainHTTP)
        let signer = S3Signer(accessKey: config.username, secretKey: secretKey, region: region.value)
        let signed = signer.sign(method: method, url: url, query: query, headers: headers)
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = HTTPTransport.timeout
        for (k, v) in signed.headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Sends a request; on a wrong-region answer (301/307/400) switches region and retries once.
    private func send(_ method: String, key: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
                      secretKey: String? = nil,
                      _ exec: (URLRequest) async throws -> (HTTPURLResponse, Data)) async throws -> (HTTPURLResponse, Data) {
        guard let sk = secretKey ?? secret.value else { throw RemoteError.notConnected }
        var (resp, data) = try await exec(signedRequest(method, key: key, query: query, headers: headers, secretKey: sk))
        if [301, 307, 400].contains(resp.statusCode) {
            let hinted = resp.value(forHTTPHeaderField: "x-amz-bucket-region") ?? S3Parsing.parseError(data)?.region
            if let r = hinted, !r.isEmpty, r != region.value {
                region.value = r
                (resp, data) = try await exec(signedRequest(method, key: key, query: query, headers: headers, secretKey: sk))
            }
        }
        return (resp, data)
    }

    private func simple(_ method: String, key: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
                        secretKey: String? = nil, path: String) async throws -> (HTTPURLResponse, Data) {
        let (resp, data) = try await send(method, key: key, query: query, headers: headers, secretKey: secretKey) { req in
            let (d, r) = try await self.transport.data(req)
            return (r, d)
        }
        if let e = S3Parsing.error(status: resp.statusCode, info: S3Parsing.parseError(data), path: path) { throw e }
        return (resp, data)
    }

    // MARK: Connection

    public func connect() async throws {
        guard !config.username.isEmpty else {
            throw RemoteError.authenticationFailed("Enter the Access Key ID as the username.")
        }
        let (_, sk) = try await PasswordLogin.run(config: config, environment: environment, kind: .s3Secret, cached: secret.value) { sk in
            _ = try await self.simple("GET", key: "", query: [URLQueryItem(name: "list-type", value: "2"),
                                                                URLQueryItem(name: "max-keys", value: "1")],
                                      secretKey: sk, path: "/")
        }
        secret.value = sk
        connected.value = true
    }

    public func disconnect() async { connected.value = false }

    public func makeTransferConnection() async throws -> RemoteFileSystem {
        let fs = S3FileSystem(config: config, environment: environment, cachedSecret: secret.value)
        fs.region.value = region.value
        try await fs.connect()
        return fs
    }

    // MARK: Listing

    func listObjects(prefix: String, delimiter: Bool, maxKeys: Int? = nil) async throws -> S3ListResult {
        var all = S3ListResult()
        var token: String?
        repeat {
            var q = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: prefix)]
            if delimiter { q.append(URLQueryItem(name: "delimiter", value: "/")) }
            if let maxKeys { q.append(URLQueryItem(name: "max-keys", value: String(maxKeys))) }
            if let token { q.append(URLQueryItem(name: "continuation-token", value: token)) }
            let (_, data) = try await simple("GET", key: "", query: q, path: "/" + prefix)
            let page = try S3Parsing.parseList(data)
            all.objects += page.objects
            all.prefixes += page.prefixes
            token = page.isTruncated ? page.continuationToken : nil
            if maxKeys != nil { break }
        } while token != nil
        return all
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        let dir = RemotePath.normalize(path)
        var prefix = Self.key(dir)
        if !prefix.isEmpty { prefix += "/" }
        let r = try await listObjects(prefix: prefix, delimiter: true)
        var items: [RemoteItem] = []
        for p in r.prefixes {
            let name = String(p.dropFirst(prefix.count).dropLast(p.hasSuffix("/") ? 1 : 0))
            guard !name.isEmpty else { continue }
            items.append(RemoteItem(name: name, path: RemotePath.join(dir, name), type: .directory))
        }
        for o in r.objects where o.key != prefix {
            let name = String(o.key.dropFirst(prefix.count))
            guard !name.isEmpty, !name.contains("/") else { continue }
            items.append(RemoteItem(name: name, path: RemotePath.join(dir, name), type: .file, size: o.size,
                                    modificationDate: o.lastModified))
        }
        if items.isEmpty && !prefix.isEmpty && r.objects.isEmpty {
            // An empty listing for a folder without a marker means it does not exist.
            if (try? await stat(dir))?.isDirectory != true { throw RemoteError.notFound(dir) }
        }
        return items
    }

    public func stat(_ path: String) async throws -> RemoteItem {
        let p = RemotePath.normalize(path)
        if p == "/" { return RemoteItem(name: "/", path: "/", type: .directory) }
        let key = Self.key(p)
        let (resp, _) = try await send("HEAD", key: key) { req in
            let (d, r) = try await self.transport.data(req)
            return (r, d)
        }
        if (200..<300).contains(resp.statusCode) {
            let size = resp.value(forHTTPHeaderField: "Content-Length").flatMap { UInt64($0) }
            let date = resp.value(forHTTPHeaderField: "Last-Modified").flatMap { HTTPDates.parse($0) }
            return RemoteItem(name: RemotePath.lastComponent(p), path: p, type: .file, size: size, modificationDate: date)
        }
        if resp.statusCode != 404 {
            if let e = S3Parsing.error(status: resp.statusCode, info: nil, path: p) { throw e }
        }
        let r = try await listObjects(prefix: key + "/", delimiter: true, maxKeys: 1)
        if !r.objects.isEmpty || !r.prefixes.isEmpty {
            return RemoteItem(name: RemotePath.lastComponent(p), path: p, type: .directory)
        }
        throw RemoteError.notFound(p)
    }

    public func symlinkTarget(_ path: String) async throws -> String { throw RemoteError.unsupported("S3 has no symbolic links.") }

    // MARK: Operations

    private func copyObject(_ srcKey: String, _ dstKey: String, path: String) async throws {
        let source = "/" + URLEncoding.path(bucket + "/" + srcKey)
        let (_, data) = try await simple("PUT", key: dstKey, headers: ["x-amz-copy-source": source], path: path)
        // CopyObject can report errors with HTTP 200.
        if let info = S3Parsing.parseError(data), let e = S3Parsing.error(status: 500, info: info, path: path) { throw e }
    }

    private func objectsUnder(_ path: String) async throws -> [S3ListResult.Object] {
        try await listObjects(prefix: Self.key(path) + "/", delimiter: false).objects
    }

    public func copyItem(_ from: String, to: String) async throws {
        let item = try await stat(from)
        if item.isDirectory {
            let srcPrefix = Self.key(from) + "/", dstPrefix = Self.key(to) + "/"
            let objects = try await objectsUnder(from)
            if let big = objects.first(where: { $0.size > Self.maxSingleUpload }) {
                throw RemoteError.unsupported("\(big.key) is larger than 5 GB and cannot be copied.")
            }
            if objects.isEmpty { try await createDirectory(to) }
            for o in objects {
                try Task.checkCancellation()
                try await copyObject(o.key, dstPrefix + o.key.dropFirst(srcPrefix.count), path: to)
            }
        } else {
            if let s = item.size, s > Self.maxSingleUpload {
                throw RemoteError.unsupported("Objects larger than 5 GB cannot be copied (multipart copy is not supported).")
            }
            try await copyObject(Self.key(from), Self.key(to), path: to)
        }
    }

    public func rename(_ from: String, to: String) async throws {
        if await exists(to) != nil { throw RemoteError.alreadyExists(to) }
        let item = try await stat(from)
        try await copyItem(from, to: to)
        try await delete(from, isDirectory: item.isDirectory)
    }

    public func delete(_ path: String, isDirectory: Bool) async throws {
        if isDirectory {
            for o in try await objectsUnder(path) {
                try Task.checkCancellation()
                _ = try await simple("DELETE", key: o.key, path: "/" + o.key)
            }
            // Marker object (may not exist).
            _ = try? await simple("DELETE", key: Self.key(path) + "/", path: path)
        } else {
            _ = try await simple("DELETE", key: Self.key(path), path: path)
        }
    }

    public func createDirectory(_ path: String) async throws {
        if let existing = await exists(path) { throw RemoteError.alreadyExists(existing.path) }
        _ = try await simple("PUT", key: Self.key(path) + "/", headers: ["content-length": "0"], path: path)
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        throw RemoteError.unsupported("S3 does not support changing permissions.")
    }

    /// S3 sets the modification time on upload; nothing to do.
    public func setModificationDate(_ path: String, date: Date) async throws {}

    // MARK: Transfers

    public func download(_ remotePath: String, to localURL: URL, offset: UInt64,
                         progress: @escaping TransferProgressHandler) async throws {
        let headers = offset > 0 ? ["range": "bytes=\(offset)-"] : [:]
        let (resp, data) = try await send("GET", key: Self.key(remotePath), headers: headers) { req in
            try await self.transport.stream(req, progress: progress) { resp in
                try WebDAVFileSystem.openForDownload(resp, localURL: localURL, offset: offset)
            }
        }
        if offset > 0 && resp.statusCode == 416 { progress(offset); return }
        if let e = S3Parsing.error(status: resp.statusCode, info: S3Parsing.parseError(data), path: remotePath) { throw e }
    }

    public func upload(_ localURL: URL, to remotePath: String, offset: UInt64,
                       progress: @escaping TransferProgressHandler) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size > Self.maxSingleUpload {
            throw RemoteError.unsupported("Files larger than 5 GB cannot be uploaded to S3 (multipart upload is not supported).")
        }
        let (resp, data) = try await send("PUT", key: Self.key(remotePath), headers: ["content-type": "application/octet-stream"]) { req in
            let (d, r) = try await self.transport.upload(req, fromFile: localURL, progress: progress)
            return (r, d)
        }
        if let e = S3Parsing.error(status: resp.statusCode, info: S3Parsing.parseError(data), path: remotePath) { throw e }
    }
}
