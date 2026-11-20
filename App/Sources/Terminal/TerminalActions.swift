import SwiftUI
import AppKit
import xFinderKit

/// Opens SSH sessions in Terminal, iTerm2 or Ghostty.
@MainActor
final class TerminalActions {
    unowned let app: AppModel
    private lazy var askpass = AskpassBroker(directory: app.paths.askpassDirectory)

    init(app: AppModel) { self.app = app }

    func open(site: Site, path: String?) {
        guard site.protocolType.isSSH else {
            alert("Terminal sessions are only available for SFTP and SCP (shell) servers.")
            return
        }
        let resolved = app.resolver.resolve(site)
        let spec = SSHCommandSpec(host: site.host, port: site.effectivePort, username: resolved.username,
                                  keyPath: resolved.key?.expandedPath, keyOnly: resolved.keyOnly,
                                  sshConfigAlias: site.sshConfigAlias, remotePath: path)
        do {
            let command = try SSHCommandBuilder.commandLine(spec)
            var helper: TerminalScript.Askpass?
            if resolved.allowsPassword, let password = app.secrets.read(resolved.passwordKeychainAccount) {
                try askpass.start()
                helper = TerminalScript.Askpass(helperPath: askpass.helperPath, socketPath: askpass.socketPath,
                                                token: askpass.issueToken(password: password))
            }
            let script = try TerminalScript.write(commandLine: command, askpass: helper, in: app.paths.terminalDirectory)
            try launch(script)
        } catch {
            alert((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func launch(_ script: URL) throws {
        switch app.settings.terminalApp {
        case .terminal:
            try openWith(bundleID: "com.apple.Terminal", url: script)
        case .iTerm2:
            let source = """
            tell application id "com.googlecode.iterm2"
                activate
                create window with default profile command "\(script.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
            end tell
            """
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err {
                throw RemoteError.protocolError("iTerm2 could not be controlled: \(err[NSAppleScript.errorMessage] ?? err)")
            }
        case .ghostty:
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
                throw RemoteError.protocolError("Ghostty is not installed.")
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            cfg.arguments = ["-e", script.path]
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
        }
    }

    private func openWith(bundleID: String, url: URL) throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw RemoteError.protocolError("The terminal application is not installed.")
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Cannot open a terminal"
        a.informativeText = message
        a.runModal()
    }
}
