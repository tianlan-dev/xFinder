import XCTest
@testable import xFinderKit

@MainActor
final class TransferManagerTests: XCTestCase {
    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xf-tm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeManager(_ servers: [(RemoteEndpoint, MemoryFileSystem)]) async -> TransferManager {
        let pool = TransferConnectionPool()
        for (ep, fs) in servers {
            await pool.register(ep.id) { fs.connected = true; return fs }
        }
        return TransferManager(pool: pool, stagingRoot: tmp.appendingPathComponent("Staging"))
    }

    func waitUntilIdle(_ m: TransferManager, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while m.hasActiveTransfers {
            if Date() > deadline { XCTFail("Timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func endpoint(_ id: String, _ caps: RemoteCapabilities = .sftp) -> RemoteEndpoint {
        RemoteEndpoint(id: id, label: id, capabilities: caps)
    }

    func testNaming() {
        XCTAssertEqual(TransferNaming.duplicateName("a.txt", isDirectory: false, existing: []), "a copy.txt")
        XCTAssertEqual(TransferNaming.duplicateName("a.txt", isDirectory: false, existing: ["a copy.txt"]), "a copy 2.txt")
        XCTAssertEqual(TransferNaming.duplicateName("dir.d", isDirectory: true, existing: []), "dir.d copy")
        XCTAssertEqual(TransferNaming.duplicateName(".bashrc", isDirectory: false, existing: []), ".bashrc copy")
        XCTAssertEqual(TransferNaming.duplicateName(".config.json", isDirectory: false, existing: []), ".config copy.json")
        XCTAssertEqual(TransferNaming.duplicateName("archive.tar.gz", isDirectory: false, existing: []), "archive.tar copy.gz")
        XCTAssertEqual(TransferNaming.keepBothName("a.txt", isDirectory: false, existing: ["a 2.txt"]), "a 3.txt")
        XCTAssertEqual(TransferNaming.remoteTemporaryName("a.txt"), ".a.txt.rfpart")
        XCTAssertEqual(TransferNaming.localTemporaryName("a.txt"), "a.txt.rfdownload")
    }

    func testUploadFolderRecursivelySkippingSymlinks() async throws {
        let fs = MemoryFileSystem()
        let ep = endpoint("a")
        let m = await makeManager([(ep, fs)])
        let src = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: src.appendingPathComponent("one.txt"))
        try Data(repeating: 7, count: 20_000).write(to: src.appendingPathComponent("sub/two.bin"))
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("link"), withDestinationURL: src.appendingPathComponent("one.txt"))
        try m.enqueue(.upload([src], to: ep, directory: "/"))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/src/one.txt"), Data("one".utf8))
        XCTAssertEqual(fs.data("/src/sub/two.bin")?.count, 20_000)
        XCTAssertNil(fs.node("/src/link"))
        XCTAssertFalse(fs.allPaths.contains { $0.hasSuffix(".rfpart") })
        XCTAssertEqual(m.allItems.count, 2)
        XCTAssertTrue(m.allItems.allSatisfy { $0.state == .completed })
        XCTAssertEqual(m.summary, "All transfers finished")
    }

    func testDownloadKeepsModificationDateAndLeavesNoTemporaryFile() async throws {
        let fs = MemoryFileSystem()
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        fs.mkdir("/d")
        fs.put("/d/f.txt", Data("hello".utf8), mtime: date)
        let ep = endpoint("a")
        let m = await makeManager([(ep, fs)])
        try m.enqueue(.download([try await fs.stat("/d")], from: ep, to: tmp))
        try await waitUntilIdle(m)
        let out = tmp.appendingPathComponent("d/f.txt")
        XCTAssertEqual(try Data(contentsOf: out), Data("hello".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: out.path)
        XCTAssertEqual((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, 1_600_000_000, accuracy: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("d/f.txt.rfdownload").path))
    }

    func testConflictPolicies() async throws {
        let fs = MemoryFileSystem()
        let ep = endpoint("a")
        fs.put("/f.txt", Data("old".utf8))
        let local = tmp.appendingPathComponent("f.txt")
        try Data("new".utf8).write(to: local)

        let m = await makeManager([(ep, fs)])
        m.conflictPolicy = .skip
        try m.enqueue(.upload([local], to: ep, directory: "/"))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/f.txt"), Data("old".utf8))
        XCTAssertEqual(m.allItems.last?.state, .skipped(""))

        m.conflictPolicy = .keepBoth
        try m.enqueue(.upload([local], to: ep, directory: "/"))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/f 2.txt"), Data("new".utf8))

        m.conflictPolicy = .overwrite
        try m.enqueue(.upload([local], to: ep, directory: "/"))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/f.txt"), Data("new".utf8))
    }

    func testOverwriteIfNewerUsesOneSecondTolerance() async throws {
        let fs = MemoryFileSystem()
        let ep = endpoint("a")
        let local = tmp.appendingPathComponent("f.txt")
        try Data("new".utf8).write(to: local)
        let localDate = try FileManager.default.attributesOfItem(atPath: local.path)[.modificationDate] as! Date
        fs.put("/f.txt", Data("old".utf8), mtime: localDate.addingTimeInterval(-0.5))
        let m = await makeManager([(ep, fs)])
        m.conflictPolicy = .overwriteIfNewer
        try m.enqueue(.upload([local], to: ep, directory: "/"))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/f.txt"), Data("old".utf8), "within tolerance: skipped")

        fs.put("/f.txt", Data("old".utf8), mtime: localDate.addingTimeInterval(-10))
        try m.enqueue(.upload([local], to: ep, directory: "/"))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/f.txt"), Data("new".utf8))
    }

    func testAskWithApplyToAllAndResume() async throws {
        let fs = MemoryFileSystem()
        let ep = endpoint("a")
        let payload = Data((0..<10_000).map { UInt8($0 % 200) })
        fs.put("/a.bin", payload.prefix(4000))
        fs.put("/b.bin", payload.prefix(100))
        let a = tmp.appendingPathComponent("a.bin"), b = tmp.appendingPathComponent("b.bin")
        try payload.write(to: a)
        try payload.write(to: b)
        let m = await makeManager([(ep, fs)])
        m.maxConcurrent = 1
        var asked: [TransferConflict] = []
        m.conflictHandler = { c in asked.append(c); return ConflictAnswer(.resume, applyToAll: true) }
        try m.enqueue(.upload([a, b], to: ep, directory: "/"))
        try await waitUntilIdle(m)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].canResume)
        XCTAssertEqual(fs.data("/a.bin"), payload)
        XCTAssertEqual(fs.data("/b.bin"), payload)
    }

