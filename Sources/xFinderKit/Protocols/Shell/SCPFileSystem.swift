import Foundation
import Citadel
import NIOCore
import NIOSSH

/// SCP (shell) mode: plain SSH exec channels for servers without an SFTP
/// subsystem. Listing and file operations run POSIX shell commands; transfers
/// use the classic SCP protocol (`scp -f` / `scp -t`), or `cat` when the server
/// has no `scp`.
public final class SCPFileSystem: RemoteFileSystem, @unchecked Sendable {
    public static let chunkSize = 32 * 1024

    public let config: ConnectionConfig
    let environment: ConnectionEnvironment
    private let cached: CachedCredentials?

    private let state = Locked<(client: SSHClient?, home: String, credentials: CachedCredentials?, tools: ShellTools)>(
        (nil, "/", nil, ShellTools()))
    private let disconnectHandler = Locked<(@Sendable () -> Void)?>(nil)

    public init(config: ConnectionConfig, environment: ConnectionEnvironment, cachedCredentials: CachedCredentials? = nil) {
        self.config = config
        self.environment = environment
        self.cached = cachedCredentials
    }

    public var capabilities: RemoteCapabilities { .scp }
    public var homeDirectory: String { state.value.home }
    public var isConnected: Bool { state.value.client?.isConnected ?? false }
    public var tools: ShellTools { state.value.tools }

    /// Tests: pretend the server lacks some tools (for example `scp` or `stat`).
    func overrideTools(_ change: (inout ShellTools) -> Void) {
        state.withLock { change(&$0.tools) }
    }

