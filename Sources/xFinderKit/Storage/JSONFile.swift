import Foundation

/// Reading and writing JSON data files.
///
/// Files are written pretty-printed with sorted keys, atomically, with 0600
/// permissions.
public enum JSONFile {
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encode(value)
        try writeAtomically(data, to: url)
    }

    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fm = FileManager.default
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RemoteError.localIO("Could not write \(url.path)")
        }
        do {
            if rename(tmp.path, url.path) != 0 {
                throw RemoteError.localIO("Could not replace \(url.path): \(String(cString: strerror(errno)))")
            }
            chmod(url.path, 0o600)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Loads a value; returns nil when the file does not exist.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try makeDecoder().decode(T.self, from: data)
    }
}
