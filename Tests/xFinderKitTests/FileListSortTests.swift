import XCTest
@testable import xFinderKit

final class FileListSortTests: XCTestCase {
    func item(_ name: String, _ type: RemoteItemType, size: UInt64? = nil, date: TimeInterval? = nil,
              linkToDir: Bool? = nil) -> RemoteItem {
        RemoteItem(name: name, path: "/" + name, type: type, size: size,
                   modificationDate: date.map(Date.init(timeIntervalSince1970:)),
                   symlinkTargetIsDirectory: linkToDir)
    }

    lazy var list: [RemoteItem] = [
        item("b.txt", .file, size: 10, date: 300),
        item("zeta", .directory, date: 100),
        item("A10.log", .file, size: 500, date: 200),
        item("alpha", .directory, date: 400),
        item("A2.log", .file, size: 5, date: 50),
        item("link", .symlink, date: 250, linkToDir: true),
    ]

    func names(_ key: FileSortKey, _ asc: Bool, _ foldersFirst: Bool) -> [String] {
        FileListSort.sorted(list, by: key, ascending: asc, foldersFirst: foldersFirst).map(\.name)
    }

    func testFoldersFirstByName() {
        XCTAssertEqual(names(.name, true, true), ["alpha", "link", "zeta", "A2.log", "A10.log", "b.txt"])
        // Folders stay on top when the direction flips.
        XCTAssertEqual(names(.name, false, true), ["zeta", "link", "alpha", "b.txt", "A10.log", "A2.log"])
    }

    func testMixedByName() {
        XCTAssertEqual(names(.name, true, false), ["A2.log", "A10.log", "alpha", "b.txt", "link", "zeta"])
        XCTAssertEqual(names(.name, false, false), ["zeta", "link", "b.txt", "alpha", "A10.log", "A2.log"])
    }

    func testMixedByDate() {
        XCTAssertEqual(names(.date, true, false), ["A2.log", "zeta", "A10.log", "link", "b.txt", "alpha"])
        XCTAssertEqual(names(.date, true, true), ["zeta", "link", "alpha", "A2.log", "A10.log", "b.txt"])
    }

    func testSizeTreatsFoldersAsUnknown() {
        // Mixed: folders have no size and come first ascending, last descending.
        XCTAssertEqual(names(.size, true, false), ["alpha", "link", "zeta", "A2.log", "b.txt", "A10.log"])
        XCTAssertEqual(names(.size, false, false), ["A10.log", "b.txt", "A2.log", "alpha", "link", "zeta"])
        XCTAssertEqual(names(.size, false, true), ["alpha", "link", "zeta", "A10.log", "b.txt", "A2.log"])
    }

    func testSettingDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(AppSettings().foldersFirst)
        var s = AppSettings()
        s.foldersFirst = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(decoded.foldersFirst)
        // Older settings files without the key keep the default.
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.foldersFirst)
    }
}
