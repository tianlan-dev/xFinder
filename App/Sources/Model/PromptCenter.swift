import SwiftUI
import xFinderKit

/// A prompt waiting for the user.
struct PendingPrompt: Identifiable {
    enum Kind {
        case hostKey(HostKeyPrompt, CheckedContinuation<Bool, Never>)
        case certificate(CertificatePrompt, CheckedContinuation<Bool, Never>)
        case secret(SecretPrompt, CheckedContinuation<SecretReply?, Never>)
    }
    let id = UUID()
    let kind: Kind

    var originID: UUID? {
        if case .secret(let p, _) = kind { return p.originID }
        return nil
    }
}

/// Bridges connection prompts (host keys, certificates, passwords, passphrases,
/// S3 secrets) from protocol code to SwiftUI sheets. Prompts are shown one at a
/// time, in order.
final class PromptCenter: ObservableObject, ConnectionInteraction, @unchecked Sendable {
    @MainActor @Published private(set) var current: PendingPrompt?
    @MainActor private var queue: [PendingPrompt] = []
    /// Called when a prompt from a background tab appears.
    @MainActor var onPromptForOrigin: ((UUID) -> Void)?

    @MainActor private func enqueue(_ p: PendingPrompt) {
        queue.append(p)
        if current == nil { advance() }
    }

    @MainActor private func advance() {
        current = queue.isEmpty ? nil : queue.removeFirst()
        if let origin = current?.originID { onPromptForOrigin?(origin) }
        if current != nil { NSApp.activate(ignoringOtherApps: false) }
    }

    @MainActor func finish() {
        current = nil
        DispatchQueue.main.async { self.advance() }
    }

    func confirmHostKey(_ prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { c in
            Task { @MainActor in self.enqueue(PendingPrompt(kind: .hostKey(prompt, c))) }
        }
    }

    func confirmCertificate(_ prompt: CertificatePrompt) async -> Bool {
        await withCheckedContinuation { c in
            Task { @MainActor in self.enqueue(PendingPrompt(kind: .certificate(prompt, c))) }
        }
    }

    func requestSecret(_ prompt: SecretPrompt) async -> SecretReply? {
        await withCheckedContinuation { c in
            Task { @MainActor in self.enqueue(PendingPrompt(kind: .secret(prompt, c))) }
        }
    }
}
