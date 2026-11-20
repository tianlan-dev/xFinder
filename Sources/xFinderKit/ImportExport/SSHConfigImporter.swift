import Foundation

/// Imports concrete `Host` entries from ~/.ssh/config.
public enum SSHConfigImporter {
    public static let folderName = "Imported from ssh config"

    public struct Entry: Equatable, Sendable {
        public var alias: String
        public var hostName: String?
        public var port: Int?
        public var user: String?
        public var identityFile: String?
    }

    /// Parses Host blocks; wildcard patterns and Match blocks are skipped.
    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var current: [Int] = []   // indices of entries the current block applies to
        var inMatch = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { continue }
            let (key, value) = splitKeyValue(line)
            switch key {
            case "host":
                inMatch = false
                current = []
                for pattern in tokens(value) {
                    if pattern.contains("*") || pattern.contains("?") || pattern.hasPrefix("!") { continue }
                    if entries.contains(where: { $0.alias == pattern }) { continue }
                    entries.append(Entry(alias: pattern))
                    current.append(entries.count - 1)
                }
            case "match":
                inMatch = true
                current = []
            default:
                guard !inMatch, !current.isEmpty else { continue }
                let v = tokens(value).first ?? value
                for i in current {
                    // ssh uses the first value it sees for each option.
                    switch key {
                    case "hostname": if entries[i].hostName == nil { entries[i].hostName = v }
                    case "port": if entries[i].port == nil { entries[i].port = Int(v) }
                    case "user": if entries[i].user == nil { entries[i].user = v }
                    case "identityfile": if entries[i].identityFile == nil { entries[i].identityFile = v }
                    default: break
                    }
                }
            }
        }
        return entries
    }

    static func splitKeyValue(_ line: String) -> (String, String) {
        // "Key value", "Key=value" or "Key = value"
        let idx = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) ?? line.endIndex
        let key = String(line[..<idx]).lowercased()
        var rest = line[idx...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (key, String(rest))
    }

    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        for c in s {
            if c == "\"" { quoted.toggle(); continue }
            if !quoted && (c == " " || c == "\t") {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else { cur.append(c) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Expands `~` and `%d` (home) in IdentityFile.
    static func expand(_ path: String, home: String) -> String {
        var p = path.replacingOccurrences(of: "%d", with: home)
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        return p
    }

    /// Adds new entries to the "Imported from ssh config" folder. Aliases already imported are skipped.
    public static func importEntries(_ entries: [Entry], library: inout SiteLibrary, keys: inout KeyLibrary,
                                     home: String = NSHomeDirectory(),
                                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ImportReport {
        var report = ImportReport()
        let existingAliases = Set(library.sites.compactMap(\.sshConfigAlias))
        var folderID = library.folders.first(where: { $0.name == folderName })?.id
        for e in entries {
            if existingAliases.contains(e.alias) { report.skipped.append("\(e.alias): already imported"); continue }
            let host = e.hostName.map { $0.replacingOccurrences(of: "%h", with: e.alias) } ?? e.alias
            if let problem = SiteValidation.validateHost(host) { report.skipped.append("\(e.alias): \(problem)"); continue }
            if folderID == nil {
                let f = SiteFolder(name: folderName)
                library.addFolder(f)
                folderID = f.id
                report.foldersAdded += 1
            }
            var site = Site(name: library.uniqueSiteName(e.alias), protocolType: .sftp, host: host,
                            port: e.port == 22 ? nil : e.port, username: e.user ?? "")
            site.folderID = folderID
            site.sshConfigAlias = e.alias
            if let idf = e.identityFile {
                let path = expand(idf, home: home)
                if let k = keys.key(atPath: path) {
                    site.key = .key(k.id)
                } else if fileExists(path) {
                    site.key = .key(keys.add(path: path).id)
                    report.keysAdded += 1
                } else {
                    report.notes.append("\(e.alias): IdentityFile \(idf) does not exist; using Inherit.")
                }
            }
            library.addSite(site)
            report.sitesAdded += 1
        }
        return report
    }
}
