import Foundation

/// A trusted SSH host key or TLS certificate.
public struct TrustedFingerprint: Codable, Hashable, Sendable {
    public var fingerprint: String
    /// Key type (`ssh-ed25519`, …) or certificate subject summary.
    public var detail: String
    public var addedAt: Date

    public init(fingerprint: String, detail: String, addedAt: Date = Date()) {
        self.fingerprint = fingerprint
        self.detail = detail
        self.addedAt = addedAt
    }
}

public enum FingerprintCheck: Equatable, Sendable {
    case trusted
    case unknown
    /// The stored fingerprint differs: possible man-in-the-middle.
    case changed(previous: String)
}

/// App-owned trust store (`known_hosts.json`), separate from `~/.ssh/known_hosts`.
/// SSH entries are keyed `[host]:port`, TLS certificate entries `tls:[host]:port`.
public final class KnownHostsStore: @unchecked Sendable {
    struct FileFormat: Codable {
        var hosts: [String: TrustedFingerprint] = [:]
        var certificates: [String: TrustedFingerprint] = [:]
    }

    private let url: URL?
    private let lock = NSLock()
    private var data = FileFormat()

    public init(url: URL?) {
        self.url = url
        if let url, let loaded = try? JSONFile.load(FileFormat.self, from: url) { data = loaded }
    }

    public static func key(host: String, port: Int) -> String { "[\(host.lowercased())]:\(port)" }

    private func save() {
        guard let url else { return }
        try? JSONFile.save(data, to: url)
    }

    // MARK: SSH

    public func checkHostKey(host: String, port: Int, fingerprint: String) -> FingerprintCheck {
        lock.lock(); defer { lock.unlock() }
        guard let e = data.hosts[Self.key(host: host, port: port)] else { return .unknown }
        return e.fingerprint == fingerprint ? .trusted : .changed(previous: e.fingerprint)
    }

    public func trustHostKey(host: String, port: Int, fingerprint: String, keyType: String) {
        lock.lock()
        data.hosts[Self.key(host: host, port: port)] = TrustedFingerprint(fingerprint: fingerprint, detail: keyType)
        lock.unlock()
        save()
    }

    public var hostKeys: [(key: String, value: TrustedFingerprint)] {
        lock.lock(); defer { lock.unlock() }
        return data.hosts.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }

    public func removeHostKey(_ key: String) {
        lock.lock(); data.hosts[key] = nil; lock.unlock()
        save()
    }

    // MARK: TLS

    public func checkCertificate(host: String, port: Int, fingerprint: String) -> FingerprintCheck {
        lock.lock(); defer { lock.unlock() }
        guard let e = data.certificates[Self.key(host: host, port: port)] else { return .unknown }
        return e.fingerprint == fingerprint ? .trusted : .changed(previous: e.fingerprint)
    }

    public func trustCertificate(host: String, port: Int, fingerprint: String, summary: String) {
        lock.lock()
        data.certificates[Self.key(host: host, port: port)] = TrustedFingerprint(fingerprint: fingerprint, detail: summary)
        lock.unlock()
        save()
    }

    public var certificates: [(key: String, value: TrustedFingerprint)] {
        lock.lock(); defer { lock.unlock() }
        return data.certificates.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }

    public func removeCertificate(_ key: String) {
        lock.lock(); data.certificates[key] = nil; lock.unlock()
        save()
    }
}