    func testStopCancelsBatch() async throws {
        let fs = MemoryFileSystem()
        let ep = endpoint("a")
        fs.put("/a.txt", Data("x".utf8))
        fs.put("/b.txt", Data("x".utf8))
        let a = tmp.appendingPathComponent("a.txt"), b = tmp.appendingPathComponent("b.txt")
        try Data("new".utf8).write(to: a)
        try Data("new".utf8).write(to: b)
        let m = await makeManager([(ep, fs)])
        m.maxConcurrent = 1
        m.conflictHandler = { _ in ConflictAnswer(.stop) }
        try m.enqueue(.upload([a, b], to: ep, directory: "/"))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/a.txt"), Data("x".utf8))
        XCTAssertEqual(fs.data("/b.txt"), Data("x".utf8))
        XCTAssertTrue(m.allItems.allSatisfy { $0.state == .cancelled })
    }

    func testDuplicateUsesServerCopy() async throws {
        let fs = MemoryFileSystem()
        let ep = endpoint("a")
        fs.put("/a.txt", Data("x".utf8))
        fs.put("/a copy.txt", Data("x".utf8))
        let m = await makeManager([(ep, fs)])
        try m.enqueue(.copy([try await fs.stat("/a.txt")], from: ep, to: ep, directory: "/", duplicate: true))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/a copy 2.txt"), Data("x".utf8))
        XCTAssertEqual(fs.copyCount.value, 1)
    }