    public func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        disconnectHandler.value = handler
    }

    // MARK: Connect

    public func connect() async throws {
        let (client, creds) = try await SSHConnector.connect(config: config, environment: environment, cached: cached)
        state.withLock { $0.client = client; $0.credentials = creds }
        let result: ShellResult
        do {
            result = try await withTimeout(20) { try await self.run(ShellScripts.probe) }
        } catch {
            try? await client.close()
            state.withLock { $0.client = nil }
            throw RemoteError.connectionFailed("Signed in, but the server does not allow running shell commands "
                + "(\((error as? LocalizedError)?.errorDescription ?? "\(error)")).")
        }
        let (home, tools) = ShellScripts.parseProbe(result.text)
        state.withLock { $0.home = home; $0.tools = tools }
        client.onDisconnect { [weak self] in
            self?.disconnectHandler.value?()
        }
    }

    public func disconnect() async {
        let client = state.value.client
        state.withLock { $0.client = nil }
        try? await client?.close()
    }

    public func makeTransferConnection() async throws -> RemoteFileSystem {
        let fs = SCPFileSystem(config: config, environment: environment,
                               cachedCredentials: state.value.credentials ?? cached)
        try await fs.connect()
        return fs
    }

    // MARK: Commands

    struct ShellResult {
        var stdout: Data
        var stderr: Data
        var status: Int
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var errorText: String { String(decoding: stderr, as: UTF8.self) }
    }

    private func client() throws -> SSHClient {
        guard let c = state.value.client, c.isConnected else { throw RemoteError.notConnected }
        return c
    }

    /// Runs a script, collecting its output.
    func run(_ script: String, stdin: Data? = nil) async throws -> ShellResult {
        var out = Data(), err = Data(), status = 0
        try await exec(script) { io in
            if let stdin, !stdin.isEmpty { try await io.write(stdin) }
            try? await io.writer.sendEOF()
            while let chunk = try await io.read() { out.append(chunk) }
            err = io.stderr
            status = io.exitStatus
        }
        return ShellResult(stdout: out, stderr: err, status: status)
    }

    /// Runs a script and throws a mapped error when it fails.
    @discardableResult
    func check(_ script: String, path: String) async throws -> ShellResult {
        let r = try await run(script)
        if r.status != 0 { throw ShellErrors.map(r.errorText, path: path, exitStatus: r.status) }
        return r
    }

    /// Opens an exec channel for `script` and hands its streams to `body`.
    func exec(_ script: String, _ body: (ExecIO) async throws -> Void) async throws {
        let client = try client()
        var finished = false
        // Errors from `body` are kept aside: Citadel closes the channel after
        // `perform`, and a failing close must not hide the real error.
        var bodyError: Error?
        do {
            try await client.withExec(ShellScripts.command(script)) { inbound, outbound in
                let io = ExecIO(inbound: inbound, writer: outbound)
                do { try await body(io) } catch { bodyError = error }
                finished = true
            }
        } catch let e as ChannelError where finished && (e == .alreadyClosed || e == .ioOnClosedChannel) {
            // The server closed the channel first; the command already finished.
        } catch let e as RemoteError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !client.isConnected { throw RemoteError.notConnected }
            throw RemoteError.protocolError("Remote command failed: \(error)")
        }
        if let bodyError { throw bodyError }
    }

    // MARK: Listing

    public func list(_ path: String) async throws -> [RemoteItem] {
        let tools = self.tools
        let r = try await run(ShellScripts.list(path, tools: tools))
        if r.status != 0 { throw ShellErrors.map(r.errorText.isEmpty ? "No such file or directory" : r.errorText, path: path, exitStatus: r.status) }
        return ShellScripts.parseListing(r.stdout, directory: path, tools: tools)
    }

    public func stat(_ path: String) async throws -> RemoteItem {
        let tools = self.tools
        let r = try await run(ShellScripts.stat(path, tools: tools))
        if r.status != 0 { throw ShellErrors.map(r.errorText.isEmpty ? "No such file or directory" : r.errorText, path: path, exitStatus: r.status) }
        let items = ShellScripts.parseListing(r.stdout, directory: RemotePath.parent(path), tools: tools)
        guard var item = items.first else { throw RemoteError.notFound(path) }
        item.path = RemotePath.normalize(path)
        item.name = RemotePath.lastComponent(path)
        return item
    }

    public func symlinkTarget(_ path: String) async throws -> String {
        let r = try await check("readlink \(ShellQuote.quote(path))", path: path)
        return r.text.trimmingCharacters(in: .newlines)
    }

    // MARK: Changes

    private static func failIfExists(_ q: String) -> String {
        "if [ -e \(q) ] || [ -L \(q) ]; then echo \(q)': File exists' >&2; exit 1; fi; "
    }

    public func rename(_ from: String, to: String) async throws {
        let qt = ShellQuote.quote(to)
        try await check(Self.failIfExists(qt) + "mv \(ShellQuote.quote(from)) \(qt)", path: from)
    }

    public func delete(_ path: String, isDirectory: Bool) async throws {
        let q = ShellQuote.quote(path)
        try await check(isDirectory ? "rm -rf \(q)" : "rm \(q)", path: path)
    }

    public func createDirectory(_ path: String) async throws {
        try await check("mkdir \(ShellQuote.quote(path))", path: path)
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        try await check("chmod \(String(mode & 0o7777, radix: 8)) \(ShellQuote.quote(path))", path: path)
    }

    public func setModificationDate(_ path: String, date: Date) async throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm.ss"
        try await check("touch -c -t \(f.string(from: date)) \(ShellQuote.quote(path))", path: path)
    }

    public func copyItem(_ from: String, to: String) async throws {
        let qt = ShellQuote.quote(to)
        try await check(Self.failIfExists(qt) + "cp -pR \(ShellQuote.quote(from)) \(qt)", path: from)
    }

    // MARK: Transfers

    public func download(_ remotePath: String, to localURL: URL, offset: UInt64,
                         progress: @escaping TransferProgressHandler) async throws {
        guard offset == 0 else { throw RemoteError.unsupported("SCP (shell) cannot resume downloads.") }
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: localURL) } catch { throw RemoteError.localIO(error.localizedDescription) }
        defer { try? output.close() }
        progress(0)
        let q = ShellQuote.quote(remotePath)
        if tools.scp {
            try await exec("exec scp -f \(q)") { io in
                try await SCPTransfer.receive(io, path: remotePath, output: output, progress: progress)
            }
        } else {
            var received: UInt64 = 0
            var failure: RemoteError?
            try await exec("exec cat \(q)") { io in
                try? await io.writer.sendEOF()
                while let chunk = try await io.read() {
                    try Task.checkCancellation()
                    do { try output.write(contentsOf: chunk) } catch { throw RemoteError.localIO(error.localizedDescription) }
                    received += UInt64(chunk.count)
                    progress(received)
                }
                if io.exitStatus != 0 {
                    failure = ShellErrors.map(String(decoding: io.stderr, as: UTF8.self), path: remotePath, exitStatus: io.exitStatus)
                }
            }
            if let failure { throw failure }
        }
    }

    public func upload(_ localURL: URL, to remotePath: String, offset: UInt64,
                       progress: @escaping TransferProgressHandler) async throws {
        guard offset == 0 else { throw RemoteError.unsupported("SCP (shell) cannot resume uploads.") }
        let input: FileHandle
        let size: UInt64
        do {
            input = try FileHandle(forReadingFrom: localURL)
            size = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        } catch { throw RemoteError.localIO(error.localizedDescription) }
        defer { try? input.close() }
        progress(0)
        let q = ShellQuote.quote(remotePath)
        if tools.scp {
            try await exec("exec scp -t \(q)") { io in
                try await SCPTransfer.send(io, path: remotePath, input: input, size: size, progress: progress)
            }
        } else {
            var failure: RemoteError?
            try await exec("cat > \(q)") { io in
                var sent: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    guard let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty else { break }
                    try await io.write(data)
                    if io.outputClosed { break }
                    sent += UInt64(data.count)
                    progress(sent)
                }
                try? await io.writer.sendEOF()
                while try await io.read() != nil {}
                if io.exitStatus != 0 {
                    failure = ShellErrors.map(String(decoding: io.stderr, as: UTF8.self), path: remotePath, exitStatus: io.exitStatus)
                }
            }
            if let failure { throw failure }
        }
    }
}

