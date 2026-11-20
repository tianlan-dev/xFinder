import XCTest
@testable import xFinderKit

final class FavoritesTransferTests: XCTestCase {
    func makeSource() -> (SiteLibrary, KeyLibrary, AccountStore) {
        var keys = KeyLibrary()
        let present = keys.add(path: "/keys/present", alias: "Present")
        let missing = keys.add(path: "/keys/missing", alias: "Missing")
        _ = keys.add(path: "/keys/unused", alias: "Unused")
        var accounts = AccountStore()
        let acc = accounts.add(Account(name: "Deploy", username: "deploy", key: .key(present.id)))
        var lib = SiteLibrary()
        let f = SiteFolder(name: "Prod", key: .key(missing.id))
        lib.addFolder(f)
        lib.addSite(Site(name: "web", host: "web.example.com", folderID: f.id, accountID: acc.id))
        lib.addSite(Site(name: "db", host: "db.example.com", port: 2200, key: .key(missing.id)))
        return (lib, keys, accounts)
    }

    func testExportContainsOnlyUsedKeysAndNoSecrets() throws {
        let (lib, keys, accounts) = makeSource()
        let data = try FavoritesTransfer.export(library: lib, keys: keys, accounts: accounts)
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(text.contains("xFinder Favorites"))
        XCTAssertTrue(text.contains("/keys/present"))
        XCTAssertFalse(text.contains("/keys/unused"))
        XCTAssertFalse(text.contains("\"password\""))
        XCTAssertFalse(text.contains("passphrase"))
    }

    func testImportIntoEmptyLibrary() throws {
        let (lib, keys, accounts) = makeSource()
        let data = try FavoritesTransfer.export(library: lib, keys: keys, accounts: accounts)
        var newLib = SiteLibrary(), newKeys = KeyLibrary(), newAccounts = AccountStore()
        let report = try FavoritesTransfer.importData(data, library: &newLib, keys: &newKeys, accounts: &newAccounts,
                                                      fileExists: { $0 == "/keys/present" })
        XCTAssertEqual(report.sitesAdded, 2)
        XCTAssertEqual(report.foldersAdded, 1)
        XCTAssertEqual(report.keysAdded, 1)
        XCTAssertEqual(report.accountsAdded, 1)
        XCTAssertFalse(report.notes.isEmpty, "missing keys are reported")
        XCTAssertEqual(newKeys.keys.map(\.path), ["/keys/present"])
        let db = try XCTUnwrap(newLib.sites.first { $0.host == "db.example.com" })
        XCTAssertEqual(db.key, .inherit)
        XCTAssertEqual(db.port, 2200)
        XCTAssertEqual(newLib.folders.first?.key, .inherit)
        let web = try XCTUnwrap(newLib.sites.first { $0.host == "web.example.com" })
        XCTAssertEqual(newAccounts.account(web.accountID)?.username, "deploy")
        XCTAssertEqual(newAccounts.account(web.accountID)?.key.keyID, newKeys.keys.first?.id)
        // New identities, so importing twice never collides.
        XCTAssertFalse(lib.sites.map(\.id).contains(web.id))
    }

    func testImportTwiceMergesKeysAndAccountsButRenamesSites() throws {
        let (lib, keys, accounts) = makeSource()
        let data = try FavoritesTransfer.export(library: lib, keys: keys, accounts: accounts)
        var l = SiteLibrary(), k = KeyLibrary(), a = AccountStore()
        _ = try FavoritesTransfer.importData(data, library: &l, keys: &k, accounts: &a, fileExists: { _ in true })
        _ = try FavoritesTransfer.importData(data, library: &l, keys: &k, accounts: &a, fileExists: { _ in true })
        XCTAssertEqual(l.sites.count, 4)
        XCTAssertEqual(Set(l.sites.map(\.name)).count, 4)
        XCTAssertEqual(k.keys.count, 2)
        XCTAssertEqual(a.accounts.count, 1)
    }

    func testRejectsOtherFiles() {
        var l = SiteLibrary(), k = KeyLibrary(), a = AccountStore()
        XCTAssertThrowsError(try FavoritesTransfer.importData(Data("{\"format\":\"other\"}".utf8), library: &l, keys: &k, accounts: &a))
        XCTAssertThrowsError(try FavoritesTransfer.importData(Data("nope".utf8), library: &l, keys: &k, accounts: &a))
    }
}

final class SettingsTransferTests: XCTestCase {
    func testRoundTripKeepsLocalUpdateStateAndRemapsDefaultKey() throws {
        var keys = KeyLibrary()
        let k = keys.add(path: "/keys/a", alias: "A")
        var accounts = AccountStore()
        _ = accounts.add(Account(name: "Ops", username: "ops"))
        var s = AppSettings()
        s.maxConcurrentTransfers = 5
        s.defaultKeyID = k.id
        s.terminalApp = .ghostty
        s.openWithRules = [OpenWithRule(kind: .extensions, pattern: "md", applicationPath: "/Applications/X.app")]
        s.updates.skippedVersion = "9.9.9"
        let data = try SettingsTransfer.export(settings: s, keys: keys, accounts: accounts)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("xFinder Settings"))

        let preview = try SettingsTransfer.read(data)
        XCTAssertEqual(preview.keyCount, 1)
        XCTAssertEqual(preview.accountCount, 1)

