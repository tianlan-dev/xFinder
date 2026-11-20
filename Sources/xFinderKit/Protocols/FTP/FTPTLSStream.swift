import Foundation
import Network

/// Byte stream used for FTP control and data connections.
protocol FTPStream: AnyObject, Sendable {
    func write(_ data: Data) async throws
    /// Returns nil at end of stream.
    func read(maxLength: Int) async throws -> Data?
    /// Upgrades to TLS (explicit FTPS).
    func startTLS() async throws
    /// Half-closes the write side (end of an upload).
    func finishWriting() async
    func close()
}

/// Plain TCP via Network.framework.
final class NWStream: FTPStream, @unchecked Sendable {
    let connection: NWConnection

    private init(_ c: NWConnection) { connection = c }

    static func connect(host: String, port: Int, timeout: Double) async throws -> NWStream {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw RemoteError.connectionFailed("Invalid port \(port)") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let stream = NWStream(conn)
        let done = Locked(false)
        do {
            try await withTimeout(timeout) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    conn.stateUpdateHandler = { state in
                        func finish(_ r: Result<Void, Error>) {
                            let first = done.withLock { d -> Bool in defer { d = true }; return !d }
                            if first { cont.resume(with: r) }
                        }
                        switch state {
                        case .ready: finish(.success(()))
                        case .failed(let e): finish(.failure(RemoteError.connectionFailed(e.localizedDescription)))
                        case .waiting(let e): finish(.failure(RemoteError.connectionFailed(e.localizedDescription)))
                        case .cancelled: finish(.failure(RemoteError.connectionFailed("Connection cancelled")))
                        default: break
                        }
                    }
                    conn.start(queue: DispatchQueue(label: "xfinder.ftp.nw"))
                }
            }
        } catch {
            conn.cancel()
            throw error
        }
        return stream
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: RemoteError.connectionFailed(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    func read(maxLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: nil) }
                else if let error {
                    // ENODATA / ECONNRESET after the peer finished sending mean end of stream.
                    if case .posix(let code) = error, code == .ENODATA { cont.resume(returning: nil); return }
                    cont.resume(throwing: RemoteError.connectionFailed(error.localizedDescription))
                }
                else { cont.resume(returning: nil) }
            }
        }
    }

    func startTLS() async throws { throw RemoteError.unsupported("TLS upgrade on a plain connection") }

    func finishWriting() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    func close() { connection.cancel() }
}

/// TLS-capable stream via URLSessionStreamTask (FTPS control and data connections).
final class TLSStream: NSObject, FTPStream, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var task: URLSessionStreamTask!
    let trust: TLSTrustEvaluator
    let trustHost: String
    let trustPort: Int
    let rejected = Locked(false)
    private let secured = Locked(false)

    init(host: String, port: Int, trust: TLSTrustEvaluator, trustPort: Int) {
        self.trust = trust
        trustHost = host
        self.trustPort = trustPort
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        task = session.streamTask(withHostName: host, port: port)
        task.resume()
    }

    static func connect(host: String, port: Int, trust: TLSTrustEvaluator, trustPort: Int, tls: Bool) async throws -> TLSStream {
        let s = TLSStream(host: host, port: port, trust: trust, trustPort: trustPort)
        if tls { try await s.startTLS() }
        return s
    }

    func startTLS() async throws {
        task.startSecureConnection()
        secured.value = true
    }

    private func map(_ error: Error) -> Error {
        if rejected.value { return RemoteError.hostKeyRejected }
        if let u = error as? URLError {
            if u.code == .timedOut { return RemoteError.timeout }
            return RemoteError.connectionFailed(u.localizedDescription)
        }
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain || ns.domain == "kCFStreamErrorDomainSSL" {
            return RemoteError.connectionFailed("TLS error: \(ns.localizedDescription)")
        }
        return RemoteError.connectionFailed(error.localizedDescription)
    }

    func write(_ data: Data) async throws {
        do { try await task.write(data, timeout: 60) } catch { throw map(error) }
    }

    func read(maxLength: Int) async throws -> Data? {
        while true {
            let result: (Data?, Bool)
            do { result = try await task.readData(ofMinLength: 1, maxLength: maxLength, timeout: 60) } catch { throw map(error) }
            if let d = result.0, !d.isEmpty { return d }
            if result.1 { return nil }
        }
    }

    func finishWriting() async {
        task.closeWrite()
    }

    func close() {
        task.cancel()
        session.invalidateAndCancel()
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completion(.performDefaultHandling, nil)
            return
        }
        let trust = self.trust, host = trustHost, port = trustPort, rejected = self.rejected
        Task {
            if await trust.evaluate(serverTrust, host: host, port: port) {
                completion(.useCredential, URLCredential(trust: serverTrust))
            } else {
                rejected.value = true
                completion(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }
}