/// Byte-level access to one exec channel: stdout (after the start marker),
/// collected stderr and the exit status.
final class ExecIO {
    private var iterator: TTYOutput.AsyncIterator
    let writer: TTYStdinWriter
    private var buffer = Data()
    private var started = false
    private var ended = false
    private(set) var stderr = Data()
    private(set) var exitStatus = 0

    init(inbound: TTYOutput, writer: TTYStdinWriter) {
        self.iterator = inbound.makeAsyncIterator()
        self.writer = writer
    }

    /// True once the server stopped accepting input (the command exited).
    private(set) var outputClosed = false

    /// Writes to the command's standard input. If the server already closed
    /// the channel the data is dropped; the reason shows up in the output.
    func write(_ data: Data) async throws {
        guard !outputClosed else { return }
        do {
            try await writer.write(ByteBuffer(bytes: data))
        } catch let e as ChannelError where e == .alreadyClosed || e == .ioOnClosedChannel || e == .outputClosed {
            outputClosed = true
        }
    }

    /// Pulls the next stdout chunk from the channel into `buffer`. False at end.
    private func fill() async throws -> Bool {
        while !ended {
            let next: ExecCommandOutput?
            do {
                next = try await iterator.next()
            } catch let e as SSHClient.CommandFailed {
                exitStatus = e.exitCode
                next = nil
            } catch let e as ChannelError where e == .alreadyClosed || e == .ioOnClosedChannel || e == .outputClosed {
                // A write raced with the command exiting; the output so far is complete.
                if exitStatus == 0 { exitStatus = -1 }
                next = nil
            }
            guard let next else { ended = true; break }
            switch next {
            case .stderr(let b):
                stderr.append(contentsOf: b.readableBytesView)
            case .stdout(let b):
                buffer.append(contentsOf: b.readableBytesView)
                if !started {
                    let marker = Data(ShellScripts.marker.utf8)
                    guard let r = buffer.range(of: marker) else { continue }
                    buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                    started = true
                }
                if !buffer.isEmpty { return true }
            }
        }
        if !started { buffer.removeAll() } // never saw the marker: discard login noise
        return !buffer.isEmpty
    }

    /// Returns any available stdout bytes, or nil at end of output.
    func read() async throws -> Data? {
        if buffer.isEmpty, !(try await fill()) { return nil }
        let d = buffer
        buffer = Data()
        return d
    }

    func readByte() async throws -> UInt8? {
        if buffer.isEmpty, !(try await fill()) { return nil }
        return buffer.removeFirst()
    }

    /// Reads up to `max` bytes (at least one unless at end).
    func read(max: Int) async throws -> Data? {
        if buffer.isEmpty, !(try await fill()) { return nil }
        let n = min(max, buffer.count)
        let d = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(d)
    }

