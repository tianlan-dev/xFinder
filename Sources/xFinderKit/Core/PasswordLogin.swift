import Foundation

/// Shared password flow for FTP, WebDAV and S3: Keychain first, then up to three
/// prompts; the secret is saved only after the server accepted it.
enum PasswordLogin {
    static func run<T>(config: ConnectionConfig, environment: ConnectionEnvironment, kind: SecretKind = .password,
                       cached: String?, body: (String) async throws -> T) async throws -> (T, String) {
        if let cached {
            return (try await body(cached), cached)
        }
        let account = config.resolved.passwordKeychainAccount
        var lastError: Error = RemoteError.authenticationFailed("")
        for attempt in 1...PasswordBroker.maxPasswordAttempts {
            let what = kind == .s3Secret ? "Secret Access Key" : "Password"
            let who = kind == .s3Secret ? "Access Key \(config.username)" : "\(config.username)@\(config.hostLabel)"
            let prompt = SecretPrompt(kind: kind, title: "\(what) for \(who)",
                                      message: attempt > 1 ? "The \(what.lowercased()) was not accepted. Try again." : "Enter the \(what.lowercased()).",
                                      attempt: attempt, allowSave: config.allowSavingSecrets, originID: config.originID)
            guard let obtained = await environment.broker.obtain(keychainAccount: account, prompt: prompt) else {
                throw RemoteError.cancelledByUser
            }
            do {
                let result = try await body(obtained.secret)
                if config.allowSavingSecrets { await environment.broker.commit(obtained, keychainAccount: account) }
                return (result, obtained.secret)
            } catch let e as RemoteError {
                guard case .authenticationFailed = e else { throw e }
                await environment.broker.rejected(obtained, keychainAccount: account)
                lastError = e
            }
        }
        throw lastError
    }
}

/// Serializes async work (FTP control channel commands).
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    func run<T>(_ body: () async throws -> T) async throws -> T {
        await lock()
        do {
            let r = try await body()
            unlock()
            return r
        } catch {
            unlock()
            throw error
        }
    }
}
