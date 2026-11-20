import Foundation
import Crypto

/// AWS Signature Version 4 for S3.
public struct S3Signer: Sendable {
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public var accessKey: String
    public var secretKey: String
    public var region: String
    public var service = "s3"

    public init(accessKey: String, secretKey: String, region: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
    }

    static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// Canonical query string: keys and values strictly encoded, sorted by key.
    public static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        let pairs: [(String, String)] = items.map { item in
            (URLEncoding.strict(item.name), URLEncoding.strict(item.value ?? ""))
        }
        let sorted = pairs.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        return sorted.map { (p: (String, String)) -> String in p.0 + "=" + p.1 }.joined(separator: "&")
    }

    /// Host header value as URLSession sends it.
    public static func hostHeader(_ url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, !(url.scheme == "https" && port == 443) && !(url.scheme == "http" && port == 80) {
            return "\(host):\(port)"
        }
        return host
    }

    public struct Signed: Sendable {
        public var headers: [String: String]
        public var canonicalRequest: String
        public var stringToSign: String
        public var signature: String
    }

    /// Signs a request. `headers` are signed in addition to host, x-amz-date and
    /// x-amz-content-sha256 (pass the URL with its path already percent-encoded).
    public func sign(method: String, url: URL, query: [URLQueryItem], headers: [String: String] = [:],
                     payloadHash: String = S3Signer.unsignedPayload, date: Date = Date()) -> Signed {
        let amz = Self.amzDate(date)
        let day = String(amz.prefix(8))
        var all: [String: String] = [:]
        for (k, v) in headers { all[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        all["host"] = Self.hostHeader(url)
        all["x-amz-date"] = amz
        all["x-amz-content-sha256"] = payloadHash
        let names = all.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(all[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        let canonical = [method, path, Self.canonicalQuery(query), canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let hashed = SHA256.hash(data: Data(canonical.utf8)).hex
        let stringToSign = ["AWS4-HMAC-SHA256", amz, scope, hashed].joined(separator: "\n")
        func hmac(_ key: SymmetricKey, _ s: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key)))
        }
        var key = hmac(SymmetricKey(data: Data(("AWS4" + secretKey).utf8)), day)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)).hex
        var out = all
        out.removeValue(forKey: "host")
        out["authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return Signed(headers: out, canonicalRequest: canonical, stringToSign: stringToSign, signature: signature)
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
