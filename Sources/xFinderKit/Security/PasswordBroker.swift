import Foundation

/// Obtains passwords and passphrases: Keychain first, then the user.
///
/// - Simultaneous requests for the same Keychain item share a single prompt.
/// - At most `maxAttempts` attempts per connection.
/// - A secret is written to the Keychain only after it worked and the user chose
///   to save it (`commit`).
public actor PasswordBroker {
    public let secrets: SecretStore
    public let interaction: ConnectionInteraction
    public static let maxPasswordAttempts = 3
    public static let maxPassphraseAttempts = 4

    private var inflight: [String: Task<SecretReply?, Never>] = [:]

    public init(secrets: SecretStore, interaction: ConnectionInteraction) {
        self.secrets = secrets
        self.interaction = interaction
    }

    public struct Obtained: Sendable {
        public var secret: String
        public var fromKeychain: Bool
        public var save: Bool
    }

    /// Returns a secret for `keychainAccount`. On the first attempt the Keychain
    /// is consulted; later attempts (after a rejection) always prompt.
    public func obtain(keychainAccount: String?, prompt: SecretPrompt) async -> Obtained? {
        if prompt.attempt == 1, let account = keychainAccount, let stored = secrets.read(account) {
            return Obtained(secret: stored, fromKeychain: true, save: false)
        }
        let dedupeKey = (keychainAccount ?? UUID().uuidString) + "#\(prompt.attempt)"
        if let existing = inflight[dedupeKey] {
            guard let r = await existing.value else { return nil }
            return Obtained(secret: r.secret, fromKeychain: false, save: r.save)
        }
        let interaction = self.interaction
        let task = Task { await interaction.requestSecret(prompt) }
        inflight[dedupeKey] = task
        let reply = await task.value
        inflight[dedupeKey] = nil
        guard let reply else { return nil }
        return Obtained(secret: reply.secret, fromKeychain: false, save: reply.save)
    }

    /// Call after a secret was accepted by the server.
    public func commit(_ obtained: Obtained, keychainAccount: String?) {
        guard obtained.save, !obtained.fromKeychain, let account = keychainAccount else { return }
        try? secrets.write(obtained.secret, for: account)
    }

    /// Call after a stored secret was rejected. Shared account passwords are kept
    /// (another server may still accept them); per-site passwords are removed.
    public func rejected(_ obtained: Obtained, keychainAccount: String?) {
        guard obtained.fromKeychain, let account = keychainAccount else { return }
        if account.hasPrefix("account-password.") { return }
        secrets.delete(account)
    }
}