        var target = AppSettings()
        target.updates.lastCheck = Date(timeIntervalSince1970: 1000)
        target.updates.skippedVersion = "1.2.3"
        var tKeys = KeyLibrary()
        let existing = tKeys.add(path: "/keys/a", alias: "Mine")
        var tAccounts = AccountStore()
        _ = SettingsTransfer.apply(preview, settings: &target, keys: &tKeys, accounts: &tAccounts)
        XCTAssertEqual(target.maxConcurrentTransfers, 5)
        XCTAssertEqual(target.terminalApp, .ghostty)
        XCTAssertEqual(target.openWithRules.count, 1)
        XCTAssertEqual(target.defaultKeyID, existing.id, "default key is remapped by path")
        XCTAssertEqual(tKeys.keys.count, 1)
        XCTAssertEqual(tKeys.keys.first?.alias, "Mine", "existing keys stay unchanged")
        XCTAssertEqual(target.updates.lastCheck, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(target.updates.skippedVersion, "1.2.3")
        XCTAssertEqual(tAccounts.accounts.map(\.name), ["Ops"])
    }

    func testRejectsFavoritesFile() throws {
        let fav = try FavoritesTransfer.export(library: SiteLibrary(), keys: KeyLibrary(), accounts: AccountStore())
        XCTAssertThrowsError(try SettingsTransfer.read(fav))
    }
}

final class SSHConfigImporterTests: XCTestCase {
    let config = """
    # comment
    Host *
        User everyone
    Host web web-alias
        HostName web.example.com
        Port 2222
        User deploy
        IdentityFile ~/.ssh/id_web
    Host db
        HostName=%h.internal
        IdentityFile "~/.ssh/missing key"
    Host !bad *.wild
        User x
    Match host foo
        User matched
    Host plain
    """

    func testParse() {
        let entries = SSHConfigImporter.parse(config)
        XCTAssertEqual(entries.map(\.alias), ["web", "web-alias", "db", "plain"])
        XCTAssertEqual(entries[0].hostName, "web.example.com")
        XCTAssertEqual(entries[0].port, 2222)
        XCTAssertEqual(entries[0].user, "deploy")
        XCTAssertEqual(entries[0].identityFile, "~/.ssh/id_web")
        XCTAssertEqual(entries[2].hostName, "%h.internal")
        XCTAssertEqual(entries[2].identityFile, "~/.ssh/missing key")
        XCTAssertNil(entries[3].user)
    }

    func testImport() {
        var lib = SiteLibrary(), keys = KeyLibrary()
        let entries = SSHConfigImporter.parse(config)
        let r = SSHConfigImporter.importEntries(entries, library: &lib, keys: &keys, home: "/Users/t",
                                                fileExists: { $0 == "/Users/t/.ssh/id_web" })
        XCTAssertEqual(r.sitesAdded, 4)
        XCTAssertEqual(r.foldersAdded, 1)
        XCTAssertEqual(r.keysAdded, 1)
        XCTAssertEqual(lib.folders.first?.name, SSHConfigImporter.folderName)
        let web = lib.sites.first { $0.sshConfigAlias == "web" }!
        XCTAssertEqual(web.host, "web.example.com")
        XCTAssertEqual(web.port, 2222)
        XCTAssertEqual(keys.key(web.key.keyID)?.path, "/Users/t/.ssh/id_web")
        let alias = lib.sites.first { $0.sshConfigAlias == "web-alias" }!
        XCTAssertEqual(alias.key, web.key, "same key file is added once")
        XCTAssertEqual(lib.sites.first { $0.sshConfigAlias == "db" }?.host, "db.internal")
        XCTAssertEqual(lib.sites.first { $0.sshConfigAlias == "db" }?.key, .inherit)

        let again = SSHConfigImporter.importEntries(entries, library: &lib, keys: &keys, home: "/Users/t", fileExists: { _ in true })
        XCTAssertEqual(again.sitesAdded, 0)
        XCTAssertEqual(again.skipped.count, 4)
        XCTAssertEqual(lib.folders.count, 1)
    }
}

final class TransmitImporterTests: XCTestCase {
    func testPlist() throws {
        let doc: [String: Any] = [
            "children": [
                ["name": "Work", "children": [
                    ["nickname": "Web", "server": "web.example.com", "protocol": "SFTP", "port": 0, "username": "deploy", "remotePath": "/var/www"],
                    ["name": "Clients", "children": [
                        ["nickname": "FTP box", "server": "ftp.example.com", "protocol": "FTP", "port": 2121, "username": "u"],
                    ]],
                ]],
                ["nickname": "Bucket", "server": "s3.amazonaws.com", "protocol": "S3"],
                ["nickname": "Loose", "address": "10.0.0.1", "protocol": "SFTP", "port": "22"],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: doc, format: .xml, options: 0)
        let parsed = try TransmitImporter.parse(data)
        XCTAssertEqual(parsed.servers.map(\.name), ["Web", "FTP box", "Loose"])
        XCTAssertEqual(parsed.servers[1].folderPath, ["Work", "Clients"])
        XCTAssertEqual(parsed.skipped.count, 1)

        var lib = SiteLibrary()
        let r = TransmitImporter.importServers(parsed, library: &lib)
        XCTAssertEqual(r.sitesAdded, 3)
        XCTAssertEqual(Set(lib.folders.map(\.name)), ["Work", "Work / Clients"])
        let web = lib.sites.first { $0.name == "Web" }!
        XCTAssertNil(web.port)
        XCTAssertEqual(web.initialPath, "/var/www")
        XCTAssertEqual(lib.sites.first { $0.name == "FTP box" }?.port, 2121)
        XCTAssertEqual(lib.sites.first { $0.name == "FTP box" }?.protocolType, .ftp)
        XCTAssertNil(lib.sites.first { $0.name == "Loose" }?.folderID)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try TransmitImporter.parse(Data("garbage".utf8)))
    }
}
