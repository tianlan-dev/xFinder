import XCTest
@testable import xFinderKit

/// Runs only when XF_SFTP_TEST_PORT and XF_SFTP_TEST_KEY point at a throwaway sshd
/// on 127.0.0.1 (see scripts/test_sftp_server.sh). Skipped otherwise.
final class SFTPIntegrationTests: XCTestCase {
    struct Env {
        var port: Int
        var keyPath: String
        var passphrase: String?
        var root: String
    }

    func env() throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard let p = e["XF_SFTP_TEST_PORT"].flatMap(Int.init), let k = e["XF_SFTP_TEST_KEY"] else {
            throw XCTSkip("No test SFTP server configured")
        }
        return Env(port: p, keyPath: k, passphrase: e["XF_SFTP_TEST_PASSPHRASE"],
                   root: e["XF_SFTP_TEST_ROOT"] ?? NSTemporaryDirectory())
    }

    func makeFS(_ env: Env) throws -> RemoteFileSystem {
        let keyEntry = SSHKeyEntry(alias: "test", path: env.keyPath)
        var site = Site(name: "test", host: "127.0.0.1", port: env.port, username: NSUserName())
        site.key = .key(keyEntry.id)
        let resolver = SiteSettingsResolver(library: SiteLibrary(), keys: KeyLibrary(keys: [keyEntry]),
                                            accounts: AccountStore(), settings: AppSettings())
        let interaction = NonInteractive(acceptUnknownHosts: true,
                                         secrets: env.passphrase.map { [.passphrase: $0] } ?? [:])
        let environment = ConnectionEnvironment(knownHosts: KnownHostsStore(url: nil),
                                                secrets: InMemorySecretStore(), interaction: interaction)
        return try RemoteFileSystemFactory.make(ConnectionConfig(site: site, resolved: resolver.resolve(site)),
                                                environment: environment)
    }

    func testRoundTrip() async throws {
        let env = try env()
        let fs = try makeFS(env)
        try await fs.connect()
        XCTAssertFalse(fs.homeDirectory.isEmpty)
        let dir = RemotePath.join(env.root, "xf-it-\(UUID().uuidString.prefix(8))")
        try await fs.createDirectory(dir)

        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data((0..<1_500_000).map { UInt8($0 % 251) })
        try payload.write(to: local)
        let remote = RemotePath.join(dir, "file.bin")
        try await fs.upload(local, to: remote, offset: 0) { _ in }

        let items = try await fs.list(dir)
        XCTAssertEqual(items.map(\.name), ["file.bin"])
        XCTAssertEqual(items.first?.size, UInt64(payload.count))

        let back = local.appendingPathExtension("back")
        try await fs.download(remote, to: back, offset: 0) { _ in }
        XCTAssertEqual(try Data(contentsOf: back), payload)

        // Resume: download the first half, then continue from the offset.
        let half = local.appendingPathExtension("half")
        try payload.prefix(700_000).write(to: half)
        try await fs.download(remote, to: half, offset: 700_000) { _ in }
        XCTAssertEqual(try Data(contentsOf: half), payload)

        try await fs.rename(remote, to: RemotePath.join(dir, "renamed.bin"))
        try await fs.setPermissions(RemotePath.join(dir, "renamed.bin"), mode: 0o640)
        let st = try await fs.stat(RemotePath.join(dir, "renamed.bin"))
        XCTAssertEqual(st.permissions.map { $0 & 0o777 }, 0o640)

        try await fs.delete(dir, isDirectory: true)
        await XCTAssertThrowsAsync { _ = try await fs.stat(dir) }
        await fs.disconnect()
        for u in [local, back, half] { try? FileManager.default.removeItem(at: u) }
    }
}

extension SFTPIntegrationTests {
    @MainActor
    func testTransferQueueOverSFTP() async throws {
        let env = try env()
        let template = try makeFS(env)
        try await template.connect()
        let pool = TransferConnectionPool()
        await pool.register("sftp") { try await template.makeTransferConnection() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xf-q-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 300_000).write(to: src.appendingPathComponent("sub/a.bin"))
        try Data("hi".utf8).write(to: src.appendingPathComponent("b.txt"))
        let m = TransferManager(pool: pool, stagingRoot: tmp.appendingPathComponent("Staging"))
        let ep = RemoteEndpoint(id: "sftp", label: "test", capabilities: template.capabilities)
        let root = RemotePath.join(env.root, "xf-q-\(UUID().uuidString.prefix(6))")
        try await template.createDirectory(root)
        func idle() async throws { while m.hasActiveTransfers { try await Task.sleep(nanoseconds: 20_000_000) } }

        try m.enqueue(.upload([src], to: ep, directory: root))
        try await idle()
        XCTAssertTrue(m.allItems.allSatisfy { $0.state == .completed }, "\(m.allItems.map(\.state))")
        let tree = try await template.stat(RemotePath.join(root, "tree"))
        try m.enqueue(.copy([tree], from: ep, to: ep, directory: root, duplicate: true))
        try await idle()
        let copied = try await template.stat(RemotePath.join(root, "tree copy/sub/a.bin"))
        XCTAssertEqual(copied.size, 300_000)

        let out = tmp.appendingPathComponent("out")
        try m.enqueue(.download([try await template.stat(RemotePath.join(root, "tree copy"))], from: ep, to: out))
        try await idle()
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("tree copy/sub/a.bin")).count, 300_000)
        XCTAssertTrue(m.allItems.allSatisfy { $0.state == .completed }, "\(m.allItems.map(\.state))")

        try await template.delete(root, isDirectory: true)
        await template.disconnect()
        await pool.closeAll()
        try? FileManager.default.removeItem(at: tmp)
    }
}

func XCTAssertThrowsAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("Expected an error", file: file, line: line) } catch {}
}

extension SFTPIntegrationTests {
    /// A server that refuses the "sftp" subsystem must fail quickly with a
    /// specific message instead of hanging (XF_SFTP_NOSUBSYSTEM_PORT).
    func testServerWithoutSFTPSubsystemFailsFast() async throws {
        var env = try env()
        guard let port = ProcessInfo.processInfo.environment["XF_SFTP_NOSUBSYSTEM_PORT"].flatMap(Int.init) else {
            throw XCTSkip("No SFTP-less test server configured")
        }
        env.port = port
        let fs = try makeFS(env)
        let start = Date()
        do {
            try await fs.connect()
            XCTFail("connect should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not offer SFTP"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
