import Foundation
import Security

/// Hands a password to the SSH_ASKPASS helper of an external terminal.
///
/// The app issues a 32-byte random one-time token valid for 60 seconds. The helper
/// sends the token over a Unix socket that only the user can access (0600, peer UID
/// verified) and receives the password; it never touches disk or the command line.
public final class AskpassBroker: @unchecked Sendable {
    public static let tokenLifetime: TimeInterval = 60

    public let directory: URL
    public var socketPath: String { directory.appendingPathComponent("broker.sock").path }
    public var helperPath: String { directory.appendingPathComponent("askpass.sh").path }

    private struct Entry {
        var password: String
        var expires: Date
    }

    private let tokens = Locked<[String: Entry]>([:])
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "xfinder.askpass")
    private var source: DispatchSourceRead?

    public init(directory: URL) {
        self.directory = directory
    }

    deinit { stop() }

    // MARK: Tokens

    public func issueToken(password: String, now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        tokens.withLock { t in
            t = t.filter { $0.value.expires > now }
            t[token] = Entry(password: password, expires: now.addingTimeInterval(Self.tokenLifetime))
        }
        return token
    }

    /// Returns the password once; the token is consumed.
    public func redeem(_ token: String, now: Date = Date()) -> String? {
        tokens.withLock { t in
            guard let e = t.removeValue(forKey: token), e.expires > now else { return nil }
            return e.password
        }
    }

    // MARK: Helper script

    public static let helperScript = """
    #!/bin/zsh
    # xFinder SSH_ASKPASS helper. The first password prompt is answered by xFinder
    # (one-time token over a private Unix socket); everything else is asked in the terminal.
    prompt="$1"
    lower="${prompt:l}"
    if [[ -n "$XFINDER_ASKPASS_TOKEN" && "$lower" == *password* && "$lower" != *passphrase* && "$lower" != *verification* ]]; then
      answer=$(print -r -- "$XFINDER_ASKPASS_TOKEN" | /usr/bin/nc -U "$XFINDER_ASKPASS_SOCKET" 2>/dev/null)
      if [[ -n "$answer" ]]; then
        print -r -- "$answer"
        exit 0
      fi
    fi
    # Fall back to the terminal.
    print -rn -- "$prompt" > /dev/tty
    if [[ "$lower" == *"(yes/no"* ]]; then
      read -r reply < /dev/tty
    else
      read -rs reply < /dev/tty
      print "" > /dev/tty
    fi
    print -r -- "$reply"
    """

    public func installHelper() throws {
        _ = try AppPaths.ensureDirectory(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = Data(Self.helperScript.utf8)
        if (try? Data(contentsOf: URL(fileURLWithPath: helperPath))) != data {
            try? FileManager.default.removeItem(atPath: helperPath)
            guard FileManager.default.createFile(atPath: helperPath, contents: data, attributes: [.posixPermissions: 0o700]) else {
                throw RemoteError.localIO("Cannot write \(helperPath)")
            }
        }
    }

    // MARK: Socket server

    public var isRunning: Bool { listenFD >= 0 }

    public func start() throws {
        guard listenFD < 0 else { return }
        try installHelper()
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteError.localIO("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw RemoteError.localIO("Socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes)
            buf[pathBytes.count] = 0
        }
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0 else { close(fd); throw RemoteError.localIO("bind() failed: \(String(cString: strerror(errno)))") }
        chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); throw RemoteError.localIO("listen() failed") }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 256)
        var received = Data()
        while received.count < 200 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
            if received.contains(0x0A) { break }
        }
        let token = String(decoding: received, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let password = redeem(token) else { return }
        let reply = Array((password + "\n").utf8)
        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
    }
}
