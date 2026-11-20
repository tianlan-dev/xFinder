import XCTest
@testable import xFinderKit

final class SSHCommandBuilderTests: XCTestCase {
    func testQuote() {
        XCTAssertEqual(SSHCommandBuilder.quote("plain"), "'plain'")
        XCTAssertEqual(SSHCommandBuilder.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(SSHCommandBuilder.quote("$(rm -rf ~)"), "'$(rm -rf ~)'")
    }

    func testBasicCommand() throws {
        let spec = SSHCommandSpec(host: "example.com", port: 2222, username: "deploy", keyPath: "/k/id", keyOnly: true)
        let args = try SSHCommandBuilder.arguments(spec)
        XCTAssertEqual(args, ["ssh", "-t", "-p", "2222", "-i", "/k/id", "-o", "IdentitiesOnly=yes",
                              "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
                              "-o", "KbdInteractiveAuthentication=no", "-l", "deploy", "--", "example.com"])
    }

    func testDefaultPortAndNoKey() throws {
        let args = try SSHCommandBuilder.arguments(SSHCommandSpec(host: "[::1]", username: "me"))
        XCTAssertEqual(args, ["ssh", "-t", "-o", "PubkeyAuthentication=no", "-l", "me", "--", "::1"])
    }

    func testAliasUsesSSHConfig() throws {
        let args = try SSHCommandBuilder.arguments(SSHCommandSpec(host: "ignored", port: 2200, username: "x",
                                                                  keyPath: "/k", sshConfigAlias: "prod"))
        XCTAssertEqual(args, ["ssh", "-t", "--", "prod"])
    }

    func testRemotePath() throws {
        XCTAssertEqual(SSHCommandBuilder.remoteChangeDirectory("~"), "cd \"$HOME\"")
        XCTAssertEqual(SSHCommandBuilder.remoteChangeDirectory("~/a b"), "cd \"$HOME\"/'a b'")
        XCTAssertEqual(SSHCommandBuilder.remoteChangeDirectory("-rf"), "cd './-rf'")
        XCTAssertEqual(SSHCommandBuilder.remoteChangeDirectory("/var/it's"), "cd '/var/it'\\''s'")
        let args = try SSHCommandBuilder.arguments(SSHCommandSpec(host: "h", remotePath: "/srv/$(id)"))
        XCTAssertEqual(args.last, "cd '/srv/$(id)' && exec \"$SHELL\" -l")
    }

    func testInjectionAttemptsAreRejected() {
        for host in ["-oProxyCommand=touch /tmp/x", "a b", "host\nrm", "", "x\0y"] {
            XCTAssertThrowsError(try SSHCommandBuilder.arguments(SSHCommandSpec(host: host)), host)
        }
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(SSHCommandSpec(host: "h", username: "-oProxyCommand=x")))
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(SSHCommandSpec(host: "h", username: "a b")))
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(SSHCommandSpec(host: "h", sshConfigAlias: "-F/etc/x")))
    }

    func testCommandLineIsShellSafe() throws {
        let line = try SSHCommandBuilder.commandLine(SSHCommandSpec(host: "h", username: "u", keyPath: "/k/it's key",
                                                                    remotePath: "/tmp/`whoami`; rm -rf /"))
        // Run through the shell and check every argument comes back unchanged.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "set -- \(line); for a; do printf '%s\\n' \"$a\"; done"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let expected = try SSHCommandBuilder.arguments(SSHCommandSpec(host: "h", username: "u", keyPath: "/k/it's key",
                                                                      remotePath: "/tmp/`whoami`; rm -rf /"))
        XCTAssertEqual(out.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init), expected)
    }

    func testTerminalScript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xf-term-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TerminalScript.write(commandLine: "'ssh' '--' 'h'",
                                           askpass: .init(helperPath: "/a/askpass.sh", socketPath: "/a/s.sock", token: "abc"),
                                           in: dir)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("SSH_ASKPASS_REQUIRE"))
        XCTAssertTrue(text.contains("abc"))
        XCTAssertTrue(text.contains("'ssh' '--' 'h'"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        let plain = TerminalScript.contents(commandLine: "'ssh'", askpass: nil)
        XCTAssertFalse(plain.contains("SSH_ASKPASS"))
    }
}

final class AskpassTests: XCTestCase {
    func testTokensAreSingleUseAndExpire() {
        let b = AskpassBroker(directory: FileManager.default.temporaryDirectory)
        let t = b.issueToken(password: "secret")
        XCTAssertEqual(t.count, 64)
        XCTAssertEqual(b.redeem(t), "secret")
        XCTAssertNil(b.redeem(t))
        let now = Date()
        let t2 = b.issueToken(password: "x", now: now)
        XCTAssertNil(b.redeem(t2, now: now.addingTimeInterval(AskpassBroker.tokenLifetime + 1)))
        XCTAssertNil(b.redeem("not-a-token"))
    }

    func testSocketRoundTripThroughHelper() throws {
        // Short path: Unix socket paths are limited to 104 bytes.
        let dir = URL(fileURLWithPath: "/tmp/xfa-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = AskpassBroker(directory: dir)
        try b.start()
        defer { b.stop() }
        let sockMode = try FileManager.default.attributesOfItem(atPath: b.socketPath)[.posixPermissions] as? Int
        XCTAssertEqual(sockMode, 0o600)
        let token = b.issueToken(password: "p@ss w'rd")

        func runHelper(_ prompt: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: b.helperPath)
            p.arguments = [prompt]
            p.environment = ["XFINDER_ASKPASS_TOKEN": token, "XFINDER_ASKPASS_SOCKET": b.socketPath, "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            p.standardInput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try runHelper("deploy@host's password: "), "p@ss w'rd\n")
        // Second use of the same token gets nothing from the broker.
        XCTAssertNil(b.redeem(token))
    }
}
