import Foundation

public struct FTPReply: Equatable, Sendable {
    public var code: Int
    public var lines: [String]
    public var text: String { lines.joined(separator: "\n") }
    /// Message without the code prefixes.
    public var message: String {
        lines.map { l in
            let chars = Array(l)
            if chars.count >= 4, Int(String(chars[0..<3])) != nil, chars[3] == " " || chars[3] == "-" { return String(chars[4...]) }
            return l
        }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
    public var isPositivePreliminary: Bool { (100..<200).contains(code) }
    public var isSuccess: Bool { (200..<300).contains(code) }
    public var isIntermediate: Bool { (300..<400).contains(code) }
}

public enum FTPParsing {
    /// Tries to take one complete (possibly multi-line) reply from the buffer of lines.
    /// Returns the reply and the number of lines consumed.
    public static func reply(from lines: [String]) -> (FTPReply, Int)? {
        guard let first = lines.first, first.count >= 3, let code = Int(first.prefix(3)) else {
            if let first = lines.first, !first.isEmpty { return (FTPReply(code: 0, lines: [first]), 1) }
            return nil
        }
        let chars = Array(first)
        if chars.count > 3 && chars[3] == "-" {
            let terminator = "\(first.prefix(3)) "
            for (i, l) in lines.enumerated().dropFirst() where l.hasPrefix(terminator) || l == String(first.prefix(3)) {
                return (FTPReply(code: code, lines: Array(lines[0...i])), i + 1)
            }
            return nil
        }
        return (FTPReply(code: code, lines: [first]), 1)
    }

    /// "229 Entering Extended Passive Mode (|||6446|)"
    public static func epsvPort(_ text: String) -> Int? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inner = text[text.index(after: open)..<close]
        guard let delim = inner.first else { return nil }
        let parts = inner.split(separator: delim, omittingEmptySubsequences: false)
        guard parts.count >= 4, let port = Int(parts[3]), (1...65535).contains(port) else { return nil }
        return port
    }

    /// "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)" — the address is ignored.
    public static func pasvPort(_ text: String) -> Int? {
        let digits = text.split(whereSeparator: { !$0.isNumber && $0 != "," })
            .map(String.init).filter { $0.split(separator: ",").count == 6 }
        guard let group = digits.last else { return nil }
        let n = group.split(separator: ",").compactMap { Int($0) }
        guard n.count == 6, n[4] <= 255, n[5] <= 255 else { return nil }
        let port = n[4] * 256 + n[5]
        return port > 0 ? port : nil
    }

