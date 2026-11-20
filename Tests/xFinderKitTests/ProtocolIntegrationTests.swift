import XCTest
@testable import xFinderKit

/// Online tests for FTP, FTPS, WebDAV and S3. They run only when
/// XF_IT_PROTOCOL is set (see scripts/test_protocol_servers.sh).
@MainActor
final class ProtocolIntegrationTests: XCTestCase {
    struct Env {
        var site: Site
        var password: String
        var root: String
    }

    func env() throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard let p = e["XF_IT_PROTOCOL"], let proto = SiteProtocol(rawValue: p) else {
            throw XCTSkip("No protocol test server configured")
        }
        var site = Site(name: "it", protocolType: proto, host: e["XF_IT_HOST"] ?? "127.0.0.1",
                        port: e["XF_IT_PORT"].flatMap(Int.init), username: e["XF_IT_USER"] ?? "")
        site.webDAVBasePath = e["XF_IT_BASE"] ?? ""
        site.s3Bucket = e["XF_IT_BUCKET"] ?? ""
        site.s3Region = e["XF_IT_REGION"] ?? ""
        site.s3UsePlainHTTP = e["XF_IT_PLAIN_HTTP"] == "1"
        return Env(site: site, password: e["XF_IT_PASS"] ?? "", root: e["XF_IT_ROOT"] ?? "/")
    }

    func makeFS(_ env: Env) throws -> RemoteFileSystem {
        let resolver = SiteSettingsResolver(library: SiteLibrary(), keys: KeyLibrary(), accounts: AccountStore(), settings: AppSettings())
        let interaction = NonInteractive(acceptUnknownHosts: true,
                                         secrets: [.password: env.password, .s3Secret: env.password])
        let environment = ConnectionEnvironment(knownHosts: KnownHostsStore(url: nil), secrets: InMemorySecretStore(),
                                                interaction: interaction)
        return try RemoteFileSystemFactory.make(ConnectionConfig(site: env.site, resolved: resolver.resolve(env.site)),
                                                environment: environment)
    }

    func testRoundTrip() async throws {
        let env = try env()
        let fs = try makeFS(env)
        try await fs.connect()
        let dir = RemotePath.join(env.root, "xf-it-\(UUID().uuidString.prefix(8))")
        try await fs.createDirectory(dir)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xf-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let payload = Data((0..<700_000).map { UInt8($0 % 251) })
        let local = tmp.appendingPathComponent("file with space.bin")
        try payload.write(to: local)
        let remote = RemotePath.join(dir, "file with space.bin")
        try await fs.upload(local, to: remote, offset: 0) { _ in }

        let items = try await fs.list(dir)
        XCTAssertEqual(items.map(\.name), ["file with space.bin"])
        XCTAssertEqual(items.first?.size, UInt64(payload.count))
        let st = try await fs.stat(remote)
        XCTAssertEqual(st.type, .file)
        let v1 = try await fs.stat(dir)
        XCTAssertEqual(v1.type, .directory)

        let back = tmp.appendingPathComponent("back")
        try await fs.download(remote, to: back, offset: 0) { _ in }
        XCTAssertEqual(try Data(contentsOf: back), payload)

        if fs.capabilities.canResumeDownload {
            let half = tmp.appendingPathComponent("half")
            try payload.prefix(300_000).write(to: half)
            try await fs.download(remote, to: half, offset: 300_000) { _ in }
            XCTAssertEqual(try Data(contentsOf: half), payload)
        }
        if fs.capabilities.canResumeUpload {
            let part = tmp.appendingPathComponent("part")
            try payload.write(to: part)
            let remotePart = RemotePath.join(dir, "part.bin")
            try payload.prefix(200_000).write(to: tmp.appendingPathComponent("first"))
            try await fs.upload(tmp.appendingPathComponent("first"), to: remotePart, offset: 0) { _ in }
            try await fs.upload(part, to: remotePart, offset: 200_000) { _ in }
            let check = tmp.appendingPathComponent("check")
            try await fs.download(remotePart, to: check, offset: 0) { _ in }
            XCTAssertEqual(try Data(contentsOf: check), payload)
            try await fs.delete(remotePart, isDirectory: false)
        }

        let renamed = RemotePath.join(dir, "renamed.bin")
        try await fs.rename(remote, to: renamed)
        await XCTAssertThrowsAsync { _ = try await fs.stat(remote) }
        let v2 = try await fs.stat(renamed)
        XCTAssertEqual(v2.size, UInt64(payload.count))

        if fs.capabilities.contains(.serverCopy) {
            let sub = RemotePath.join(dir, "sub")
            try await fs.createDirectory(sub)
            try await fs.copyItem(renamed, to: RemotePath.join(sub, "copy.bin"))
            let v3 = try await fs.stat(RemotePath.join(sub, "copy.bin"))
            XCTAssertEqual(v3.size, UInt64(payload.count))
            try await fs.copyItem(sub, to: RemotePath.join(dir, "sub2"))
            let v4 = try await fs.list(RemotePath.join(dir, "sub2"))
            XCTAssertEqual(v4.map(\.name), ["copy.bin"])
        }

        // Transfer queue over the same server.
        let pool = TransferConnectionPool()
        await pool.register("it") { try await fs.makeTransferConnection() }
        let m = TransferManager(pool: pool, stagingRoot: tmp.appendingPathComponent("Staging"))
        let ep = RemoteEndpoint(id: "it", label: "it", capabilities: fs.capabilities)
        let tree = tmp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: tree.appendingPathComponent("a.txt"))
        try payload.write(to: tree.appendingPathComponent("inner/b.bin"))
        try m.enqueue(.upload([tree], to: ep, directory: dir))
        while m.hasActiveTransfers { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(m.allItems.allSatisfy { $0.state == .completed }, "\(m.allItems.map(\.state))")
        let treeItem = try await fs.stat(RemotePath.join(dir, "tree"))
        try m.enqueue(.copy([treeItem], from: ep, to: ep, directory: dir, duplicate: true))
        while m.hasActiveTransfers { try await Task.sleep(nanoseconds: 20_000_000) }
        let v5 = try await fs.stat(RemotePath.join(dir, "tree copy/inner/b.bin"))
        XCTAssertEqual(v5.size, UInt64(payload.count))
        let out = tmp.appendingPathComponent("out")
        try m.enqueue(.download([try await fs.stat(RemotePath.join(dir, "tree copy"))], from: ep, to: out))
        while m.hasActiveTransfers { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("tree copy/inner/b.bin")), payload)
        let v6 = try await fs.list(RemotePath.join(dir, "tree"))
        XCTAssertFalse(v6.contains { $0.name.hasSuffix(".rfpart") })
        await pool.closeAll()

        try await fs.delete(dir, isDirectory: true)
        await XCTAssertThrowsAsync { _ = try await fs.list(dir) }
        await fs.disconnect()
    }
}
