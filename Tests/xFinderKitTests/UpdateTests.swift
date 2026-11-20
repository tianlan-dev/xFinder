import XCTest
@testable import xFinderKit

final class UpdateTests: XCTestCase {
    func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testVersionParsingAndOrdering() {
        XCTAssertEqual(v("v0.0.1"), SemanticVersion(major: 0, minor: 0, patch: 1))
        XCTAssertEqual(v("1.2"), SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(v("1.2.3+build.5"), v("1.2.3"))
        XCTAssertNil(SemanticVersion("v.0.0.1"))
        XCTAssertNil(SemanticVersion("1.x.0"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertLessThan(v("0.0.1"), v("0.0.2"))
        XCTAssertLessThan(v("0.9.9"), v("0.10.0"))
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0-beta.10"))
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-beta"))
        XCTAssertLessThan(v("1.0.0-rc.1"), v("1.0.0"))
        XCTAssertEqual(v("v2.0.0").description, "2.0.0")
    }

    func release(_ tag: String, assets: [String], draft: Bool = false, prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(tagName: tag, body: "Notes", draft: draft, prerelease: prerelease,
                      assets: assets.map { GitHubRelease.Asset(name: $0, size: 10, browserDownloadURL: URL(string: "https://example.com/\($0)")!) })
    }

    func testAvailableUpdateSelection() {
        let r = release("v0.0.2", assets: ["xFinder-0.0.2.dmg", "xFinder-0.0.2.zip", "SHA256SUMS.txt"])
        let u = UpdateCatalog.availableUpdate(r, currentVersion: "0.0.1")
        XCTAssertEqual(u?.zip.name, "xFinder-0.0.2.zip")
        XCTAssertEqual(u?.checksums?.name, "SHA256SUMS.txt")
        XCTAssertEqual(u?.notes, "Notes")
        XCTAssertNil(UpdateCatalog.availableUpdate(r, currentVersion: "0.0.2"))
        XCTAssertNil(UpdateCatalog.availableUpdate(r, currentVersion: "1.0.0"))
        XCTAssertNil(UpdateCatalog.availableUpdate(r, currentVersion: "0.0.1", skippedVersion: "0.0.2"))
        XCTAssertNotNil(UpdateCatalog.availableUpdate(r, currentVersion: "0.0.1", skippedVersion: "0.0.1"))
        XCTAssertNotNil(UpdateCatalog.availableUpdate(r, currentVersion: "garbage"))
        XCTAssertNil(UpdateCatalog.availableUpdate(release("v0.0.2", assets: ["xFinder-0.0.2.dmg"]), currentVersion: "0.0.1"))
        XCTAssertNil(UpdateCatalog.availableUpdate(release("v0.0.2", assets: ["xFinder-0.0.2.zip"], draft: true), currentVersion: "0.0.1"))
        XCTAssertNil(UpdateCatalog.availableUpdate(release("v0.0.2", assets: ["xFinder-0.0.2.zip"], prerelease: true), currentVersion: "0.0.1"))
        XCTAssertNil(UpdateCatalog.availableUpdate(release("nightly", assets: ["xFinder-0.0.2.zip"]), currentVersion: "0.0.1"))
    }

    func testZipAndChecksumAssetFallbacks() {
        let r = release("v1.0.0", assets: ["notes.zip", "xFinder-universal.zip", "xFinder-universal.zip.sha256", "SHA256SUMS.txt"])
        let u = UpdateCatalog.availableUpdate(r, currentVersion: "0.0.1")
        XCTAssertEqual(u?.zip.name, "xFinder-universal.zip")
        XCTAssertEqual(u?.checksums?.name, "xFinder-universal.zip.sha256")
    }

    func testChecksumParsing() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let text = "\(a)  xFinder-0.0.1.dmg\n\(b) *dist/xFinder-0.0.1.zip\nbad line\n"
        XCTAssertEqual(UpdateCatalog.checksum(for: "xFinder-0.0.1.zip", in: text), b.lowercased())
        XCTAssertEqual(UpdateCatalog.checksum(for: "xFinder-0.0.1.dmg", in: text), a)
        XCTAssertNil(UpdateCatalog.checksum(for: "other.zip", in: text))
        XCTAssertNil(UpdateCatalog.checksum(for: "x.zip", in: "short  x.zip"))
    }

    func testDecodesGitHubReleaseJSON() throws {
        let json = """
        {"tag_name":"v0.0.1","name":"xFinder 0.0.1","body":"First release","html_url":"https://github.com/tianlan-dev/xFinder/releases/tag/v0.0.1",
         "draft":false,"prerelease":false,"published_at":"2026-11-20T18:00:00Z",
         "assets":[{"name":"xFinder-0.0.1.zip","size":123,"browser_download_url":"https://github.com/tianlan-dev/xFinder/releases/download/v0.0.1/xFinder-0.0.1.zip","digest":"sha256:\(String(repeating: "0", count: 64))"}]}
        """
        let r = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertEqual(r.version, SemanticVersion(major: 0, minor: 0, patch: 1))
        XCTAssertEqual(r.assets.first?.size, 123)
        XCTAssertEqual(r.assets.first?.digest?.hasPrefix("sha256:"), true)
        XCTAssertEqual(UpdateFeed().latestReleaseURL.absoluteString, "https://api.github.com/repos/tianlan-dev/xFinder/releases/latest")
    }

    func testCheckSchedule() {
        let now = Date()
        XCTAssertTrue(UpdateCatalog.isCheckDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCatalog.isCheckDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateCatalog.isCheckDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertTrue(UpdateCatalog.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    /// Runs the swap script against throwaway bundles (no admin, no real app).
    func testSwapScriptReplacesBundleAndKeepsNothingBehind() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xf-swap-\(UUID().uuidString)")
        let work = root.appendingPathComponent("work")
        let old = root.appendingPathComponent("Apps/My App.app")
        let new = work.appendingPathComponent("unpacked/My App.app")
        for d in [old, new] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("old".utf8).write(to: old.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: new.appendingPathComponent("marker"))
        defer { try? fm.removeItem(at: root) }

        let installer = UpdateInstaller(appURL: old, bundleIdentifier: "x")
        var script = installer.swapScript(PreparedUpdate(newApp: new, workDirectory: work, version: v("1.0.0")),
                                          pid: 999_999, asAdmin: false)
        // Do not actually open anything in the test.
        script = script.replacingOccurrences(of: "/usr/bin/open", with: "true").replacingOccurrences(of: "sleep 3;", with: "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: old.path + ".xfinder-backup"))
        XCTAssertFalse(fm.fileExists(atPath: work.path))
    }

    func testAdminScriptWrapsSwapInOsascript() {
        let installer = UpdateInstaller(appURL: URL(fileURLWithPath: "/Applications/xFinder.app"), bundleIdentifier: "x")
        let s = installer.swapScript(PreparedUpdate(newApp: URL(fileURLWithPath: "/tmp/w/xFinder.app"),
                                                    workDirectory: URL(fileURLWithPath: "/tmp/w"), version: v("1.0.0")),
                                     pid: 1, asAdmin: true)
        XCTAssertTrue(s.contains("with administrator privileges"))
        XCTAssertTrue(s.contains("/usr/bin/osascript"))
    }
}
