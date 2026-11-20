import Foundation

/// Remote tools detected once per SCP (shell) session.
public struct ShellTools: Equatable, Sendable {
    /// `stat -c` works (GNU coreutils and BusyBox).
    public var stat: Bool
    /// `ls --full-time` works (GNU coreutils and most BusyBox builds).
    public var lsFullTime: Bool
    public var scp: Bool
    public var readlink: Bool

    public init(stat: Bool = false, lsFullTime: Bool = false, scp: Bool = false, readlink: Bool = false) {
        self.stat = stat
        self.lsFullTime = lsFullTime
        self.scp = scp
        self.readlink = readlink
    }
}

/// Shell scripts run by the SCP (shell) mode, and parsers for their output.
/// Every script runs under `/bin/sh` with `LC_ALL=C` and `TZ=UTC0`.
public enum ShellScripts {
    /// Printed before the real output so login-shell noise can be discarded.
    public static let marker = "\u{1E}XFINDER-BEGIN\u{1E}"

    /// The full command line sent in the exec request: the user's login shell
    /// only sees one simple command that starts `/bin/sh`.
    public static func command(_ script: String) -> String {
        let body = "LC_ALL=C; export LC_ALL; TZ=UTC0; export TZ; printf '\\036XFINDER-BEGIN\\036'; " + script
        return "exec /bin/sh -c " + ShellQuote.quote(body)
    }

    public static let probe = """
        pwd
        if stat -c %Y / >/dev/null 2>&1; then echo stat=1; else echo stat=0; fi
        if ls --full-time -d / >/dev/null 2>&1; then echo fulltime=1; else echo fulltime=0; fi
        if command -v scp >/dev/null 2>&1; then echo scp=1; else echo scp=0; fi
        if command -v readlink >/dev/null 2>&1; then echo readlink=1; else echo readlink=0; fi
        """

    public static func parseProbe(_ output: String) -> (home: String, tools: ShellTools) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var tools = ShellTools()
        var home = "/"
        if let first = lines.first, first.hasPrefix("/") { home = first }
        for line in lines {
            switch line {
            case "stat=1": tools.stat = true
            case "fulltime=1": tools.lsFullTime = true
            case "scp=1": tools.scp = true
            case "readlink=1": tools.readlink = true
            default: break
            }
        }
        return (home, tools)
    }

    static let statFormat = "'%f|%s|%Y|%U|%G|%n'"

    /// Prints one `L|<isDir>|<name bytes>|<name><target>` line per symlink in the
    /// current directory (`$n` is the name, `$f` the path to test).
    static func linkLine(tools: ShellTools) -> String {
        let target = tools.readlink ? "t=$(readlink \"$f\" 2>/dev/null)" : "t="
        return "if [ -d \"$f\" ]; then d=1; else d=0; fi; \(target); printf 'L|%s|%s|%s%s\\n' \"$d\" \"${#n}\" \"$n\" \"$t\""
    }

    /// Lists a directory (entries other than `.` and `..`).
    public static func list(_ path: String, tools: ShellTools) -> String {
        let cd = "cd \(ShellQuote.quote(path)) || exit 1; "
        if tools.stat {
            return cd + """
                for f in ./.[!.]* ./..?* ./*; do [ -L "$f" ] || continue; n=${f#./}; \(linkLine(tools: tools)); done; \
                stat -c \(statFormat) ./.[!.]* ./..?* ./* 2>/dev/null; exit 0
                """
        }
        return cd + "ls -la\(tools.lsFullTime ? " --full-time" : "")"
    }

    /// Describes one item (without following a final symlink).
    public static func stat(_ path: String, tools: ShellTools) -> String {
        let q = ShellQuote.quote(path)
        if tools.stat {
            return "f=\(q); n=$f; stat -c \(statFormat) \"$f\" || exit 1; if [ -L \"$f\" ]; then \(linkLine(tools: tools)); fi"
        }
        return "ls -lad\(tools.lsFullTime ? " --full-time" : "") \(q)"
    }

    /// Parses the output of `list` / `stat`. `directory` is the listed folder
    /// (for `stat`, the parent of the item; names are reduced to their last component).
    public static func parseListing(_ output: Data, directory: String, tools: ShellTools, now: Date = Date()) -> [RemoteItem] {
        if tools.stat { return parseStatOutput(output, directory: directory) }
        return LsParser.parse(String(decoding: output, as: UTF8.self), directory: directory, now: now)
    }

    /// Parses `stat -c '%f|%s|%Y|%U|%G|%n'` lines plus the `L|…` symlink lines.
    public static func parseStatOutput(_ output: Data, directory: String) -> [RemoteItem] {
        var links: [String: (isDir: Bool, target: String)] = [:]
        var items: [RemoteItem] = []
        for raw in output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let line = Array(raw)
            if line.starts(with: Array("L|".utf8)) {
                // L|<d>|<len>|<name><target>
                let parts = line.split(separator: UInt8(ascii: "|"), maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4, let len = Int(String(decoding: parts[2], as: UTF8.self)) else { continue }
                let rest = Array(parts[3])
                guard len <= rest.count else { continue }
                let name = String(decoding: rest[..<len], as: UTF8.self)
                let target = String(decoding: rest[len...], as: UTF8.self)
                links[RemotePath.lastComponent(name)] = (parts[1].first == UInt8(ascii: "1"), target)
                continue
            }
            let parts = line.split(separator: UInt8(ascii: "|"), maxSplits: 5, omittingEmptySubsequences: false)
            guard parts.count == 6,
                  let mode = UInt32(String(decoding: parts[0], as: UTF8.self), radix: 16),
                  let size = UInt64(String(decoding: parts[1], as: UTF8.self)),
                  let mtime = TimeInterval(String(decoding: parts[2], as: UTF8.self)) else { continue }
            var name = String(decoding: parts[5], as: UTF8.self)
            if name.hasPrefix("./") { name.removeFirst(2) }
            name = RemotePath.lastComponent(name)
            if name == "." || name == ".." || name.isEmpty { continue }
            let type = itemType(mode: mode)
            let owner = String(decoding: parts[3], as: UTF8.self)
            let group = String(decoding: parts[4], as: UTF8.self)
            items.append(RemoteItem(name: name, path: RemotePath.join(directory, name), type: type,
                                    size: type == .directory ? nil : size,
                                    modificationDate: Date(timeIntervalSince1970: mtime),
                                    permissions: mode & 0o7777, owner: owner, group: group))
        }
        for i in items.indices where items[i].type == .symlink {
            if let l = links[items[i].name] {
                items[i].symlinkTarget = l.target.isEmpty ? nil : l.target
                items[i].symlinkTargetIsDirectory = l.isDir
            }
        }
        return items
    }

    static func itemType(mode: UInt32) -> RemoteItemType {
        switch mode & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symlink
        case 0o100000: return .file
        default: return .other
        }
    }
}

