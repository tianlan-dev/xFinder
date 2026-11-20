import XCTest
@testable import xFinderKit

final class LsParserTests: XCTestCase {
    var utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    lazy var now = utc.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 20))!

    func ymdhm(_ d: Date?) -> [Int] {
        guard let d else { return [] }
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!]
    }

    func testGNUFullTime() {
        let out = """
            total 24
            drwxr-xr-x  3 tian tian 4096 2026-11-19 14:20:27.123456789 -0500 .
            drwxr-xr-x. 5 root root 4096 2026-01-02 03:04:05.000000000 +0000 ..
            -rw-r--r--  1 tian tian 3697 2026-11-19 14:20:27.500000000 -0500 .bashrc
            lrwxrwxrwx  1 tian tian   11 2025-06-01 00:00:00.000000000 +0000 link -> target dir
            -rwsr-x--T+ 1 root wheel 10 2026-02-03 04:05:06.000000000 +0000   two leading spaces.txt
            crw-rw-rw-  1 root root 1,   3 2026-02-03 04:05:06.000000000 +0000 null
            """
        let items = LsParser.parse(out, directory: "/home/tian", now: now)
        XCTAssertEqual(items.map(\.name), [".bashrc", "link", "  two leading spaces.txt", "null"])
        XCTAssertEqual(items[0].size, 3697)
        XCTAssertEqual(items[0].path, "/home/tian/.bashrc")
        XCTAssertEqual(ymdhm(items[0].modificationDate), [2026, 11, 19, 19, 20, 27])
        XCTAssertEqual(items[0].permissions, 0o644)
        XCTAssertEqual(items[0].owner, "tian")
        XCTAssertEqual(items[1].type, .symlink)
        XCTAssertEqual(items[1].symlinkTarget, "target dir")
        XCTAssertEqual(items[2].permissions, 0o5750)
        XCTAssertEqual(items[2].group, "wheel")
        XCTAssertEqual(items[3].type, .other)
        XCTAssertNil(items[3].size)
    }

    func testBusyBoxFullTimeAndShortDates() {
        let full = "-rw-r--r--    1 tian     tian          3697 2026-11-19 14:20:27 -0500 .screenrc"
        XCTAssertEqual(ymdhm(LsParser.parseLine(full, directory: "/", now: now)?.modificationDate), [2026, 11, 19, 19, 20, 27])

        let recent = "-rw-r--r--    1 tian     tian          3697 Nov 19 14:20 .screenrc"
        XCTAssertEqual(ymdhm(LsParser.parseLine(recent, directory: "/", now: now)?.modificationDate), [2026, 11, 19, 14, 20, 0])
        // A month later than "now" without a year belongs to last year.
        let lastYear = "-rw-r--r--    1 tian     tian          1 Dec 24 09:00 old"
        XCTAssertEqual(ymdhm(LsParser.parseLine(lastYear, directory: "/", now: now)?.modificationDate), [2025, 12, 24, 9, 0, 0])
        let withYear = "drwxr-xr-x    2 root     root          4096 Mar  5  2023 sbin"
        let item = LsParser.parseLine(withYear, directory: "/", now: now)
        XCTAssertEqual(ymdhm(item?.modificationDate), [2023, 3, 5, 0, 0, 0])
        XCTAssertEqual(item?.type, .directory)
        XCTAssertNil(item?.size)
    }

    func testNamesWithSpacesQuotesUnicodeAndArrows() {
        let out = """
            -rw-r--r-- 1 a b 5 Nov 19 14:20 it's "quoted" ü Ωμέγα ☃.txt
            -rw-r--r-- 1 a b 5 Nov 19 14:20 a -> b.txt
            lrwxrwxrwx 1 a b 5 Nov 19 14:20 my link -> ../some where
            """
        let items = LsParser.parse(out, directory: "/d", now: now)
        XCTAssertEqual(items.map(\.name), ["it's \"quoted\" ü Ωμέγα ☃.txt", "a -> b.txt", "my link"])
        XCTAssertEqual(items[2].symlinkTarget, "../some where")
    }

    func testRejectsNoise() {
        XCTAssertNil(LsParser.parseLine("total 8", directory: "/"))
        XCTAssertNil(LsParser.parseLine("Welcome to the server!", directory: "/"))
        XCTAssertNil(LsParser.parseLine("ls: can't open 'x': No such file", directory: "/"))
    }

    func testPermissionBits() {
        XCTAssertEqual(LsParser.permissionBits("drwxr-xr-x"), 0o755)
        XCTAssertEqual(LsParser.permissionBits("-rwSr-sr-t"), 0o7655)
        XCTAssertNil(LsParser.permissionBits("short"))
    }
}

