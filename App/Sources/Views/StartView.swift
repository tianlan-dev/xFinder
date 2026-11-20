import SwiftUI
import xFinderKit

/// Quick Connect (SFTP) shown in empty tabs.
struct StartView: View {
    @ObservedObject var session: ConnectionSession
    @EnvironmentObject var app: AppModel
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var key: KeyChoice = .inherit
    @State private var initialPath = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Quick Connect").font(.title2.bold())
            Text("Connect to an SFTP server, or pick a favorite from the sidebar.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Server", text: $host, prompt: Text("host.example.com"))
                TextField("Port", text: $port, prompt: Text("22"))
                TextField("Username", text: $username, prompt: Text(NSUserName()))
                KeyPicker(selection: $key, allowInherit: true, inheritLabel: "Default key")
                TextField("Initial folder", text: $initialPath, prompt: Text("Home folder"))
            }
            .formStyle(.grouped)
            .frame(maxWidth: 460)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Save to Favorites") { save() }
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func makeSite() -> Site? {
        var site = Site(name: host, protocolType: .sftp, host: host.trimmingCharacters(in: .whitespaces),
                        port: Int(port.trimmingCharacters(in: .whitespaces)), username: username.trimmingCharacters(in: .whitespaces),
                        key: key, initialPath: initialPath)
        if !port.isEmpty && site.port == nil { error = "The port must be a number."; return nil }
        let problems = SiteValidation.validate(site)
        if let p = problems.first { error = p; return nil }
        site.name = host
        error = nil
        return site
    }

    private func connect() {
        guard let site = makeSite() else { return }
        session.open(site, quickConnect: true)
    }

    private func save() {
        guard var site = makeSite() else { return }
        site.name = app.library.uniqueSiteName(site.host)
        app.library.addSite(site)
        session.open(site)
    }
}

/// Picker for a key reference: inherit, "No key", then every key as
/// "alias (type · fingerprint prefix)".
struct KeyPicker: View {
    @Binding var selection: KeyChoice
    var allowInherit = true
    var inheritLabel = "Inherit"
    var title = "Key"
    @EnvironmentObject var app: AppModel

    var body: some View {
        Picker(title, selection: $selection) {
            if allowInherit { Text(inheritLabel).tag(KeyChoice.inherit) }
            Text("No key").tag(KeyChoice.none)
            if !app.keys.keys.isEmpty { Divider() }
            ForEach(app.keys.keys) { k in
                Text(app.keyLabel(k)).tag(KeyChoice.key(k.id))
            }
        }
    }
}

/// Picker for an optional auth order (nil = inherit).
struct AuthOrderPicker: View {
    @Binding var selection: AuthOrder?
    var inheritLabel = "Inherit"
    var title = "Auth order"

    var body: some View {
        Picker(title, selection: $selection) {
            Text(inheritLabel).tag(AuthOrder?.none)
            ForEach(AuthOrder.allCases) { o in Text(o.displayName).tag(AuthOrder?.some(o)) }
        }
    }
}
