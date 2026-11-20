import Foundation
import Security
import Crypto

/// Decides whether to accept a TLS server certificate (FTPS, HTTPS).
///
/// Certificates trusted by macOS pass directly. Otherwise the SHA-256 of the leaf
/// DER is compared against fingerprints the user confirmed before; unknown or
/// changed fingerprints are shown to the user.
public final class TLSTrustEvaluator: @unchecked Sendable {
    public let store: KnownHostsStore
    public let interaction: ConnectionInteraction

    public init(store: KnownHostsStore, interaction: ConnectionInteraction) {
        self.store = store
        self.interaction = interaction
    }

    public static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public static func leaf(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    public func evaluate(_ trust: SecTrust, host: String, port: Int) async -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return true }
        guard let leaf = Self.leaf(of: trust) else { return false }
        let fp = Self.fingerprint(of: leaf)
        let check = store.checkCertificate(host: host, port: port, fingerprint: fp)
        if check == .trusted { return true }
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? host
        let issuer = ""
        var previous: String?
        if case .changed(let p) = check { previous = p }
        let prompt = CertificatePrompt(host: host, port: port, subject: subject, issuer: issuer, fingerprint: fp,
                                       previousFingerprint: previous,
                                       reason: (error as Error?)?.localizedDescription ?? "The certificate is not trusted.")
        let ok = await interaction.confirmCertificate(prompt)
        if ok { store.trustCertificate(host: host, port: port, fingerprint: fp, summary: subject) }
        return ok
    }
}
