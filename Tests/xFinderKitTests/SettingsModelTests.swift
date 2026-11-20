import XCTest
@testable import xFinderKit

final class SettingsInheritanceTests: XCTestCase {
    var keys = KeyLibrary()
    var accounts = AccountStore()
    var library = SiteLibrary()
    var settings = AppSettings()
    var k1: SSHKeyEntry!, k2: SSHKeyEntry!, k3: SSHKeyEntry!

    override func setUp() {
        keys = KeyLibrary()
        k1 = keys.add(path: "/tmp/k1")
        k2 = keys.add(path: "/tmp/k2")
        k3 = keys.add(path: "/tmp/k3")
        settings = AppSettings()
        settings.defaultKeyID = k1.id
        settings.defaultAuthOrder = .keyFirst
    }

    func resolver() -> SiteSettingsResolver {
        SiteSettingsResolver(library: library, keys: keys, accounts: accounts, settings: settings, localUserName: "local")
    }

    func testUsernameFallsBackToFolderThenLocalUserForSSHOnly() {
        var folder = SiteFolder(name: "F", username: "folderuser")
        library.addFolder(folder)
        let s1 = Site(name: "a", host: "a.example", folderID: folder.id)
        library.addSite(s1)
        XCTAssertEqual(resolver().resolve(s1).username, "folderuser")

        folder.username = ""
        library.updateFolder(folder)
        XCTAssertEqual(resolver().resolve(s1).username, "local")

        let ftp = Site(name: "f", protocolType: .ftp, host: "f.example")
        library.addSite(ftp)
        XCTAssertEqual(resolver().resolve(ftp).username, "")

        let own = Site(name: "o", host: "o.example", username: "me", folderID: folder.id)
        library.addSite(own)
        XCTAssertEqual(resolver().resolve(own).username, "me")
    }

    func testKeyInheritance() {
        let folder = SiteFolder(name: "F", key: .key(k2.id))
        library.addFolder(folder)
        let inFolder = Site(name: "a", host: "a", key: .inherit, folderID: folder.id)
        let explicit = Site(name: "b", host: "b", key: .key(k3.id), folderID: folder.id)
        let noKey = Site(name: "c", host: "c", key: .none, folderID: folder.id)
        let top = Site(name: "d", host: "d", key: .inherit)
        for s in [inFolder, explicit, noKey, top] { library.addSite(s) }
        let r = resolver()
        XCTAssertEqual(r.resolve(inFolder).key?.id, k2.id)
        XCTAssertEqual(r.resolve(explicit).key?.id, k3.id)
        XCTAssertNil(r.resolve(noKey).key)
        XCTAssertEqual(r.resolve(top).key?.id, k1.id)

        var noneFolder = folder
        noneFolder.key = .none
        library.updateFolder(noneFolder)
        XCTAssertNil(resolver().resolve(inFolder).key)
    }

    func testAuthOrderInheritance() {
        let folder = SiteFolder(name: "F", authOrder: .passwordFirst)
        library.addFolder(folder)
        let a = Site(name: "a", host: "a", folderID: folder.id)
        let b = Site(name: "b", host: "b", authOrder: .keyFirst, folderID: folder.id)
        let c = Site(name: "c", host: "c")
        for s in [a, b, c] { library.addSite(s) }
        XCTAssertEqual(resolver().resolve(a).authOrder, .passwordFirst)
        XCTAssertEqual(resolver().resolve(b).authOrder, .keyFirst)
        XCTAssertEqual(resolver().resolve(c).authOrder, .keyFirst)
    }

    func testAccountOverridesUsernameAndKey() {
        let acc = accounts.add(Account(name: "Deploy", username: "deploy", key: .key(k3.id), usePassword: false))
        let s = Site(name: "a", host: "a", username: "ignored", key: .key(k2.id), accountID: acc.id)
        library.addSite(s)
        let r = resolver().resolve(s)
        XCTAssertEqual(r.username, "deploy")
        XCTAssertEqual(r.key?.id, k3.id)
        XCTAssertTrue(r.keyOnly)
        XCTAssertFalse(r.allowsPassword)
        XCTAssertEqual(r.passwordKeychainAccount, KeychainAccountName.accountPassword(acc.id))
    }

