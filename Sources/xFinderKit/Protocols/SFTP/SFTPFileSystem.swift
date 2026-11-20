import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// SFTP over SSH (Citadel / NIOSSH).
public final class SFTPFileSystem: RemoteFileSystem, @unchecked Sendable {
    public static let chunkSize = 32 * 1024
    public static let concurrentRequests = 16
    public static let connectTimeout: Int64 = 20

    public let config: ConnectionConfig
    let environment: ConnectionEnvironment
    private let cached: CachedCredentials?

    private let state = Locked<(client: SSHClient?, sftp: SFTPClient?, home: String, credentials: CachedCredentials?)>(
        (nil, nil, "/", nil))
    private let disconnectHandler = Locked<(@Sendable () -> Void)?>(nil)

    public init(config: ConnectionConfig, environment: ConnectionEnvironment, cachedCredentials: CachedCredentials? = nil) {
        self.config = config
        self.environment = environment
        self.cached = cachedCredentials
    }

    public var capabilities: RemoteCapabilities { .sftp }
    public var homeDirectory: String { state.value.home }
    public var isConnected: Bool { state.value.client?.isConnected ?? false }

    public func setDisconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        disconnectHandler.value = handler
    }

    // MARK: Connect

    public func connect() async throws {
        let (client, creds) = try await SSHConnector.connect(config: config, environment: environment, cached: cached)
        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP()
        } catch {
            try? await client.close()
            throw Self.mapOpenSFTPError(error)
        }
        let home = (try? await withTimeout(Self.requestTimeout) { try await sftp.getRealPath(atPath: ".") }) ?? "/"
        state.value = (client, sftp, home, creds)
        client.onDisconnect { [weak self] in
            self?.disconnectHandler.value?()
        }
    }

    /// Bound for the first request after the SFTP session opened.
    static let requestTimeout: Double = 15

    /// Error shown when SSH login worked but the SFTP session could not start.
    static func mapOpenSFTPError(_ error: Error) -> RemoteError {
        switch error as? SFTPError {
        case .subsystemRejected?:
            return .sftpUnavailable
        case .missingResponse?:
            return .connectionFailed("Signed in, but the server did not answer the SFTP request within 15 seconds.")
        case .unsupportedVersion(let v)?:
            return .connectionFailed("Signed in, but the server's SFTP version (\(v.rawValue)) is not supported.")
        default:
            return .connectionFailed("Signed in, but the SFTP session could not be started (\(error.localizedDescription)).")
        }
    }

    public func disconnect() async {
        let (client, sftp, _, _) = state.value
        state.withLock { $0.client = nil; $0.sftp = nil }
        try? await sftp?.close()
        try? await client?.close()
    }

    public func makeTransferConnection() async throws -> RemoteFileSystem {
        let fs = SFTPFileSystem(config: config, environment: environment,
                                cachedCredentials: state.value.credentials ?? cached)
        try await fs.connect()
        return fs
    }

    private func sftp() throws -> SFTPClient {
        guard let s = state.value.sftp, s.isActive else { throw RemoteError.notConnected }
        return s
    }

    // MARK: Error mapping

    static func map(_ error: Error, path: String) -> Error {
        if error is CancellationError { return error }
        if let r = error as? RemoteError { return r }
        if let status = error as? SFTPMessage.Status { return mapStatus(status, path: path) }
        if let e = error as? SFTPError {
            switch e {
            case .errorStatus(let status): return mapStatus(status, path: path)
            case .connectionClosed, .noResponseTarget: return RemoteError.notConnected
            default: return RemoteError.protocolError("SFTP error: \(e)")
            }
        }
        if error is ChannelError { return RemoteError.notConnected }
        return RemoteError.protocolError(error.localizedDescription)
    }

    static func mapStatus(_ status: SFTPMessage.Status, path: String) -> RemoteError {
        switch status.errorCode {
        case .noSuchFile: return .notFound(path)
        case .permissionDenied: return .permissionDenied(path)
        case .unsupportedOperation: return .unsupported(status.message)
        case .noConnection, .connectionLost: return .notConnected
        default: return .protocolError(status.message.isEmpty ? "The server reported a failure for \(path)." : status.message)
        }
    }

    private func run<T>(_ path: String, _ body: (SFTPClient) async throws -> T) async throws -> T {
        do { return try await body(try sftp()) } catch { throw Self.map(error, path: path) }
    }

    // MARK: Listing

    static func itemType(_ attrs: SFTPFileAttributes, longname: String) -> RemoteItemType {
        if let p = attrs.permissions {
            switch p & 0o170000 {
            case 0o040000: return .directory
            case 0o120000: return .symlink
            case 0o100000: return .file
            case 0: break
            default: return .other
            }
        }
        switch longname.first {
        case "d": return .directory
        case "l": return .symlink
        case "-": return .file
        default: return .file
        }
    }

    static func item(name: String, path: String, attrs: SFTPFileAttributes, longname: String) -> RemoteItem {
        var owner: String?
        var group: String?
        let cols = longname.split(separator: " ", omittingEmptySubsequences: true)
        if cols.count >= 4, cols[0].count >= 10 {
            owner = String(cols[2]); group = String(cols[3])
        } else if let ug = attrs.uidgid {
            owner = String(ug.userId); group = String(ug.groupId)
        }
        return RemoteItem(name: name, path: path, type: itemType(attrs, longname: longname), size: attrs.size,
                          modificationDate: attrs.accessModificationTime?.modificationTime,
                          permissions: attrs.permissions.map { $0 & 0o7777 }, owner: owner, group: group)
    }

    public func list(_ path: String) async throws -> [RemoteItem] {
        try await run(path) { sftp in
            let names = try await sftp.listDirectory(atPath: path)
            var items: [RemoteItem] = []
            for name in names {
                for c in name.components where c.filename != "." && c.filename != ".." {
                    items.append(Self.item(name: c.filename, path: RemotePath.join(path, c.filename),
                                           attrs: c.attributes, longname: c.longname))
                }
            }
            // Resolve symlinks to absolute targets and learn whether they are folders.
            let links = items.indices.filter { items[$0].type == .symlink }
            if !links.isEmpty {
                let resolved = await withTaskGroup(of: (Int, String?, Bool?).self) { group -> [(Int, String?, Bool?)] in
                    for i in links {
                        let p = items[i].path
                        group.addTask {
                            let target = try? await sftp.getRealPath(atPath: p)
                            var isDir: Bool?
                            if let attrs = try? await sftp.getAttributes(at: p) {
                                isDir = Self.itemType(attrs, longname: "") == .directory
                            } else if target != nil {
                                isDir = nil
                            }
                            return (i, target, isDir)
                        }
                    }
                    var out: [(Int, String?, Bool?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                for (i, target, isDir) in resolved {
                    items[i].symlinkTarget = target
                    items[i].symlinkTargetIsDirectory = isDir
                }
            }
            return items
        }
    }

    public func stat(_ path: String) async throws -> RemoteItem {
        try await run(path) { sftp in
            let attrs = try await sftp.getAttributes(at: path)
            var item = Self.item(name: RemotePath.lastComponent(path), path: path, attrs: attrs, longname: "")
            if let real = try? await sftp.getRealPath(atPath: path), RemotePath.normalize(real) != RemotePath.normalize(path),
               RemotePath.normalize(real) != RemotePath.normalize(RemotePath.join(homeDirectory, path)) {
                // The path is (or goes through) a symlink.
                item.symlinkTarget = real
                item.symlinkTargetIsDirectory = item.type == .directory
            }
            return item
        }
    }

    public func symlinkTarget(_ path: String) async throws -> String {
        try await run(path) { try await $0.getRealPath(atPath: path) }
    }

    public func rename(_ from: String, to: String) async throws {
        try await run(from) { try await $0.rename(at: from, to: to) }
    }

    public func delete(_ path: String, isDirectory: Bool) async throws {
        try await run(path) { sftp in
            if isDirectory {
                try await self.deleteRecursively(path, sftp: sftp)
            } else {
                try await sftp.remove(at: path)
            }
        }
    }

    private func deleteRecursively(_ path: String, sftp: SFTPClient) async throws {
        try Task.checkCancellation()
        let names = try await sftp.listDirectory(atPath: path)
        for name in names {
            for c in name.components where c.filename != "." && c.filename != ".." {
                let child = RemotePath.join(path, c.filename)
                if Self.itemType(c.attributes, longname: c.longname) == .directory {
                    try await deleteRecursively(child, sftp: sftp)
                } else {
                    try await sftp.remove(at: child)
                }
            }
        }
        try await sftp.rmdir(at: path)
    }

    public func createDirectory(_ path: String) async throws {
        try await run(path) { try await $0.createDirectory(atPath: path) }
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        try await run(path) { sftp in
            var attrs = SFTPFileAttributes()
            attrs.permissions = mode & 0o7777
            try await sftp.setAttributes(at: path, to: attrs)
        }
    }

    public func setModificationDate(_ path: String, date: Date) async throws {
        try await run(path) { sftp in
            let attrs = SFTPFileAttributes(accessModificationTime: .init(accessTime: date, modificationTime: date))
            try await sftp.setAttributes(at: path, to: attrs)
        }
    }

    /// Server-side copy via `cp -pR`. Throws `.unsupported` when commands cannot run.
    public func copyItem(_ from: String, to: String) async throws {
        guard let client = state.value.client else { throw RemoteError.notConnected }
        let marker = "XFINDER_CP_STATUS:"
        let command = "cp -pR -- \(ShellQuote.quote(from)) \(ShellQuote.quote(to)) 2>&1; echo \(marker)$?"
        let output: String
        do {
            let buffer = try await client.executeCommand(command, maxResponseSize: 1 << 20)
            output = String(buffer: buffer)
        } catch {
            throw RemoteError.unsupported("This server does not allow running commands.")
        }
        guard let range = output.range(of: marker, options: .backwards) else {
            throw RemoteError.unsupported("This server does not allow running commands.")
        }
        let code = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if code != "0" {
            let message = output[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if code == "127" { throw RemoteError.unsupported("`cp` is not available on the server.") }
            if message.localizedCaseInsensitiveContains("permission denied") { throw RemoteError.permissionDenied(to) }
            if message.localizedCaseInsensitiveContains("no such file") { throw RemoteError.notFound(from) }
            throw RemoteError.protocolError(message.isEmpty ? "Copy failed (exit status \(code))." : message)
        }
    }

    // MARK: Transfers

    public func download(_ remotePath: String, to localURL: URL, offset: UInt64,
                         progress: @escaping TransferProgressHandler) async throws {
        let sftp = try sftp()
        let file: SFTPFile
        do { file = try await sftp.openFile(filePath: remotePath, flags: .read) } catch { throw Self.map(error, path: remotePath) }
        defer { Task { try? await file.close() } }

        let fm = FileManager.default
        if offset == 0 || !fm.fileExists(atPath: localURL.path) {
            guard fm.createFile(atPath: localURL.path, contents: nil) else {
                throw RemoteError.localIO("Cannot create \(localURL.path)")
            }
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: localURL) } catch { throw RemoteError.localIO(error.localizedDescription) }
        defer { try? handle.close() }
        do {
            if offset > 0 { try handle.truncate(atOffset: offset); try handle.seek(toOffset: offset) } else { try handle.truncate(atOffset: 0) }
        } catch { throw RemoteError.localIO(error.localizedDescription) }

        let size = (try? await file.readAttributes())?.size
        var position = offset
        progress(position)
        let chunk = UInt32(Self.chunkSize)

        do {
            if let size {
                var nextOffset = position
                var inflight: [(UInt64, Task<ByteBuffer, Error>)] = []
                func enqueue() {
                    while inflight.count < Self.concurrentRequests && nextOffset < size {
                        let o = nextOffset
                        let len = UInt32(min(UInt64(chunk), size - o))
                        inflight.append((o, Task { try await file.read(from: o, length: len) }))
                        nextOffset += UInt64(len)
                    }
                }
                enqueue()
                while !inflight.isEmpty {
                    if Task.isCancelled { inflight.forEach { $0.1.cancel() }; throw CancellationError() }
                    let (o, task) = inflight.removeFirst()
                    var buffer = try await task.value
                    let expected = min(UInt64(chunk), size - o)
                    var got = UInt64(buffer.readableBytes)
                    if let bytes = buffer.readBytes(length: buffer.readableBytes) { try handle.write(contentsOf: bytes) }
                    // Short read: fetch the remainder before continuing in order.
                    while got < expected {
                        var more = try await file.read(from: o + got, length: UInt32(expected - got))
                        if more.readableBytes == 0 { break }
                        got += UInt64(more.readableBytes)
                        if let bytes = more.readBytes(length: more.readableBytes) { try handle.write(contentsOf: bytes) }
                    }
                    position = o + got
                    progress(position)
                    if got < expected { break } // file shrank (EOF)
                    enqueue()
                }
                inflight.forEach { $0.1.cancel() }
                // The file may have grown since we stat'ed it.
                while true {
                    try Task.checkCancellation()
                    var buffer = try await file.read(from: position, length: chunk)
                    if buffer.readableBytes == 0 { break }
                    position += UInt64(buffer.readableBytes)
                    if let bytes = buffer.readBytes(length: buffer.readableBytes) { try handle.write(contentsOf: bytes) }
                    progress(position)
                }
            } else {
                while true {
                    try Task.checkCancellation()
                    var buffer = try await file.read(from: position, length: chunk)
                    if buffer.readableBytes == 0 { break }
                    position += UInt64(buffer.readableBytes)
                    if let bytes = buffer.readBytes(length: buffer.readableBytes) { try handle.write(contentsOf: bytes) }
                    progress(position)
                }
            }
        } catch {
            throw Self.map(error, path: remotePath)
        }
    }

    public func upload(_ localURL: URL, to remotePath: String, offset: UInt64,
                       progress: @escaping TransferProgressHandler) async throws {
        let sftp = try sftp()
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: localURL) } catch { throw RemoteError.localIO(error.localizedDescription) }
        defer { try? input.close() }
        let flags: SFTPOpenFileFlags = offset == 0 ? [.write, .create, .truncate] : [.write, .create]
        let file: SFTPFile
        do { file = try await sftp.openFile(filePath: remotePath, flags: flags) } catch { throw Self.map(error, path: remotePath) }
        var closed = false
        defer { if !closed { Task { try? await file.close() } } }
        do {
            if offset > 0 { try input.seek(toOffset: offset) }
            var position = offset
            progress(position)
            var inflight: [(Int, Task<Void, Error>)] = []
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty else { break }
                let o = position
                let buffer = ByteBuffer(bytes: data)
                inflight.append((data.count, Task { try await file.write(buffer, at: o) }))
                position += UInt64(data.count)
                if inflight.count >= Self.concurrentRequests {
                    let (n, t) = inflight.removeFirst()
                    try await t.value
                    _ = n
                    progress(position - UInt64(inflight.reduce(0) { $0 + $1.0 }))
                }
            }
            for (_, t) in inflight { try await t.value }
            progress(position)
            closed = true
            try await file.close()
        } catch {
            throw Self.map(error, path: remotePath)
        }
    }
}

