import Foundation

/// "xFinder Settings" export: preferences, Open With rules, keys and accounts.
/// Passwords, favorites and trusted host keys are never included.
public enum SettingsTransfer {
    public static let formatName = "xFinder Settings"
    public static let version = 1

    struct Document: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var settings: AppSettings
        var keys: [SSHKeyEntry]
        var accounts: [Account]
    }

    public static func export(settings: AppSettings, keys: KeyLibrary, accounts: AccountStore) throws -> Data {
        var s = settings
        s.updates.lastCheck = nil
        s.updates.skippedVersion = nil
        let doc = Document(format: formatName, version: version, exportedAt: Date(), settings: s, keys: keys.keys,
                           accounts: accounts.accounts)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(doc)
    }

    public struct Preview: Sendable {
        public var settings: AppSettings
        public var keyCount: Int
        public var accountCount: Int
        fileprivate var doc: Document
    }

    public static func read(_ data: Data) throws -> Preview {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let doc = try? d.decode(Document.self, from: data), doc.format == formatName else {
            throw RemoteError.invalidResponse("This is not an xFinder Settings file.")
        }
        guard doc.version <= version else { throw RemoteError.unsupported("The file was made by a newer version of xFinder.") }
        return Preview(settings: doc.settings, keyCount: doc.keys.count, accountCount: doc.accounts.count, doc: doc)
    }

    /// Replaces preferences (after the user confirmed) and merges keys and accounts.
    public static func apply(_ preview: Preview, settings: inout AppSettings, keys: inout KeyLibrary,
                             accounts: inout AccountStore, fileManager: FileManager = .default) -> ImportReport {
        var report = ImportReport()
        var keyMap: [UUID: UUID] = [:]
        for k in preview.doc.keys {
            if let existing = keys.key(atPath: k.path) { keyMap[k.id] = existing.id } else {
                keyMap[k.id] = keys.add(path: k.path, alias: k.alias).id
                report.keysAdded += 1
            }
        }
        for a in preview.doc.accounts {
            if accounts.match(name: a.name, username: a.username) != nil { continue }
            var na = a
            na.id = UUID()
            if let k = a.key.keyID { na.key = keyMap[k].map { .key($0) } ?? .none }
            accounts.add(na)
            report.accountsAdded += 1
        }
        let localUpdates = settings.updates
        var s = preview.settings
        s.updates = UpdatePreferences(automaticallyCheck: s.updates.automaticallyCheck, lastCheck: localUpdates.lastCheck,
                                      skippedVersion: localUpdates.skippedVersion)
        s.defaultKeyID = s.defaultKeyID.flatMap { keyMap[$0] }
        s.sanitize(fileManager: fileManager)
        settings = s
        return report
    }
}