    func testFolderAccountOnlyWhenSiteHasNoUsername() {
        let acc = accounts.add(Account(name: "Ops", username: "ops", key: .none, usePassword: true))
        let folder = SiteFolder(name: "F", accountID: acc.id)
        library.addFolder(folder)
        let plain = Site(name: "a", host: "a", folderID: folder.id)
        let named = Site(name: "b", host: "b", username: "root", folderID: folder.id)
        library.addSite(plain)
        library.addSite(named)
        XCTAssertEqual(resolver().resolve(plain).username, "ops")
        XCTAssertEqual(resolver().resolve(plain).account?.id, acc.id)
        XCTAssertFalse(resolver().resolve(plain).keyOnly)
        XCTAssertNil(resolver().resolve(named).account)
        XCTAssertEqual(resolver().resolve(named).passwordKeychainAccount, KeychainAccountName.sitePassword(named.id))
    }

    func testAccountNamesAreUnique() {
        let a = accounts.add(Account(name: "Same", username: "x"))
        let b = accounts.add(Account(name: "Same", username: "y"))
        XCTAssertNotEqual(a.name, b.name)
        XCTAssertEqual(accounts.match(name: "Same", username: "x")?.id, a.id)
        XCTAssertNil(accounts.match(name: "Same", username: "nobody"))
    }

    func testKeyUsagesAndReplacement() {
        let folder = SiteFolder(name: "F", key: .key(k2.id))
        library.addFolder(folder)
        let s = Site(name: "a", host: "a", key: .key(k2.id))
        library.addSite(s)
        XCTAssertEqual(library.usages(ofKey: k2.id).sites.count, 1)
        XCTAssertEqual(library.usages(ofKey: k2.id).folders.count, 1)
        library.replaceKey(k2.id, with: .inherit)
        XCTAssertEqual(library.site(s.id)?.key, .inherit)
        XCTAssertEqual(library.folder(folder.id)?.key, .inherit)
        XCTAssertTrue(library.usages(ofKey: k2.id).sites.isEmpty)
    }
}

final class SiteLibraryTests: XCTestCase {
    func testAddMoveRemoveAndUniqueNames() {
        var lib = SiteLibrary()
        let f = SiteFolder(name: "Work")
        lib.addFolder(f)
        let a = Site(name: "Alpha", host: "a")
        let b = Site(name: "Beta", host: "b", folderID: f.id)
        lib.addSite(a)
        lib.addSite(b)
        XCTAssertEqual(lib.sites(inFolder: f.id).map(\.id), [b.id])
        XCTAssertEqual(lib.uniqueSiteName("Alpha"), "Alpha (2)")
        XCTAssertEqual(lib.uniqueFolderName("Work"), "Work (2)")

        lib.move([.site(a.id)], toFolder: f.id, at: 0)
        XCTAssertEqual(lib.sites(inFolder: f.id).map(\.id), [a.id, b.id])
        XCTAssertEqual(lib.site(a.id)?.folderID, f.id)

        let dup = lib.duplicateSite(a.id)
        XCTAssertNotNil(dup)
        XCTAssertNotEqual(dup?.id, a.id)
        XCTAssertNotEqual(dup?.name, "Alpha")

        let removed = lib.removeFolder(f.id, keepSites: true)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertNil(lib.folder(f.id))
        XCTAssertNil(lib.site(a.id)?.folderID)
        XCTAssertEqual(lib.sites.count, 3)

        _ = lib.removeSites([a.id, b.id])
        XCTAssertEqual(lib.sites.count, 1)
    }

    func testSearchAndSort() {
        var lib = SiteLibrary()
        lib.addSite(Site(name: "zeta", host: "z.example.com"))
        lib.addSite(Site(name: "Alpha", host: "web.example.com"))
        lib.addSite(Site(name: "file10", host: "x"))
        lib.addSite(Site(name: "file9", host: "y"))
        XCTAssertEqual(lib.search("web").map(\.name), ["Alpha"])
        lib.sortByName(.topLevel)
        XCTAssertEqual(lib.topLevel.map { lib.displayName(of: $0) }, ["Alpha", "file9", "file10", "zeta"])
    }

