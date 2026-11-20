import SwiftUI
import xFinderKit

/// Sheet content for the current connection prompt.
struct PromptSheet: View {
    let prompt: PendingPrompt
    @EnvironmentObject var prompts: PromptCenter

    var body: some View {
        switch prompt.kind {
        case .hostKey(let p, let c):
            HostKeyPromptView(prompt: p) { ok in c.resume(returning: ok); prompts.finish() }
        case .certificate(let p, let c):
            CertificatePromptView(prompt: p) { ok in c.resume(returning: ok); prompts.finish() }
        case .secret(let p, let c):
            SecretPromptView(prompt: p) { reply in c.resume(returning: reply); prompts.finish() }
        }
    }
}

struct HostKeyPromptView: View {
    let prompt: HostKeyPrompt
    let done: (Bool) -> Void

    var changed: Bool { prompt.previousFingerprint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: changed ? "exclamationmark.triangle.fill" : "lock.shield")
                    .font(.system(size: 32))
                    .foregroundStyle(changed ? .red : .accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(changed ? "The server's host key has changed!" : "Unknown server")
                        .font(.headline)
                    Text(changed
                         ? "The host key for \(prompt.host) (port \(prompt.port)) is different from the one you trusted before. This can mean someone is intercepting the connection, or the server was reinstalled."
                         : "xFinder has not connected to \(prompt.host) (port \(prompt.port)) before. Verify the fingerprint with the server administrator before trusting it.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Key type", value: prompt.keyType)
                    LabeledContent("Fingerprint") { Text(prompt.fingerprint).textSelection(.enabled).font(.system(.body, design: .monospaced)) }
                    if let old = prompt.previousFingerprint {
                        LabeledContent("Previous") { Text(old).textSelection(.enabled).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                }
                .padding(4)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button(changed ? "Trust New Key" : "Trust and Connect") { done(true) }
                    .keyboardShortcut(changed ? nil : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct CertificatePromptView: View {
    let prompt: CertificatePrompt
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prompt.previousFingerprint != nil ? "exclamationmark.triangle.fill" : "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(prompt.previousFingerprint != nil ? .red : .orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt.previousFingerprint != nil ? "The server's certificate has changed!" : "Untrusted certificate")
                        .font(.headline)
                    Text("macOS does not trust the certificate of \(prompt.host) (port \(prompt.port)): \(prompt.reason)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Subject", value: prompt.subject)
                    LabeledContent("SHA-256") { Text(prompt.fingerprint).textSelection(.enabled).font(.system(.caption, design: .monospaced)) }
                    if let old = prompt.previousFingerprint {
                        LabeledContent("Previous") { Text(old).textSelection(.enabled).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                }
                .padding(4)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust Certificate") { done(true) }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct SecretPromptView: View {
    let prompt: SecretPrompt
    let done: (SecretReply?) -> Void
    @State private var secret = ""
    @State private var save = true

    var fieldLabel: String {
        switch prompt.kind {
        case .password: return "Password"
        case .passphrase: return "Passphrase"
        case .s3Secret: return "Secret Access Key"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prompt.kind == .passphrase ? "key.fill" : "person.badge.key.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.title).font(.headline)
                    Text(prompt.message)
                        .foregroundStyle(prompt.attempt > 1 ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SecureField(fieldLabel, text: $secret)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if prompt.allowSave {
                Toggle("Save in Keychain", isOn: $save)
            }
            HStack {
                Spacer()
                Button(prompt.kind == .passphrase ? "Skip Key" : "Cancel", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        done(SecretReply(secret: secret, save: prompt.allowSave && save))
    }
}