// MARK: - Host key validation

final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let environment: ConnectionEnvironment
    let rejected = Locked(false)

    init(host: String, port: Int, environment: ConnectionEnvironment) {
        self.host = host
        self.port = port
        self.environment = environment
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = SSHFingerprint.sha256(hostKey)
        let keyType = SSHFingerprint.keyType(hostKey)
        let check = environment.knownHosts.checkHostKey(host: host, port: port, fingerprint: fingerprint)
        if check == .trusted {
            validationCompletePromise.succeed(())
            return
        }
        var previous: String?
        if case .changed(let p) = check { previous = p }
        let prompt = HostKeyPrompt(host: host, port: port, keyType: keyType, fingerprint: fingerprint, previousFingerprint: previous)
        let env = environment
        let host = self.host, port = self.port
        let rejected = self.rejected
        Task {
            if await env.interaction.confirmHostKey(prompt) {
                env.knownHosts.trustHostKey(host: host, port: port, fingerprint: fingerprint, keyType: keyType)
                validationCompletePromise.succeed(())
            } else {
                rejected.value = true
                validationCompletePromise.fail(RemoteError.hostKeyRejected)
            }
        }
    }
}

// MARK: - User authentication

/// Tries keys and passwords in the configured order. A passphrase is asked at
/// most 4 times and a password 3 times. Successful credentials stay in memory.
final class SSHAuthenticator: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    enum Step {
        case key(SSHKeyEntry)
        case loadedKey(LoadedPrivateKey)
        case password
        case fixedPassword(String)
    }

    enum Offered {
        case key(LoadedPrivateKey)
        case password(PasswordBroker.Obtained)
        case fixedPassword(String)
    }

    let config: ConnectionConfig
    let environment: ConnectionEnvironment
    let cancelled = Locked(false)
    let started = Locked(false)
    let failure = Locked<RemoteError?>(nil)

    private var steps: [Step]
    private var pendingKeyOffers: [NIOSSHPrivateKey] = []
    private var currentKey: LoadedPrivateKey?
    private var passwordAttempt = 0
    private var lastOffered: Offered?
    private let lock = NSLock()

    init(config: ConnectionConfig, environment: ConnectionEnvironment, cached: CachedCredentials?) {
        self.config = config
        self.environment = environment
        var steps: [Step] = []
        if let cached {
            if let k = cached.key { steps.append(.loadedKey(k)) }
            if let p = cached.password { steps.append(.fixedPassword(p)) }
        } else {
            let r = config.resolved
            let keyStep: [Step] = r.key.map { [.key($0)] } ?? []
            let pwStep: [Step] = r.allowsPassword ? [.password] : []
            steps = r.authOrder == .keyFirst ? keyStep + pwStep : pwStep + keyStep
        }
        self.steps = steps
    }

    var successfulCredentials: CachedCredentials? {
        lock.lock(); defer { lock.unlock() }
        switch lastOffered {
        case .key(let k): return CachedCredentials(key: k)
        case .password(let o): return CachedCredentials(password: o.secret)
        case .fixedPassword(let p): return CachedCredentials(password: p)
        case nil: return nil
        }
    }

    func commitSuccess() async {
        let offered: Offered? = { lock.lock(); defer { lock.unlock() }; return lastOffered }()
        if case .password(let o) = offered, config.allowSavingSecrets {
            await environment.broker.commit(o, keychainAccount: config.resolved.passwordKeychainAccount)
        }
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        started.value = true
        Task {
            do {
                let offer = try await self.next(availableMethods)
                if offer == nil && self.failure.value == nil {
                    self.failure.value = .authenticationFailed("The server rejected all authentication methods.")
                }
                nextChallengePromise.succeed(offer)
            } catch {
                nextChallengePromise.fail(error)
            }
        }
    }

    private func makeOffer(_ offer: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHUserAuthenticationOffer {
        NIOSSHUserAuthenticationOffer(username: config.username, serviceName: "", offer: offer)
    }

    private func next(_ available: NIOSSHAvailableUserAuthenticationMethods) async throws -> NIOSSHUserAuthenticationOffer? {
        // A previous password offer was rejected.
        if case .password(let o) = lastOffered {
            await environment.broker.rejected(o, keychainAccount: config.resolved.passwordKeychainAccount)
            if passwordAttempt < PasswordBroker.maxPasswordAttempts, available.contains(.password) {
                return try await offerPassword()
            }
            failure.value = .authenticationFailed("The password was rejected.")
        }
        if !pendingKeyOffers.isEmpty, available.contains(.publicKey), let key = currentKey {
            let k = pendingKeyOffers.removeFirst()
            lastOffered = .key(key)
            return makeOffer(.privateKey(.init(privateKey: k)))
        }
        pendingKeyOffers = []
        while !steps.isEmpty {
            let step = steps.removeFirst()
            switch step {
            case .key(let entry):
                guard available.contains(.publicKey) else { continue }
                guard let key = try await loadKey(entry) else { continue }
                currentKey = key
                pendingKeyOffers = key.nioKeys
                let k = pendingKeyOffers.removeFirst()
                lastOffered = .key(key)
                return makeOffer(.privateKey(.init(privateKey: k)))
            case .loadedKey(let key):
                guard available.contains(.publicKey) else { continue }
                currentKey = key
                pendingKeyOffers = key.nioKeys
                let k = pendingKeyOffers.removeFirst()
                lastOffered = .key(key)
                return makeOffer(.privateKey(.init(privateKey: k)))
            case .password:
                guard available.contains(.password) else { continue }
                return try await offerPassword()
            case .fixedPassword(let p):
                guard available.contains(.password) else { continue }
                lastOffered = .fixedPassword(p)
                return makeOffer(.password(.init(password: p)))
            }
        }
        lastOffered = nil
        return nil
    }

    private func offerPassword() async throws -> NIOSSHUserAuthenticationOffer {
        passwordAttempt += 1
        let prompt = SecretPrompt(kind: .password, title: "Password for \(config.username)@\(config.hostLabel)",
                                  message: passwordAttempt > 1 ? "The password was not accepted. Try again." : "Enter the password.",
                                  attempt: passwordAttempt, allowSave: config.allowSavingSecrets, originID: config.originID)
        guard let obtained = await environment.broker.obtain(keychainAccount: config.resolved.passwordKeychainAccount, prompt: prompt) else {
            cancelled.value = true
            throw RemoteError.cancelledByUser
        }
        lastOffered = .password(obtained)
        return makeOffer(.password(.init(password: obtained.secret)))
    }

    /// Loads (and if needed decrypts) a key. Returns nil if the user skipped it.
    private func loadKey(_ entry: SSHKeyEntry) async throws -> LoadedPrivateKey? {
        do {
            return try SSHPrivateKeyLoader.load(path: entry.path, passphrase: nil)
        } catch SSHKeyError.passphraseRequired {
            // Fall through to passphrase prompts.
        } catch {
            failure.value = .authenticationFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return nil
        }
        let account = KeychainAccountName.keyPassphrase(entry.id)
        for attempt in 1...PasswordBroker.maxPassphraseAttempts {
            let prompt = SecretPrompt(kind: .passphrase, title: "Passphrase for key \"\(entry.alias)\"",
                                      message: attempt > 1 ? "The passphrase is incorrect. Try again." : "Enter the passphrase for \(entry.path).",
                                      attempt: attempt, allowSave: config.allowSavingSecrets, originID: config.originID)
            guard let obtained = await environment.broker.obtain(keychainAccount: account, prompt: prompt) else {
                return nil // skipped: continue with the next method
            }
            do {
                let key = try SSHPrivateKeyLoader.load(path: entry.path, passphrase: obtained.secret)
                if config.allowSavingSecrets { await environment.broker.commit(obtained, keychainAccount: account) }
                return key
            } catch SSHKeyError.wrongPassphrase {
                if obtained.fromKeychain { environment.secrets.delete(account) }
                continue
            } catch {
                failure.value = .authenticationFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                return nil
            }
        }
        failure.value = .authenticationFailed("The key passphrase is incorrect.")
        return nil
    }
}
