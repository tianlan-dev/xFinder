import Foundation

/// URLSession wrapper shared by WebDAV and S3: ephemeral session, 60-second
/// timeout, at most 4 connections per host, TLS trust via TLSTrustEvaluator and
/// Basic/Digest credentials.
final class HTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let timeout: TimeInterval = 60

    private(set) var session: URLSession!
    let trust: TLSTrustEvaluator
    let trustHost: String
    let trustPort: Int
    let credential = Locked<URLCredential?>(nil)
    let certificateRejected = Locked(false)
    /// S3 signs the host, so redirects must not be followed automatically.
    let followRedirects: Bool

    private final class StreamState: @unchecked Sendable {
        var onResponse: (HTTPURLResponse) throws -> (FileHandle, UInt64)?
        var progress: TransferProgressHandler
        var handle: FileHandle?
        var written: UInt64 = 0
        var body = Data()
        var response: HTTPURLResponse?
        var failure: Error?
        var continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?

        init(onResponse: @escaping (HTTPURLResponse) throws -> (FileHandle, UInt64)?, progress: @escaping TransferProgressHandler) {
            self.onResponse = onResponse
            self.progress = progress
        }
    }
    private let streams = Locked<[Int: StreamState]>([:])

    init(trust: TLSTrustEvaluator, host: String, port: Int, followRedirects: Bool = true) {
        self.followRedirects = followRedirects
        self.trust = trust
        trustHost = host
        trustPort = port
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.timeout
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }

    func invalidate() { session.invalidateAndCancel() }

    // MARK: Requests

    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RemoteError.invalidResponse("Not an HTTP response") }
            return (data, http)
        } catch {
            throw map(error)
        }
    }

    /// Streams a response body into a file. `onResponse` returns the file handle
    /// (and starting byte count) to write into, or nil to buffer the body (errors).
    func stream(_ request: URLRequest, progress: @escaping TransferProgressHandler,
                onResponse: @escaping (HTTPURLResponse) throws -> (FileHandle, UInt64)?) async throws -> (HTTPURLResponse, Data) {
        let task = session.dataTask(with: request)
        let state = StreamState(onResponse: onResponse, progress: progress)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    state.continuation = cont
                    streams.withLock { $0[task.taskIdentifier] = state }
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw map(error)
        }
    }

    func upload(_ request: URLRequest, fromFile url: URL, progress: @escaping TransferProgressHandler) async throws -> (Data, HTTPURLResponse) {
        let delegate = UploadProgressDelegate(progress: progress)
        do {
            let (data, response) = try await session.upload(for: request, fromFile: url, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw RemoteError.invalidResponse("Not an HTTP response") }
            return (data, http)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw map(error)
        }
    }

    func map(_ error: Error) -> Error {
        if error is RemoteError || error is CancellationError { return error }
        guard let u = error as? URLError else { return RemoteError.protocolError(error.localizedDescription) }
        switch u.code {
        case .timedOut: return RemoteError.timeout
        case .cancelled:
            if certificateRejected.value { return RemoteError.hostKeyRejected }
            return CancellationError()
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            if certificateRejected.value { return RemoteError.hostKeyRejected }
            return RemoteError.connectionFailed(u.localizedDescription)
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return RemoteError.authenticationFailed("")
        default:
            return RemoteError.connectionFailed(u.localizedDescription)
        }
    }

    // MARK: Delegate

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                completion(.performDefaultHandling, nil)
                return
            }
            let trust = self.trust, host = trustHost, port = trustPort, rejected = certificateRejected
            Task {
                if await trust.evaluate(serverTrust, host: host, port: port) {
                    completion(.useCredential, URLCredential(trust: serverTrust))
                } else {
                    rejected.value = true
                    completion(.cancelAuthenticationChallenge, nil)
                }
            }
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault:
            if challenge.previousFailureCount == 0, let c = credential.value {
                completion(.useCredential, c)
            } else {
                // Let the 401 through so the caller reports an authentication failure.
                completion(.rejectProtectionSpace, nil)
            }
        default:
            completion(.performDefaultHandling, nil)
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

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(followRedirects ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = streams.value[dataTask.taskIdentifier] else { completionHandler(.allow); return }
        guard let http = response as? HTTPURLResponse else {
            state.failure = RemoteError.invalidResponse("Not an HTTP response")
            completionHandler(.cancel)
            return
        }
        state.response = http
        do {
            if let (h, start) = try state.onResponse(http) {
                state.handle = h
                state.written = start
                state.progress(start)
            }
            completionHandler(.allow)
        } catch {
            state.failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = streams.value[dataTask.taskIdentifier], state.failure == nil else { return }
        if let h = state.handle {
            do {
                try h.write(contentsOf: data)
                state.written += UInt64(data.count)
                state.progress(state.written)
            } catch {
                state.failure = RemoteError.localIO(error.localizedDescription)
                dataTask.cancel()
            }
        } else if state.body.count < 1_000_000 {
            state.body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = streams.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? state.handle?.close()
        if let f = state.failure {
            state.continuation?.resume(throwing: f)
        } else if let error {
            state.continuation?.resume(throwing: error)
        } else if let r = state.response {
            state.continuation?.resume(returning: (r, state.body))
        } else {
            state.continuation?.resume(throwing: RemoteError.invalidResponse("No response"))
        }
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: TransferProgressHandler
    init(progress: @escaping TransferProgressHandler) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(UInt64(max(0, totalBytesSent)))
    }
}

/// Percent-encoding helpers for URLs and SigV4.
enum URLEncoding {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// RFC 3986 encoding of everything except unreserved characters.
    static func strict(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Encodes each path segment, keeping "/".
    static func path(_ p: String) -> String {
        p.split(separator: "/", omittingEmptySubsequences: false).map { strict(String($0)) }.joined(separator: "/")
    }
}

/// HTTP date formats used by WebDAV and S3.
enum HTTPDates {
    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for f in [rfc1123, iso8601Fractional, iso8601] {
            if let d = f(t) { return d }
        }
        return nil
    }

    static func rfc1123(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func iso8601Fractional(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func iso8601(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }
}
