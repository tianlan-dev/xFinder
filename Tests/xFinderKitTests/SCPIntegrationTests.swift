import XCTest
@testable import xFinderKit

/// SCP (shell) mode against the throwaway sshd without an SFTP subsystem from
/// scripts/test_sftp_server.sh (XF_SFTP_NOSUBSYSTEM_PORT). Skipped otherwise.
final class SCPIntegrationTests: XCTestCase {
    func makeFS() throws -> (SCPFileSystem, String) {
        let e = ProcessInfo.processInfo.environment
        guard let port = e["XF_SFTP_NOSUBSYSTEM_PORT"].flatMap(Int.init), let keyPath = e["XF_SFTP_TEST_KEY"] else {
            throw XCTSkip("No SFTP-less test server configured")
        }
        let keyEntry = SSHKeyEntry(alias: "test", path: keyPath)
        var site = Site(name: "test", protocolType: .scp, host: "127.0.0.1", port: port, username: NSUserName())
        site.key = .key(keyEntry.id)
        let resolver = SiteSettingsResolver(library: SiteLibrary(), keys: KeyLibrary(keys: [keyEntry]),
                                            accounts: AccountStore(), settings: AppSettings())
        let passphrase = e["XF_SFTP_TEST_PASSPHRASE"].flatMap { $0.isEmpty ? nil : $0 }
        let interaction = NonInteractive(acceptUnknownHosts: true, secrets: passphrase.map { [.passphrase: $0] } ?? [:])
        let environment = ConnectionEnvironment(knownHosts: KnownHostsStore(url: nil),
                                                secrets: InMemorySecretStore(), interaction: interaction)
        let fs = try RemoteFileSystemFactory.make(ConnectionConfig(site: site, resolved: resolver.resolve(site)),
                                                  environment: environment)
        return (try XCTUnwrap(fs as? SCPFileSystem), e["XF_SFTP_TEST_ROOT"] ?? NSTemporaryDirectory())
    }

    func roundTrip(_ fs: SCPFileSystem, root: String, label: String) async throws {
        let dir = RemotePath.join(root, "xf-scp-\(label)-\(UUID().uuidString.prefix(6))")
        try await fs.createDirectory(dir)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: local)
        let name = "it's a file ü.bin"
        let remote = RemotePath.join(dir, name)
        var lastProgress: UInt64 = 0
        try await fs.upload(local, to: remote, offset: 0) { lastProgress = $0 }
        XCTAssertEqual(lastProgress, UInt64(payload.count))

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: empty)
        try await fs.upload(empty, to: RemotePath.join(dir, "-empty"), offset: 0) { _ in }
        try await fs.createDirectory(RemotePath.join(dir, "sub dir"))

        let items = try await fs.list(dir)
        XCTAssertEqual(Set(items.map(\.name)), [name, "-empty", "sub dir"], label)
        XCTAssertEqual(items.first { $0.name == name }?.size, UInt64(payload.count))
        XCTAssertEqual(items.first { $0.name == "-empty" }?.size, 0)
        XCTAssertEqual(items.first { $0.name == "sub dir" }?.type, .directory)

        let back = local.appendingPathExtension("back")
        try await fs.download(remote, to: back, offset: 0) { _ in }
        XCTAssertEqual(try Data(contentsOf: back), payload, label)

        let renamed = RemotePath.join(dir, "renamed \"x\".bin")
        try await fs.rename(remote, to: renamed)
        await XCTAssertThrowsAsync { try await fs.rename(renamed, to: RemotePath.join(dir, "-empty")) }
        try await fs.setPermissions(renamed, mode: 0o640)
        let st = try await fs.stat(renamed)
        XCTAssertEqual(st.permissions.map { $0 & 0o777 }, 0o640)
        XCTAssertEqual(st.size, UInt64(payload.count))

        await XCTAssertThrowsAsync { _ = try await fs.stat(RemotePath.join(dir, "missing")) }
        do {
            try await fs.download(RemotePath.join(dir, "missing"), to: back, offset: 0) { _ in }
            XCTFail("download of a missing file should fail")
        } catch let e as RemoteError {
            XCTAssertEqual(e, .notFound(RemotePath.join(dir, "missing")), label)
        }

        try await fs.delete(renamed, isDirectory: false)
        try await fs.delete(dir, isDirectory: true)
        await XCTAssertThrowsAsync { _ = try await fs.stat(dir) }
        for u in [local, back, empty] { try? FileManager.default.removeItem(at: u) }
    }

    func testRoundTripWithSCP() async throws {
        let (fs, root) = try makeFS()
        try await fs.connect()
        XCTAssertTrue(fs.homeDirectory.hasPrefix("/"))
        XCTAssertTrue(fs.tools.scp)
        try await roundTrip(fs, root: root, label: "scp")
        await fs.disconnect()
    }

    func testRoundTripWithCatFallback() async throws {
        let (fs, root) = try makeFS()
        try await fs.connect()
        fs.overrideTools { $0.scp = false }
        try await roundTrip(fs, root: root, label: "cat")
        await fs.disconnect()
    }

    func testRoundTripWithLsFallback() async throws {
        let (fs, root) = try makeFS()
        try await fs.connect()
        fs.overrideTools { $0.stat = false }
        try await roundTrip(fs, root: root, label: "ls")
        await fs.disconnect()
    }
}
