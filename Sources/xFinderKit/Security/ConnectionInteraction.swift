import Foundation

public struct HostKeyPrompt: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var keyType: String
    public var fingerprint: String
    /// Set when the key changed since it was trusted.
    public var previousFingerprint: String?
}

public struct CertificatePrompt: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var subject: String
    public var issuer: String
    /// SHA-256 of the DER certificate, colon-separated hex.
    public var fingerprint: String
    public var previousFingerprint: String?
    public var reason: String
}

public enum SecretKind: String, Sendable {
    case password
    case s3Secret
    case passphrase
}

public struct SecretPrompt: Sendable, Hashable {
    public var kind: SecretKind
    public var title: String
    public var message: String
    /// 1-based attempt number.
    public var attempt: Int
    /// Whether "Save in Keychain" should be offered.
    public var allowSave: Bool
    /// Identifies the session/tab that asked (lets the UI switch to it).
    public var originID: UUID?
}

public struct SecretReply: Sendable, Hashable {
    public var secret: String
    public var save: Bool
    public init(secret: String, save: Bool) {
        self.secret = secret
        self.save = save
    }
}

/// User interaction needed while connecting. Implemented by the app's prompt UI.
public protocol ConnectionInteraction: AnyObject, Sendable {
    func confirmHostKey(_ prompt: HostKeyPrompt) async -> Bool
    func confirmCertificate(_ prompt: CertificatePrompt) async -> Bool
    /// Returns nil when the user cancels.
    func requestSecret(_ prompt: SecretPrompt) async -> SecretReply?
}

/// Non-interactive implementation: rejects unknown hosts and never prompts.
public final class NonInteractive: ConnectionInteraction, @unchecked Sendable {
    public let acceptUnknownHosts: Bool
    public let secrets: [SecretKind: String]
    public init(acceptUnknownHosts: Bool = false, secrets: [SecretKind: String] = [:]) {
        self.acceptUnknownHosts = acceptUnknownHosts
        self.secrets = secrets
    }
    public func confirmHostKey(_ prompt: HostKeyPrompt) async -> Bool { acceptUnknownHosts && prompt.previousFingerprint == nil }
    public func confirmCertificate(_ prompt: CertificatePrompt) async -> Bool { acceptUnknownHosts && prompt.previousFingerprint == nil }
    public func requestSecret(_ prompt: SecretPrompt) async -> SecretReply? {
        guard prompt.attempt == 1, let s = secrets[prompt.kind] else { return nil }
        return SecretReply(secret: s, save: false)
    }
}
