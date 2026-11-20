import Foundation

enum FTPSecurity: Sendable {
    case none
    case explicit
    case implicit
}

/// One FTP control connection. Not thread-safe: FTPFileSystem serializes access.
final class FTPConnection: @unchecked Sendable {
    static let responseTimeout: Double = 60
    static let connectTimeout: Double = 20

    let host: String
    let port: Int
    let security: FTPSecurity
    let trust: TLSTrustEvaluator
    let username: String
    let password: String

    private var control: FTPStream?
    private var buffer = Data()
    private(set) var features: Set<String> = []
    private(set) var home = "/"
    private(set) var isOpen = false

    init(host: String, port: Int, security: FTPSecurity, trust: TLSTrustEvaluator, username: String, password: String) {
        self.host = host
        self.port = port
        self.security = security
        self.trust = trust
        self.username = username
        self.password = password
    }

    var isProtected: Bool { security != .none }
    var supportsMLSD: Bool { features.contains("MLST") || features.contains("MLSD") }
    var supportsMFMT: Bool { features.contains("MFMT") }

    // MARK: Lifecycle

    private func makeStream(port p: Int, tls: Bool) async throws -> FTPStream {
        if security == .none {
            return try await NWStream.connect(host: host, port: p, timeout: Self.connectTimeout)
        }
        let s = try await TLSStream.connect(host: host, port: p, trust: trust, trustPort: port, tls: tls)
        return s
    }

    func open() async throws {
        control = try await makeStream(port: port, tls: security == .implicit)
        buffer = Data()
        let greeting = try await readReply()
        guard greeting.code == 220 else {
            close()
            throw greeting.code == 421 ? RemoteError.connectionFailed(greeting.message)
                                       : RemoteError.protocolError("Unexpected greeting: \(greeting.text)")
        }
        if security == .explicit {
            let r = try await command("AUTH TLS")
            guard r.code == 234 else {
                close()
                throw RemoteError.connectionFailed("The server does not support FTPS (AUTH TLS was refused: \(r.message)).")
            }
            try await control!.startTLS()
        }
        let user = username.isEmpty ? "anonymous" : username
        let pass = username.isEmpty ? "anonymous@" : password
        var r = try await command("USER \(user)")
        if r.code == 331 || r.code == 332 {
            r = try await command("PASS \(pass)")
        }
        guard r.code == 230 || r.code == 202 else {
            close()
            if r.code == 530 || r.code == 331 || r.code == 332 { throw RemoteError.authenticationFailed(r.message) }
            throw FTPParsing.error(r, path: "")
        }
        if isProtected {
            _ = try await command("PBSZ 0")
            let p = try await command("PROT P")
            guard p.isSuccess else {
                close()
                throw RemoteError.connectionFailed("The server refused encrypted data connections (PROT P: \(p.message)).")
            }
        }
        features = FTPParsing.features(try await command("FEAT"))
        if features.contains("UTF8") { _ = try await command("OPTS UTF8 ON") }
        _ = try await command("TYPE I")
        let pwd = try await command("PWD")
        home = FTPParsing.pwdPath(pwd.text) ?? "/"
        isOpen = true
    }

    func close() {
        isOpen = false
        control?.close()
        control = nil
    }

    func quit() async {
        if isOpen { _ = try? await withTimeout(3) { try await self.command("QUIT") } }
        close()
    }

    // MARK: Replies

    private func readLine() async throws -> String {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                var lineData = buffer[buffer.startIndex..<nl]
                if lineData.last == 0x0D { lineData = lineData.dropLast() }
                buffer = Data(buffer[buffer.index(after: nl)...])
                return String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
            }
            guard let stream = control else { throw RemoteError.notConnected }
            let chunk = try await withTimeout(Self.responseTimeout) { try await stream.read(maxLength: 8192) }
            guard let chunk else {
                close()
                throw RemoteError.connectionFailed("The server closed the connection.")
            }
            buffer.append(chunk)
        }
    }

    func readReply() async throws -> FTPReply {
        var lines: [String] = []
        while true {
            lines.append(try await readLine())
            if let (reply, _) = FTPParsing.reply(from: lines) {
                if reply.code == 421 { close() }
                return reply
            }
        }
    }

    func command(_ cmd: String) async throws -> FTPReply {
        guard !cmd.contains("\r"), !cmd.contains("\n") else {
            throw RemoteError.protocolError("Names containing line breaks cannot be used over FTP.")
        }
        guard let stream = control else { throw RemoteError.notConnected }
        do {
            try await stream.write(Data((cmd + "\r\n").utf8))
        } catch {
            close()
            throw error
        }
        do {
            return try await readReply()
        } catch {
            close()
            throw error
        }
    }

    // MARK: Data connections

    /// EPSV first, then PASV; the PASV address is ignored and the control host reused.
    func openData() async throws -> FTPStream {
        var dataPort: Int?
        let e = try await command("EPSV")
        if e.code == 229 { dataPort = FTPParsing.epsvPort(e.text) }
        if dataPort == nil {
            let p = try await command("PASV")
            guard p.code == 227, let port = FTPParsing.pasvPort(p.text) else {
                throw RemoteError.protocolError("The server refused passive mode: \(p.message)")
            }
            dataPort = port
        }
        return try await makeStream(port: dataPort!, tls: isProtected)
    }

    /// Runs a command that uses a data connection.
    func transfer(_ cmd: String, path: String, _ body: (FTPStream) async throws -> Void) async throws {
        let data = try await openData()
        let r: FTPReply
        do { r = try await command(cmd) } catch { data.close(); throw error }
        guard r.isPositivePreliminary || r.isSuccess else {
            data.close()
            throw FTPParsing.error(r, path: path)
        }
        do {
            try await body(data)
        } catch {
            data.close()
            close()  // the control channel state is unknown now
            throw error
        }
        data.close()
        if r.isPositivePreliminary {
            let final = try await readReply()
            guard final.isSuccess else { throw FTPParsing.error(final, path: path) }
        }
    }
}