final class ShellScriptTests: XCTestCase {
    func testStatOutputWithLinks() {
        let out = Data("""
            L|1|7|dir linkreal dir
            L|0|9|it's a|bx/y|z
            41ed|4096|1795116027|tian|tian|./dir link
            81a4|12|1795116000|tian|staff|./it's a|b
            a1ff|3|1795116000|root|root|./sh
            41ed|4096|1795116027|tian|tian|./.
            """.utf8)
        let items = ShellScripts.parseStatOutput(out, directory: "/h")
        XCTAssertEqual(items.map(\.name), ["dir link", "it's a|b", "sh"])
        XCTAssertEqual(items[0].type, .directory)
        XCTAssertNil(items[0].size)
        XCTAssertEqual(items[1].type, .file)
        XCTAssertEqual(items[1].size, 12)
        XCTAssertEqual(items[1].permissions, 0o644)
        XCTAssertEqual(items[1].group, "staff")
        XCTAssertEqual(items[1].modificationDate, Date(timeIntervalSince1970: 1795116000))
        XCTAssertEqual(items[2].type, .symlink)
        XCTAssertNil(items[2].symlinkTarget) // no L line for it
    }

    func testStatLinkLineMatchesSymlink() {
        let out = Data("""
            L|1|4|linkx/y|z
            a1ff|3|1795116000|root|root|./link
            """.utf8)
        let item = ShellScripts.parseStatOutput(out, directory: "/").first
        XCTAssertEqual(item?.symlinkTarget, "x/y|z")
        XCTAssertEqual(item?.symlinkTargetIsDirectory, true)
        XCTAssertTrue(item?.isDirectoryLike ?? false)
    }

    func testProbe() {
        let (home, tools) = ShellScripts.parseProbe("/home/tian\nstat=1\nfulltime=0\nscp=1\nreadlink=1\n")
        XCTAssertEqual(home, "/home/tian")
        XCTAssertEqual(tools, ShellTools(stat: true, lsFullTime: false, scp: true, readlink: true))
        XCTAssertEqual(ShellScripts.parseProbe("garbage").home, "/")
    }

    func testCommandRunsUnderShWithQuotedPaths() {
        let script = ShellScripts.list("/srv/it's here", tools: ShellTools(stat: true, readlink: true))
        let command = ShellScripts.command(script)
        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertTrue(command.contains("LC_ALL=C"))
        // The quoted path survives two levels of quoting.
        XCTAssertTrue(script.contains("cd '/srv/it'\\''s here'"))
    }

    func testQuotingRoundTripsThroughSh() throws {
        let tricky = "a b 'c' \"d\" $e `f` \\g ü\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + ShellQuote.quote(tricky)]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), tricky)
    }

    func testErrorMapping() {
        XCTAssertEqual(ShellErrors.map("rm: can't remove 'x': No such file or directory", path: "/x"), .notFound("/x"))
        XCTAssertEqual(ShellErrors.map("mkdir: can't create directory 'x': Permission denied", path: "/x"), .permissionDenied("/x"))
        XCTAssertEqual(ShellErrors.map("'/x': File exists", path: "/x"), .alreadyExists("/x"))
        XCTAssertEqual(ShellErrors.map("", path: "/x", exitStatus: 3), .protocolError("The remote command failed (exit status 3)."))
    }
}

final class SCPProtocolTests: XCTestCase {
    func testHeaderFraming() throws {
        XCTAssertEqual(try SCPProtocol.fileHeader(mode: 0o100644, size: 1234, name: "a b.txt"), Data("C0644 1234 a b.txt\n".utf8))
        XCTAssertThrowsError(try SCPProtocol.fileHeader(mode: 0o644, size: 1, name: "bad\nname"))
        XCTAssertThrowsError(try SCPProtocol.fileHeader(mode: 0o644, size: 1, name: ""))
        XCTAssertEqual(SCPProtocol.parseFileHeader("C0755 99 name with spaces"),
                       SCPProtocol.FileHeader(mode: 0o755, size: 99, name: "name with spaces"))
        XCTAssertNil(SCPProtocol.parseFileHeader("D0755 0 dir"))
        XCTAssertNil(SCPProtocol.parseFileHeader("Cxyz 1 a"))
    }

    func testStatusErrors() {
        XCTAssertEqual(SCPProtocol.error(status: 1, message: "scp: /x: No such file or directory", path: "/x"), .notFound("/x"))
        XCTAssertEqual(SCPProtocol.error(status: 2, message: "", path: "/x"), .protocolError("scp failed (status 2)"))
    }

    func testProtocolMetadata() {
        XCTAssertEqual(SiteProtocol.allCases.prefix(2), [.sftp, .scp])
        XCTAssertEqual(SiteProtocol.scp.defaultPort, 22)
        XCTAssertTrue(SiteProtocol.scp.isSSH)
        XCTAssertFalse(SiteProtocol.scp.capabilities.contains(.resume))
        XCTAssertEqual(SiteProtocol.scp.displayName, "SCP (shell)")
    }
}