    /// `257 "/home/user" is the current directory` (doubled quotes are escaped quotes).
    public static func pwdPath(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "\"") else { return nil }
        var out = ""
        var i = text.index(after: start)
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "\"" { out.append("\""); i = text.index(after: next); continue }
                return out
            }
            out.append(c)
            i = text.index(after: i)
        }
        return nil
    }

    public static func features(_ reply: FTPReply) -> Set<String> {
        guard reply.isSuccess else { return [] }
        var out = Set<String>()
        for l in reply.lines.dropFirst() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("211") { continue }
            if let w = t.split(separator: " ").first { out.insert(w.uppercased()) }
        }
        return out
    }

    /// "YYYYMMDDHHMMSS[.sss]" in UTC.
    public static func timeval(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 14 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(t.prefix(14)))
    }

    public static func formatTimeval(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: d)
    }

    /// One MLSD/MLST fact line: "type=file;size=12;modify=20240101120000; name".
    public static func mlsdEntry(_ line: String, directory: String) -> RemoteItem? {
        var l = line
        if l.hasPrefix(" ") { l.removeFirst() }
        guard let space = l.firstIndex(of: " ") else { return nil }
        let factsPart = l[..<space]
        let name = String(l[l.index(after: space)...])
        guard !name.isEmpty else { return nil }
        var facts: [String: String] = [:]
        for f in factsPart.split(separator: ";") {
            let kv = f.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { facts[kv[0].lowercased()] = String(kv[1]) }
        }
        let typeFact = facts["type"]?.lowercased() ?? "file"
        if typeFact == "cdir" || typeFact == "pdir" { return nil }
        let baseName = (name as NSString).lastPathComponent
        if baseName == "." || baseName == ".." { return nil }
        var type: RemoteItemType
        switch typeFact {
        case "dir": type = .directory
        case "file": type = .file
        default: type = typeFact.contains("slink") || typeFact.contains("symlink") ? .symlink : .other
        }
        var target: String?
        if type == .symlink, let r = typeFact.range(of: "slink:") {
            target = String(facts["type"]![r.upperBound...])
        }
        let mode = facts["unix.mode"].flatMap { UInt32($0, radix: 8) }.map { $0 & 0o7777 }
        let path = name.hasPrefix("/") ? name : RemotePath.join(directory, name)
        return RemoteItem(name: RemotePath.lastComponent(path), path: path, type: type,
                          size: type == .file ? (facts["size"].flatMap { UInt64($0) }) : nil,
                          modificationDate: facts["modify"].flatMap(timeval),
                          permissions: mode, owner: facts["unix.owner"] ?? facts["unix.uid"],
                          group: facts["unix.group"] ?? facts["unix.gid"], symlinkTarget: target)
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Parses Unix `ls -l` and Windows/IIS LIST lines.
    public static func listEntry(_ line: String, directory: String, now: Date = Date()) -> RemoteItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("total ") { return nil }
        if let first = trimmed.first, first.isNumber { return windowsEntry(trimmed, directory: directory) }
        return unixEntry(trimmed, directory: directory, now: now)
    }

    static func unixEntry(_ line: String, directory: String, now: Date) -> RemoteItem? {
        // perms links owner group size month day time/year name
        var fields: [Substring] = []
        var rest = Substring(line)
        func nextField() -> Substring? {
            rest = rest.drop(while: { $0 == " " })
            guard !rest.isEmpty else { return nil }
            let f = rest.prefix(while: { $0 != " " })
            rest = rest.dropFirst(f.count)
            return f
        }
        guard let perms = nextField(), perms.count >= 10 else { return nil }
        // Find the month token; fields before it are links/owner/group/size.
        var before: [Substring] = []
        var monthIndex: Int?
        while let f = nextField() {
            if months.contains(f.prefix(3).lowercased()) && f.count == 3, let last = before.last, UInt64(last) != nil, before.count >= 2 {
                monthIndex = before.count
                fields = before
                fields.append(f)
                break
            }
            before.append(f)
            if before.count > 6 { return nil }
        }
        guard let mi = monthIndex, let dayField = nextField(), let timeField = nextField() else { return nil }
        let name = String(rest.dropFirst())
        guard !name.isEmpty else { return nil }
        let size = UInt64(fields[mi - 1])
        let owner = mi >= 4 ? String(fields[mi - 3]) : (mi == 3 ? String(fields[mi - 2]) : nil)
        let group = mi >= 4 ? String(fields[mi - 2]) : nil
        let month = months.firstIndex(of: fields[mi].lowercased())! + 1
        guard let day = Int(dayField) else { return nil }
        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.month = month
        comps.day = day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        if timeField.contains(":") {
            let hm = timeField.split(separator: ":")
            comps.hour = Int(hm[0])
            comps.minute = hm.count > 1 ? Int(hm[1]) : 0
            var year = cal.component(.year, from: now)
            comps.year = year
            // Dates without a year are within the last ~6 months.
            if let d = cal.date(from: comps), d > now.addingTimeInterval(86400 * 2) { year -= 1; comps.year = year }
        } else {
            comps.year = Int(timeField)
        }
        let date = cal.date(from: comps)
        let typeChar = perms.first!
        var type: RemoteItemType
        switch typeChar {
        case "d": type = .directory
        case "-": type = .file
        case "l": type = .symlink
        default: type = .other
        }
        var finalName = name
        var target: String?
        if type == .symlink, let r = name.range(of: " -> ") {
            finalName = String(name[..<r.lowerBound])
            target = String(name[r.upperBound...])
        }
        if finalName == "." || finalName == ".." { return nil }
        return RemoteItem(name: finalName, path: RemotePath.join(directory, finalName), type: type,
                          size: type == .file ? size : nil, modificationDate: date,
                          permissions: parseSymbolicMode(String(perms)), owner: owner, group: group,
                          symlinkTarget: target)
    }

    /// "drwxr-sr-t" → 0o3755-style bits.
    public static func parseSymbolicMode(_ s: String) -> UInt32? {
        let c = Array(s)
        guard c.count >= 10 else { return nil }
        var mode: UInt32 = 0
        let bits: [(Int, Character, UInt32)] = [(1, "r", 0o400), (2, "w", 0o200), (4, "r", 0o040), (5, "w", 0o020), (7, "r", 0o004), (8, "w", 0o002)]
        for (i, ch, bit) in bits where c[i] == ch { mode |= bit }
        switch c[3] { case "x": mode |= 0o100; case "s": mode |= 0o4100; case "S": mode |= 0o4000; default: break }
        switch c[6] { case "x": mode |= 0o010; case "s": mode |= 0o2010; case "S": mode |= 0o2000; default: break }
        switch c[9] { case "x": mode |= 0o001; case "t": mode |= 0o1001; case "T": mode |= 0o1000; default: break }
        return mode
    }

    /// "01-15-24  03:04PM       <DIR>          folder" / "01-15-2024  15:04  1234 file.txt"
    static func windowsEntry(_ line: String, directory: String) -> RemoteItem? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return nil }
        let dateStr = String(parts[0]), timeStr = String(parts[1])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        var date: Date?
        for fmt in ["MM-dd-yy hh:mma", "MM-dd-yyyy hh:mma", "MM-dd-yy HH:mm", "MM-dd-yyyy HH:mm", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: "\(dateStr) \(timeStr.uppercased())") { date = d; break }
        }
        guard date != nil else { return nil }
        let sizeOrDir = parts[2]
        let name = String(parts[3]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        if sizeOrDir.uppercased() == "<DIR>" {
            return RemoteItem(name: name, path: RemotePath.join(directory, name), type: .directory, modificationDate: date)
        }
        guard let size = UInt64(sizeOrDir.replacingOccurrences(of: ",", with: "")) else { return nil }
        return RemoteItem(name: name, path: RemotePath.join(directory, name), type: .file, size: size, modificationDate: date)
    }

    /// Maps a failed reply to a RemoteError.
    public static func error(_ reply: FTPReply, path: String) -> RemoteError {
        let m = reply.message.lowercased()
        switch reply.code {
        case 530: return .authenticationFailed(reply.message)
        case 421: return .connectionFailed(reply.message)
        case 500, 502, 504: return .unsupported(reply.message)
        case 450, 550:
            if m.contains("permission") || m.contains("denied") || m.contains("not allowed") || m.contains("access") {
                return .permissionDenied(path)
            }
            if m.contains("exist") && !m.contains("not exist") && !m.contains("doesn't exist") && !m.contains("does not exist") {
                return .alreadyExists(path)
            }
            return .notFound(path)
        case 553: return .permissionDenied(path)
        case 552: return .insufficientStorage
        default: return .protocolError("FTP error \(reply.code): \(reply.message)")
        }
    }
}