    func testCopyFallsBackToStagingWithoutServerCopy() async throws {
        let fs = MemoryFileSystem(capabilities: .ftp)
        let ep = endpoint("a", .ftp)
        fs.mkdir("/dir")
        fs.put("/dir/x.txt", Data("abc".utf8))
        fs.mkdir("/target")
        let m = await makeManager([(ep, fs)])
        try m.enqueue(.copy([try await fs.stat("/dir")], from: ep, to: ep, directory: "/target", duplicate: false))
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/target/dir/x.txt"), Data("abc".utf8))
        XCTAssertEqual(fs.data("/dir/x.txt"), Data("abc".utf8))
        let staging = tmp.appendingPathComponent("Staging")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staging.path))?.count ?? 0, 0)
    }

    func testCrossServerCopy() async throws {
        let a = MemoryFileSystem(), b = MemoryFileSystem(capabilities: .webDAV)
        let ea = endpoint("a"), eb = endpoint("b", .webDAV)
        a.put("/f.bin", Data(repeating: 1, count: 50_000))
        let m = await makeManager([(ea, a), (eb, b)])
        try m.enqueue(.copy([try await a.stat("/f.bin")], from: ea, to: eb, directory: "/", duplicate: false))
        try await waitUntilIdle(m)
        XCTAssertEqual(b.data("/f.bin")?.count, 50_000)
        XCTAssertEqual(a.copyCount.value, 0)
    }

    func testCopyIntoItselfIsRejected() async throws {
        let fs = MemoryFileSystem()
        let ep = endpoint("a")
        fs.mkdir("/dir")
        fs.mkdir("/dir/sub")
        let m = await makeManager([(ep, fs)])
        let dir = try await fs.stat("/dir")
        XCTAssertThrowsError(try m.enqueue(.copy([dir], from: ep, to: ep, directory: "/dir/sub", duplicate: false))) {
            XCTAssertEqual($0 as? TransferRequestError, .copyIntoItself("dir"))
        }
    }

    func testPauseResumeAndCancelCleansTemporaryFile() async throws {
        let fs = MemoryFileSystem()
        fs.chunkDelay = 2_000_000
        let ep = endpoint("a")
        let local = tmp.appendingPathComponent("big.bin")
        let payload = Data((0..<400_000).map { UInt8($0 % 256) })
        try payload.write(to: local)
        let m = await makeManager([(ep, fs)])
        try m.enqueue(.upload([local], to: ep, directory: "/"))
        while m.allItems.first?.state != .running { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let item = m.allItems[0]
        m.pause(item)
        while item.state != .paused { try await Task.sleep(nanoseconds: 5_000_000) }
        let partial = fs.data("/.big.bin.rfpart")?.count ?? 0
        XCTAssertGreaterThan(partial, 0)
        XCTAssertLessThan(partial, payload.count)
        m.resume(item)
        try await waitUntilIdle(m)
        XCTAssertEqual(fs.data("/big.bin"), payload)
        XCTAssertNil(fs.node("/.big.bin.rfpart"))

        // Cancel removes the temporary file.
        m.conflictPolicy = .keepBoth
        try m.enqueue(.upload([local], to: ep, directory: "/"))
        while m.allItems.last?.state != .running { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 30_000_000)
        m.cancel(m.allItems.last!)
        while m.allItems.last?.state != .cancelled { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(fs.allPaths.contains { $0.hasSuffix(".rfpart") })
    }

    func testConcurrencyLimit() async throws {
        let fs = MemoryFileSystem()
        fs.chunkDelay = 1_000_000
        let ep = endpoint("a")
        var urls: [URL] = []
        for i in 0..<6 {
            let u = tmp.appendingPathComponent("f\(i).bin")
            try Data(repeating: UInt8(i), count: 40_000).write(to: u)
            urls.append(u)
        }
        let m = await makeManager([(ep, fs)])
        m.maxConcurrent = 2
        try m.enqueue(.upload(urls, to: ep, directory: "/"))
        var maxRunning = 0
        while m.hasActiveTransfers {
            maxRunning = max(maxRunning, m.runningCount)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertLessThanOrEqual(maxRunning, 2)
        XCTAssertEqual(maxRunning, 2)
        for i in 0..<6 { XCTAssertEqual(fs.data("/f\(i).bin")?.count, 40_000) }
    }
}
