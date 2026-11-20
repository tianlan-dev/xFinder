import Foundation

/// Registered SSH keys (`keys.json`). Only paths and aliases are stored; private
/// keys are never copied. Unregistered keys in `~/.ssh` are never tried.
public struct KeyLibrary: Codable, Hashable, Sendable {
    public var keys: [SSHKeyEntry]

    public init(keys: [SSHKeyEntry] = []) { self.keys = keys }

    public static func load(from url: URL) -> KeyLibrary {
        (try? JSONFile.load(KeyLibrary.self, from: url)) ?? KeyLibrary()
    }

    public func save(to url: URL) throws { try JSONFile.save(self, to: url) }

    public func key(_ id: UUID?) -> SSHKeyEntry? {
        guard let id else { return nil }
        return keys.first { $0.id == id }
    }

    public func key(atPath path: String) -> SSHKeyEntry? {
        let p = Self.canonicalPath(path)
        return keys.first { Self.canonicalPath($0.path) == p }
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// Adds a key (or returns the existing entry for the same path).
    @discardableResult
    public mutating func add(path: String, alias: String? = nil) -> SSHKeyEntry {
        if let existing = key(atPath: path) { return existing }
        let base = alias ?? URL(fileURLWithPath: path).lastPathComponent
        let name = SiteLibrary.uniqueName(base, existing: Set(keys.map { $0.alias.lowercased() }))
        let entry = SSHKeyEntry(alias: name, path: Self.abbreviate(path))
        keys.append(entry)
        return entry
    }

    public mutating func update(_ entry: SSHKeyEntry) {
        if let i = keys.firstIndex(where: { $0.id == entry.id }) { keys[i] = entry }
    }

    public mutating func remove(_ id: UUID) {
        keys.removeAll { $0.id == id }
    }

    /// Replaces the home directory prefix with `~`.
    public static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
