import XCTest
@testable import xFinderKit

@MainActor
final class EditSyncTests: XCTestCase {
    var tmp: URL!
    var fs: MemoryFileSystem!
    var service: EditSyncService!
    let endpoint = RemoteEndpoint(id: "site:test", label: "test", capabilities: .sftp)

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xf-edit-\(UUID().uuidString)")
        fs = MemoryFileSystem()
        fs.mkdir("/srv")
        fs.put("/srv/app.conf", Data("original\n".utf8))
        let pool = TransferConnectionPool()
        let fs = self.fs!
        await pool.register(endpoint.id) { fs.connected = true; return fs }
        service = EditSyncService(pool: pool, editRoot: tmp)
        service.pollInterval = 3600   // the tests drive poll() themselves
        service.stableInterval = 0.8
    }

    override func tearDown() async throws {
        for s in service.sessions { service.stopWatching(s) }
        try? FileManager.default.removeItem(at: tmp)
    }

    func waitFor(_ timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("Timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Writes new content with a distinct modification date.
    func save(_ url: URL, _ text: String, _ offset: TimeInterval) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(offset)], ofItemAtPath: url.path)
    }

    func testOpenDownloadsAndSavesUploadAfterStability() async throws {
        let url = try await service.open("/srv/app.conf", endpoint: endpoint)
        XCTAssertTrue(url.path.hasPrefix(tmp.path))
        XCTAssertTrue(url.path.hasSuffix("/srv/app.conf"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original\n")
        let s = try XCTUnwrap(service.sessions.first)
        XCTAssertEqual(s.status, .inSync)
        XCTAssertFalse(service.hasPendingUploads)

        try save(url, "edited\n", 10)
        let t0 = Date()
        service.poll(now: t0)
        XCTAssertEqual(s.status, .changed)
        XCTAssertTrue(service.hasPendingUploads)
        service.poll(now: t0.addingTimeInterval(0.3))   // not stable long enough yet
        XCTAssertEqual(s.status, .changed)
        service.poll(now: t0.addingTimeInterval(1.0))
        try await waitFor { s.status == .inSync }
        XCTAssertEqual(fs.data("/srv/app.conf"), Data("edited\n".utf8))
        XCTAssertNotNil(s.lastUpload)
        XCTAssertFalse(fs.allPaths.contains { $0.hasSuffix(".rfpart") })
    }

    func testReopenNeverOverwritesLocalChanges() async throws {
        let url = try await service.open("/srv/app.conf", endpoint: endpoint)
        try save(url, "local work\n", 10)
        service.poll(now: Date())
        fs.put("/srv/app.conf", Data("server\n".utf8))
        let again = try await service.open("/srv/app.conf", endpoint: endpoint)
        XCTAssertEqual(again, url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "local work\n")
        XCTAssertEqual(service.sessions.count, 1)
    }

    func testConflictIsDetectedAndCanBeResolved() async throws {
        var asked = 0
        var answer: EditConflictChoice = .decideLater
        service.conflictHandler = { _ in asked += 1; return answer }
        let url = try await service.open("/srv/app.conf", endpoint: endpoint)
        let s = try XCTUnwrap(service.sessions.first)
        fs.put("/srv/app.conf", Data("someone else\n".utf8), mtime: Date())
        try save(url, "mine\n", 10)
        let t0 = Date()
        service.poll(now: t0)
        service.poll(now: t0.addingTimeInterval(1))
        try await waitFor { asked == 1 }
        try await waitFor { s.status == .conflict }
        XCTAssertEqual(fs.data("/srv/app.conf"), Data("someone else\n".utf8))

        answer = .replaceServerVersion
        await service.resolveConflict(s, choice: .replaceServerVersion)
        try await waitFor { s.status == .inSync }
        XCTAssertEqual(fs.data("/srv/app.conf"), Data("mine\n".utf8))
    }

    func testConflictReplaceFromDialog() async throws {
        service.conflictHandler = { _ in .replaceServerVersion }
        let url = try await service.open("/srv/app.conf", endpoint: endpoint)
        let s = try XCTUnwrap(service.sessions.first)
        fs.put("/srv/app.conf", Data("theirs, longer\n".utf8), mtime: Date())
        try save(url, "mine\n", 10)
        let t0 = Date()
        service.poll(now: t0)
        service.poll(now: t0.addingTimeInterval(1))
        try await waitFor { s.status == .inSync && self.fs.data("/srv/app.conf") == Data("mine\n".utf8) }
    }

    func testUploadAsCopyAndDiscard() async throws {
        let url = try await service.open("/srv/app.conf", endpoint: endpoint)
        let s = try XCTUnwrap(service.sessions.first)
        try save(url, "mine\n", 10)
        await service.resolveConflict(s, choice: .uploadAsCopy)
        XCTAssertEqual(fs.data("/srv/app copy.conf"), Data("mine\n".utf8))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original\n")
        XCTAssertEqual(s.status, .inSync)

        try save(url, "throw away\n", 20)
        await service.resolveConflict(s, choice: .discardMyChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original\n")
    }

    func testUnreachableServerRetriesWithBackoff() async throws {
        XCTAssertEqual(EditSyncService.retryDelay(attempt: 1), 10)
        XCTAssertEqual(EditSyncService.retryDelay(attempt: 2), 20)
        XCTAssertEqual(EditSyncService.retryDelay(attempt: 4), 60)
        XCTAssertEqual(EditSyncService.retryDelay(attempt: 10), 60)

        let url = try await service.open("/srv/app.conf", endpoint: endpoint)
        let s = try XCTUnwrap(service.sessions.first)
        await service.pool.register(endpoint.id) { throw RemoteError.connectionFailed("offline") }
        await service.pool.closeAll()
        try save(url, "offline edit\n", 10)
        let t0 = Date()
        service.poll(now: t0)
        service.poll(now: t0.addingTimeInterval(1))
        try await waitFor { if case .unreachable = s.status { return true }; return false }
        XCTAssertNotNil(s.nextRetry)
        XCTAssertTrue(service.hasPendingUploads)

        let fs = self.fs!
        await service.pool.register(endpoint.id) { fs.connected = true; return fs }
        service.retryUnreachable(endpointID: endpoint.id)
        try await waitFor { s.status == .inSync }
        XCTAssertEqual(fs.data("/srv/app.conf"), Data("offline edit\n".utf8))
    }

    func testCleanUpAndStopWatching() async throws {
        let url = try await service.open("/srv/app.conf", endpoint: endpoint)
        service.cleanUpUnchanged()
        XCTAssertTrue(service.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