/// Parser for `ls -la` output from GNU coreutils and BusyBox, with or without
/// `--full-time`. Dates without a time zone are read as UTC (`TZ=UTC0`).
public enum LsParser {
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public static func parse(_ output: String, directory: String, now: Date = Date()) -> [RemoteItem] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            parseLine(String($0), directory: directory, now: now)
        }.filter { $0.name != "." && $0.name != ".." }
    }

    /// Parses one long-listing line. Returns nil for `total` and unparseable lines.
    public static func parseLine(_ line: String, directory: String, now: Date = Date()) -> RemoteItem? {
        let chars = Array(line)
        var pos = 0
        func token() -> String? {
            while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
            guard pos < chars.count else { return nil }
            let start = pos
            while pos < chars.count, chars[pos] != " " && chars[pos] != "\t" { pos += 1 }
            return String(chars[start..<pos])
        }
        guard let perms = token(), perms.count >= 10, let typeChar = perms.first,
              "-dlcbps".contains(typeChar) else { return nil }
        guard token().flatMap(Int.init) != nil,           // link count
              let owner = token(), let group = token(), var sizeToken = token() else { return nil }
        var size: UInt64?
        if sizeToken.hasSuffix(",") {
            // Device: "major, minor".
            guard let minor = token() else { return nil }
            sizeToken = minor
        } else {
            size = UInt64(sizeToken)
            guard size != nil else { return nil }
        }
        guard let d1 = token(), let d2 = token(), let d3 = token() else { return nil }
        guard let date = parseDate(d1, d2, d3, now: now) else { return nil }
        // Exactly one separator before the name (names may start with spaces).
        guard pos < chars.count else { return nil }
        var name = String(chars[(pos + 1)...])
        var target: String?
        let type: RemoteItemType
        switch typeChar {
        case "d": type = .directory
        case "l":
            type = .symlink
            if let r = name.range(of: " -> ") {
                target = String(name[r.upperBound...])
                name = String(name[..<r.lowerBound])
            }
        case "-": type = .file
        default: type = .other
        }
        guard !name.isEmpty else { return nil }
        return RemoteItem(name: name, path: RemotePath.join(directory, name), type: type,
                          size: type == .directory || typeChar == "c" || typeChar == "b" ? nil : size,
                          modificationDate: date, permissions: permissionBits(String(perms.prefix(10))),
                          owner: owner, group: group, symlinkTarget: target)
    }

    /// `rwxr-xr-x` (with the type character) to permission bits.
    public static func permissionBits(_ s: String) -> UInt32? {
        let c = Array(s)
        guard c.count == 10 else { return nil }
        var m: UInt32 = 0
        func bit(_ i: Int, _ ch: Character, _ v: UInt32) { if c[i] == ch { m |= v } }
        bit(1, "r", 0o400); bit(2, "w", 0o200)
        bit(4, "r", 0o040); bit(5, "w", 0o020)
        bit(7, "r", 0o004); bit(8, "w", 0o002)
        switch c[3] { case "x": m |= 0o100; case "s": m |= 0o4100; case "S": m |= 0o4000; default: break }
        switch c[6] { case "x": m |= 0o010; case "s": m |= 0o2010; case "S": m |= 0o2000; default: break }
        switch c[9] { case "x": m |= 0o001; case "t": m |= 0o1001; case "T": m |= 0o1000; default: break }
        return m
    }

    static func parseDate(_ a: String, _ b: String, _ c: String, now: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Full time: 2026-11-19 14:20:27[.nnnnnnnnn] -0500
        if a.count == 10, a.dropFirst(4).first == "-" {
            let dp = a.split(separator: "-").compactMap { Int($0) }
            let timePart = b.split(separator: ".").first.map(String.init) ?? b
            let tp = timePart.split(separator: ":").compactMap { Int($0) }
            guard dp.count == 3, tp.count >= 2 else { return nil }
            var comps = DateComponents(year: dp[0], month: dp[1], day: dp[2], hour: tp[0], minute: tp[1],
                                       second: tp.count > 2 ? tp[2] : 0)
            var offset = 0
            if c.count == 5, let sign = c.first, sign == "+" || sign == "-", let v = Int(c.dropFirst()) {
                offset = (v / 100 * 3600 + v % 100 * 60) * (sign == "-" ? -1 : 1)
            }
            comps.timeZone = TimeZone(secondsFromGMT: offset)
            return cal.date(from: comps)
        }
        // Short: "Nov 19 14:20" or "Nov 19  2025".
        guard let mi = months.firstIndex(of: a), let day = Int(b) else { return nil }
        if c.contains(":") {
            let tp = c.split(separator: ":").compactMap { Int($0) }
            guard tp.count == 2 else { return nil }
            let year = cal.component(.year, from: now)
            var comps = DateComponents(year: year, month: mi + 1, day: day, hour: tp[0], minute: tp[1])
            guard var date = cal.date(from: comps) else { return nil }
            // No year means "within the last six months": a date in the future is last year's.
            if date > now.addingTimeInterval(86_400) {
                comps.year = year - 1
                date = cal.date(from: comps) ?? date
            }
            return date
        }
        guard let year = Int(c) else { return nil }
        return cal.date(from: DateComponents(year: year, month: mi + 1, day: day))
    }
}