    func testRoundTripThroughJSON() throws {
        var lib = SiteLibrary()
        let f = SiteFolder(name: "F", username: "u")
        lib.addFolder(f)
        lib.addSite(Site(name: "S3", protocolType: .s3, host: "", s3Bucket: "bucket", s3Region: "eu-west-1"))
        lib.addSite(Site(name: "A", host: "a", port: 2222, folderID: f.id))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xf-lib-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try lib.save(to: url)
        let loaded = try SiteLibrary.load(from: url)
        XCTAssertEqual(loaded, lib)
    }
}

final class ValidationTests: XCTestCase {
    func testHosts() {
        for ok in ["example.com", "a-b.example.com.", "192.168.1.1", "::1", "[fe80::1%en0]", "my_host", "localhost"] {
            XCTAssertNil(SiteValidation.validateHost(ok), ok)
        }
        for bad in ["", "-oProxyCommand=x", "a b", "a..b", "-a.com", "a-.com", "ex$ample.com",
                    String(repeating: "a", count: 64) + ".com"] {
            XCTAssertNotNil(SiteValidation.validateHost(bad), bad)
        }
    }

    func testPortsAndSites() {
        XCTAssertNil(SiteValidation.validatePort(nil))
        XCTAssertNil(SiteValidation.validatePort(65535))
        XCTAssertNotNil(SiteValidation.validatePort(0))
        XCTAssertNotNil(SiteValidation.validatePort(70000))
        XCTAssertTrue(SiteValidation.validate(Site(protocolType: .s3, host: "", s3Bucket: "b")).isEmpty)
        XCTAssertFalse(SiteValidation.validate(Site(protocolType: .s3, host: "")).isEmpty)
        XCTAssertFalse(SiteValidation.validate(Site(host: "")).isEmpty)
    }

    func testSettingsSanitize() {
        var s = AppSettings()
        s.maxConcurrentTransfers = 99
        s.downloadDirectory = "/definitely/not/here"
        s.sanitize()
        XCTAssertEqual(s.maxConcurrentTransfers, 8)
        XCTAssertEqual(s.downloadDirectory, AppSettings.defaultDownloadDirectory)
        s.maxConcurrentTransfers = 0
        s.sanitize()
        XCTAssertEqual(s.maxConcurrentTransfers, 1)
    }
}

final class OpenWithTests: XCTestCase {
    let rules = [
        OpenWithRule(kind: .fileType, pattern: "public.text", applicationPath: "/Applications/TextEdit.app"),
        OpenWithRule(kind: .extensions, pattern: "md, .JSON;yaml", applicationPath: "/Applications/Code.app"),
        OpenWithRule(kind: .extensions, pattern: "md", applicationPath: "/Applications/Second.app"),
        OpenWithRule(kind: .fileName, pattern: "Dockerfile", applicationPath: "/Applications/Docker.app"),
    ]

    func testPriorityAndOrder() {
        XCTAssertEqual(OpenWithResolver.rule(for: "dockerfile", rules: rules)?.applicationName, "Docker")
        XCTAssertEqual(OpenWithResolver.rule(for: "README.md", rules: rules)?.applicationName, "Code")
        XCTAssertEqual(OpenWithResolver.rule(for: "a.json", rules: rules)?.applicationName, "Code")
        XCTAssertEqual(OpenWithResolver.rule(for: "a.yaml", rules: rules)?.applicationName, "Code")
        XCTAssertEqual(OpenWithResolver.rule(for: "notes.txt", rules: rules)?.applicationName, "TextEdit")
        XCTAssertNil(OpenWithResolver.rule(for: "image.png", rules: rules))
        XCTAssertNil(OpenWithResolver.rule(for: "Makefile", rules: rules))
    }

    func testExtensionList() {
        XCTAssertEqual(rules[1].extensionList, ["md", "json", "yaml"])
    }
}