    func readLine() async throws -> String? {
        var line = Data()
        while true {
            guard let b = try await readByte() else { return line.isEmpty ? nil : String(decoding: line, as: UTF8.self) }
            if b == UInt8(ascii: "\n") { return String(decoding: line, as: UTF8.self) }
            line.append(b)
        }
    }

    /// Drains remaining output so the exit status is known.
    func finish() async throws {
        while try await read() != nil {}
    }
}

/// The two ends of the SCP protocol used by `SCPFileSystem`.
enum SCPTransfer {
    static let zero = Data([0])

    /// Reads one status byte; throws for warnings and errors.
    static func expectOK(_ io: ExecIO, path: String) async throws {
        guard let b = try await io.readByte() else {
            try await io.finish()
            throw failure(io, path: path, fallback: "scp ended unexpectedly")
        }
        if b == SCPProtocol.ok { return }
        let message = (b == SCPProtocol.warning || b == SCPProtocol.fatal) ? (try await io.readLine() ?? "") : ""
        throw SCPProtocol.error(status: b, message: message, path: path)
    }

    static func failure(_ io: ExecIO, path: String, fallback: String) -> RemoteError {
        let text = String(decoding: io.stderr, as: UTF8.self)
        return ShellErrors.map(text.isEmpty ? fallback : text, path: path, exitStatus: io.exitStatus)
    }

    /// Sink side (`scp -f` on the server sends the file).
    static func receive(_ io: ExecIO, path: String, output: FileHandle,
                        progress: TransferProgressHandler) async throws {
        try await io.write(zero)
        var header: SCPProtocol.FileHeader?
        while header == nil {
            guard let first = try await io.readByte() else {
                try await io.finish()
                throw failure(io, path: path, fallback: "No such file or directory")
            }
            switch first {
            case UInt8(ascii: "C"):
                let rest = try await io.readLine() ?? ""
                guard let h = SCPProtocol.parseFileHeader("C" + rest) else {
                    throw RemoteError.invalidResponse("Unexpected scp header: C\(rest)")
                }
                header = h
            case UInt8(ascii: "T"):
                _ = try await io.readLine()
                try await io.write(zero)
            case UInt8(ascii: "D"):
                throw RemoteError.unsupported("SCP (shell) downloads folders file by file.")
            case SCPProtocol.warning, SCPProtocol.fatal:
                let message = try await io.readLine() ?? ""
                throw SCPProtocol.error(status: first, message: message, path: path)
            default:
                throw RemoteError.invalidResponse("Unexpected scp reply.")
            }
        }
        try await io.write(zero)
        var remaining = header!.size
        var received: UInt64 = 0
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try await io.read(max: Int(min(remaining, UInt64(SCPFileSystem.chunkSize * 4)))) else {
                throw RemoteError.protocolError("The connection ended before the file was complete.")
            }
            do { try output.write(contentsOf: chunk) } catch { throw RemoteError.localIO(error.localizedDescription) }
            remaining -= UInt64(chunk.count)
            received += UInt64(chunk.count)
            progress(received)
        }
        try await expectOK(io, path: path)
        try await io.write(zero)
        try? await io.writer.sendEOF()
        try await io.finish()
    }

    /// Source side (`scp -t` on the server receives the file).
    static func send(_ io: ExecIO, path: String, input: FileHandle, size: UInt64,
                     progress: TransferProgressHandler) async throws {
        try await expectOK(io, path: path)
        try await io.write(try SCPProtocol.fileHeader(mode: 0o644, size: size, name: RemotePath.lastComponent(path)))
        try await expectOK(io, path: path)
        var sent: UInt64 = 0
        while sent < size {
            try Task.checkCancellation()
            let want = Int(min(UInt64(SCPFileSystem.chunkSize), size - sent))
            guard let data = try input.read(upToCount: want), !data.isEmpty else {
                throw RemoteError.localIO("The local file changed while it was being uploaded.")
            }
            try await io.write(data)
            if io.outputClosed { break }
            sent += UInt64(data.count)
            progress(sent)
        }
        try await io.write(zero)
        try await expectOK(io, path: path)
        try? await io.writer.sendEOF()
        try await io.finish()
    }
}