/// Framing of the classic SCP (rcp) protocol used by `scp -f` / `scp -t`.
public enum SCPProtocol {
    public static let ok: UInt8 = 0
    public static let warning: UInt8 = 1
    public static let fatal: UInt8 = 2

    /// `C0644 <size> <name>\n`.
    public static func fileHeader(mode: UInt32, size: UInt64, name: String) throws -> Data {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\n") else {
            throw RemoteError.unsupported("SCP cannot transfer a file named \"\(name)\".")
        }
        return Data("C\(String(format: "%04o", mode & 0o7777)) \(size) \(name)\n".utf8)
    }

    public struct FileHeader: Equatable, Sendable {
        public var mode: UInt32
        public var size: UInt64
        public var name: String
    }

    /// Parses a `C` line (without the trailing newline).
    public static func parseFileHeader(_ line: String) -> FileHeader? {
        guard line.hasPrefix("C") else { return nil }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let mode = UInt32(parts[0], radix: 8), let size = UInt64(parts[1]) else { return nil }
        return FileHeader(mode: mode, size: size, name: String(parts[2]))
    }

    /// Error for a warning/fatal status byte followed by its message.
    public static func error(status: UInt8, message: String, path: String) -> RemoteError {
        ShellErrors.map(message.isEmpty ? "scp failed (status \(status))" : message, path: path)
    }
}

/// Maps remote error text (LC_ALL=C) to `RemoteError`.
public enum ShellErrors {
    public static func map(_ stderr: String, path: String, exitStatus: Int? = nil) -> RemoteError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("no such file") || lower.contains("not found") || lower.contains("can't stat")
            || lower.contains("cannot stat") || lower.contains("can't cd") || lower.contains("can't open") && lower.contains("no such") {
            return .notFound(path)
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted")
            || lower.contains("read-only file system") {
            return .permissionDenied(path)
        }
        if lower.contains("file exists") { return .alreadyExists(path) }
        if lower.contains("no space left") || lower.contains("disk quota") { return .insufficientStorage }
        if text.isEmpty {
            return .protocolError("The remote command failed\(exitStatus.map { " (exit status \($0))" } ?? "").")
        }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return .protocolError(firstLine)
    }
}
