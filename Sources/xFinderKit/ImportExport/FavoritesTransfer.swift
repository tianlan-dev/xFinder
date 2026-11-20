import Foundation

/// Import result shown to the user.
public struct ImportReport: Sendable, Equatable {
    public var sitesAdded = 0
    public var foldersAdded = 0
    public var keysAdded = 0
    public var accountsAdded = 0
    public var bookmarksAdded = 0
    public var notes: [String] = []
    public var skipped: [String] = []

    public init() {}

    public var summary: String {
        var parts: [String] = []
        if sitesAdded > 0 { parts.append("\(sitesAdded) server\(sitesAdded == 1 ? "" : "s")") }
        if foldersAdded > 0 { parts.append("\(foldersAdded) folder\(foldersAdded == 1 ? "" : "s")") }
        if keysAdded > 0 { parts.append("\(keysAdded) key\(keysAdded == 1 ? "" : "s")") }
        if accountsAdded > 0 { parts.append("\(accountsAdded) account\(accountsAdded == 1 ? "" : "s")") }
        if bookmarksAdded > 0 { parts.append("\(bookmarksAdded) bookmark\(bookmarksAdded == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing was imported." : "Imported " + parts.joined(separator: ", ") + "."
    }
}

/// "xFinder Favorites" v1 export/import. Passwords are never included.
public enum FavoritesTransfer {
    public static let formatName = "xFinder Favorites"
    public static let version = 1

    struct ExportedKey: Codable { var id: UUID; var alias: String; var path: String }
    struct ExportedAccount: Codable {
        var id: UUID; var name: String; var username: String
        var keyID: UUID?; var usePassword: Bool; var authOrder: AuthOrder?
    }
    struct Document: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var folders: [SiteFolder]
        var sites: [Site]
        var order: [LibraryItemRef]
        var globalBookmarks: [Bookmark]
        var keys: [ExportedKey]
        var accounts: [ExportedAccount]
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func export(library: SiteLibrary, keys: KeyLibrary, accounts: AccountStore) throws -> Data {
        var usedKeys = Set<UUID>()
        var usedAccounts = Set<UUID>()
        for s in library.sites {
            if let k = s.key.keyID { usedKeys.insert(k) }
            if let a = s.accountID { usedAccounts.insert(a) }
        }
        for f in library.folders {
            if let k = f.key.keyID { usedKeys.insert(k) }
            if let a = f.accountID { usedAccounts.insert(a) }
        }
        let exportedAccounts = accounts.accounts.filter { usedAccounts.contains($0.id) }
        for a in exportedAccounts { if let k = a.key.keyID { usedKeys.insert(k) } }
        let doc = Document(format: formatName, version: version, exportedAt: Date(),
                           folders: library.folders, sites: library.sites, order: library.topLevel,
                           globalBookmarks: library.globalBookmarks,
                           keys: keys.keys.filter { usedKeys.contains($0.id) }.map { ExportedKey(id: $0.id, alias: $0.alias, path: $0.path) },
                           accounts: exportedAccounts.map {
                               ExportedAccount(id: $0.id, name: $0.name, username: $0.username, keyID: $0.key.keyID,
                                               usePassword: $0.usePassword, authOrder: $0.authOrder)
                           })
        return try encoder().encode(doc)
    }

    /// Adds the document's content; existing entries are never modified.
    public static func importData(_ data: Data, library: inout SiteLibrary, keys: inout KeyLibrary,
                                  accounts: inout AccountStore,
                                  fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) })
    throws -> ImportReport {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let doc: Document
        do { doc = try d.decode(Document.self, from: data) } catch {
            throw RemoteError.invalidResponse("This is not an xFinder Favorites file.")
        }
        guard doc.format == formatName else { throw RemoteError.invalidResponse("This is not an xFinder Favorites file.") }
        guard doc.version <= version else { throw RemoteError.unsupported("The file was made by a newer version of xFinder.") }
        var report = ImportReport()

        // Keys: match by path; add when the file exists here; otherwise fall back to Inherit.
        var keyMap: [UUID: UUID] = [:]
        var missingKeys: [UUID: String] = [:]
        for k in doc.keys {
            if let existing = keys.key(atPath: k.path) {
                keyMap[k.id] = existing.id
            } else if fileExists(k.path) {
                let added = keys.add(path: k.path, alias: k.alias)
                keyMap[k.id] = added.id
                report.keysAdded += 1
            } else {
                missingKeys[k.id] = "\(k.alias) (\(k.path))"
            }
        }
        func mapKey(_ choice: KeyChoice, owner: String) -> KeyChoice {
            guard case .key(let id) = choice else { return choice }
            if let m = keyMap[id] { return .key(m) }
            report.notes.append("\(owner): key \(missingKeys[id] ?? id.uuidString) was not found on this Mac; using Inherit.")
            return .inherit
        }

        // Accounts: match by name (case-insensitive) + username, else create without password.
        var accountMap: [UUID: UUID] = [:]
        for a in doc.accounts {
            if let existing = accounts.match(name: a.name, username: a.username) {
                accountMap[a.id] = existing.id
            } else {
                var key: KeyChoice = .none
                if let k = a.keyID {
                    key = mapKey(.key(k), owner: "Account \(a.name)")
                    if key == .inherit { key = .none }
                }
                let added = accounts.add(Account(name: a.name, username: a.username, key: key,
                                                 usePassword: a.usePassword || key == .none, authOrder: a.authOrder))
                accountMap[a.id] = added.id
                report.accountsAdded += 1
            }
        }

        // Folders with fresh IDs and unique names.
        var folderMap: [UUID: UUID] = [:]
        for f in doc.folders {
            var nf = f
            nf.id = UUID()
            nf.name = library.uniqueFolderName(f.name)
            nf.siteIDs = []
            nf.key = mapKey(f.key, owner: "Folder \(f.name)")
            nf.accountID = f.accountID.flatMap { accountMap[$0] }
            nf.bookmarks = f.bookmarks.map { Bookmark(name: $0.name, path: $0.path) }
            library.addFolder(nf)
            folderMap[f.id] = nf.id
            report.foldersAdded += 1
        }

        // Sites in exported order.
        let ordered = orderedSites(doc)
        for s in ordered {
            var ns = s
            ns.id = UUID()
            ns.name = library.uniqueSiteName(s.name.isEmpty ? s.host : s.name)
            ns.folderID = s.folderID.flatMap { folderMap[$0] }
            ns.key = mapKey(s.key, owner: "Server \(s.displayName)")
            ns.accountID = s.accountID.flatMap { accountMap[$0] }
            ns.bookmarks = s.bookmarks.map { Bookmark(name: $0.name, path: $0.path) }
            library.addSite(ns)
            report.sitesAdded += 1
        }

        let existingGlobal = Set(library.globalBookmarks.map(\.path))
        for b in doc.globalBookmarks where !existingGlobal.contains(b.path) {
            library.globalBookmarks.append(Bookmark(name: b.name, path: b.path))
            report.bookmarksAdded += 1
        }
        return report
    }

    static func orderedSites(_ doc: Document) -> [Site] {
        var result: [Site] = []
        var seen = Set<UUID>()
        let byID = Dictionary(doc.sites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for f in doc.folders {
            for id in f.siteIDs { if let s = byID[id], seen.insert(id).inserted { result.append(s) } }
        }
        for ref in doc.order { if case .site(let id) = ref, let s = byID[id], seen.insert(id).inserted { result.append(s) } }
        for s in doc.sites where seen.insert(s.id).inserted { result.append(s) }
        return result
    }
}
