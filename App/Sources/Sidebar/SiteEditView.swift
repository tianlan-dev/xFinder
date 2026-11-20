import SwiftUI
import xFinderKit

/// Server editor (also used for New Server): General, Authentication and
/// Folder sections, inheritance placeholders, a summary of how the server
/// signs in, live validation in the footer and Test.
struct SiteEditView: View {
    let original: Site
    let isNew: Bool
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var site = Site()
    @State private var portText = ""
    @State private var password = ""
    @State private var testing = false
    @State private var testResult: SiteConnectionTester.Result?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $site.name, prompt: Text("e.g. Production"))
                        .multilineTextAlignment(.trailing)
                        .focused($nameFocused)
                    Picker("Protocol", selection: $site.protocolType) {
                        ForEach(SiteProtocol.allCases) { p in Text(p.displayName).tag(p) }
                    }
                    TextField("Address", text: $site.host,
                              prompt: Text(site.protocolType == .s3 ? "Empty = Amazon S3; or an S3-compatible host" : "Hostname, IPv4 or IPv6"))
                        .multilineTextAlignment(.trailing)
                    TextField("Port", text: $portText, prompt: Text("\(site.protocolType.defaultPort)"))
                        .multilineTextAlignment(.trailing)
                    if site.protocolType.isWebDAV {
                        TextField("Base path", text: $site.webDAVBasePath, prompt: Text("/remote.php/dav/files/user"))
                            .multilineTextAlignment(.trailing)
                    }
                    if site.protocolType == .s3 {
                        TextField("Bucket", text: $site.s3Bucket).multilineTextAlignment(.trailing)
                        TextField("Region", text: $site.s3Region, prompt: Text("us-east-1")).multilineTextAlignment(.trailing)
                        if !isAWS { Toggle("Use plain HTTP", isOn: $site.s3UsePlainHTTP) }
                    }
                    Picker("Folder", selection: $site.folderID) {
                        Text("None").tag(UUID?.none)
                        if !app.library.folders.isEmpty { Divider() }
                        ForEach(app.library.folders) { f in Text(f.name).tag(UUID?.some(f.id)) }
                    }
                    if let warning = securityWarning {
                        Label(warning, systemImage: "exclamationmark.shield").foregroundStyle(.orange).font(.callout)
                    }
                }
                Section("Authentication") {
                    Picker("Account", selection: $site.accountID) {
                        Text(noAccountLabel).tag(UUID?.none)
                        if !sortedAccounts.isEmpty { Divider() }
                        ForEach(sortedAccounts) { a in Text(a.name).tag(UUID?.some(a.id)) }
                    }
                    if let summary = accountSummary {
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                    if site.accountID == nil {
                        TextField(site.protocolType == .s3 ? "Access key ID" : "Username", text: $site.username,
                                  prompt: Text(usernamePlaceholder))
                            .multilineTextAlignment(.trailing)
                        if folderAccount == nil || !site.username.isEmpty {
                            if site.protocolType.isSSH {
                                KeyPicker(selection: $site.key, allowInherit: true, inheritLabel: keyInheritLabel)
                                AuthOrderPicker(selection: $site.authOrder, inheritLabel: authInheritLabel)
                            }
                            SecureField(site.protocolType == .s3 ? "Secret access key" : "Password", text: $password,
                                        prompt: Text(hasStoredPassword ? "Saved in Keychain" : "Optional, asked when connecting"))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section("Folder") {
                    TextField("Initial folder", text: $site.initialPath, prompt: Text("Empty = home folder; ~/... supported"))
                        .multilineTextAlignment(.trailing)
                    HStack {
                        if let r = testResult {
                            Label(r.message, systemImage: r.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.success ? .green : .red)
                                .font(.callout)
                                .lineLimit(3)
                        }
                        Spacer()
                        if testing { ProgressView().controlSize(.small) }
                        Button("Test") { test() }.disabled(testing || validationError != nil)
                    }
                }
                if let alias = site.sshConfigAlias {
                    Section {
                        Label("Imported from ~/.ssh/config (Host \(alias)). The external terminal runs `ssh \(alias)`, so ProxyJump and other options still apply; browsing in xFinder only uses the key selected here.",
                              systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let e = validationError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 660)
        .onAppear {
            site = original
            portText = original.port.map(String.init) ?? ""
            nameFocused = true
        }
    }

    // MARK: Inheritance

    var sortedAccounts: [Account] {
        app.accounts.accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var folder: SiteFolder? { site.folderID.flatMap { app.library.folder($0) } }

    /// The folder's account, applied when the server has no account or username.
    var folderAccount: Account? {
        guard site.accountID == nil, site.username.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return app.accounts.account(folder?.accountID)
    }

    var noAccountLabel: String {
        if let f = folder, let a = app.accounts.account(f.accountID), site.username.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Inherit from folder \(f.name) (\(a.name))"
        }
        return "None (username and password below)"
    }

    /// "Signs in as deploy with key id_rsa (from folder Example Folder)."
    var accountSummary: String? {
        let account: Account
        var source = ""
        if let a = app.accounts.account(site.accountID) {
            account = a
        } else if let a = folderAccount, let f = folder {
            account = a
            source = " (from folder \(f.name))"
        } else {
            return nil
        }
        let key = app.keys.key(account.key.keyID)
        let hasPassword = account.usePassword
        var how: String
        switch (key, hasPassword) {
        case (let k?, true): how = " with key \(k.alias) or the account’s password"
        case (let k?, false): how = " with key \(k.alias)"
        case (nil, true): how = " with the account’s password"
        case (nil, false): how = ""
        }
        let user = account.username.isEmpty ? account.name : account.username
        return "Signs in as \(user)\(how)\(source)."
    }

    var usernamePlaceholder: String {
        if let a = folderAccount, let f = folder { return "Inherit from folder \(f.name): \(a.username)" }
        if let f = folder, !f.username.isEmpty { return "Inherit from folder \(f.name): \(f.username)" }
        if site.protocolType == .s3 { return "Required" }
        if site.protocolType.isSSH { return "Default: \(NSUserName())" }
        return "Default: anonymous"
    }

    var globalKeyName: String { app.keys.key(app.settings.defaultKeyID)?.alias ?? "no key" }

    var keyInheritLabel: String {
        if let f = folder {
            switch f.key {
            case .key(let id): return "Inherit from folder \(f.name) (\(app.keys.key(id)?.alias ?? "missing key"))"
            case .none: return "Inherit from folder \(f.name) (no key)"
            case .inherit: break
            }
        }
        return "Inherit from global (\(globalKeyName))"
    }

    var authInheritLabel: String {
        if let f = folder, let o = f.authOrder { return "Inherit from folder \(f.name) (\(o.displayName))" }
        return "Inherit from global (\(app.settings.defaultAuthOrder.displayName))"
    }

    // MARK: Validation

    var validationError: String? {
        let p = portText.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty {
            guard let n = Int(p), SiteValidation.validatePort(n) == nil else { return "Invalid port (expected 1–65535)" }
        }
        let host = site.host.trimmingCharacters(in: .whitespaces)
        if site.protocolType == .s3 {
            if !host.isEmpty, SiteValidation.validateHost(host) != nil { return "Invalid address (expected a hostname, IPv4 or IPv6)" }
            if site.s3Bucket.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the S3 bucket name" }
            return nil
        }
        if SiteValidation.validateHost(host) != nil { return "Invalid address (expected a hostname, IPv4 or IPv6)" }
        return nil
    }

    var isAWS: Bool {
        let h = site.host.trimmingCharacters(in: .whitespaces).lowercased()
        return h.isEmpty || h.hasSuffix("amazonaws.com")
    }

    var securityWarning: String? {
        switch site.protocolType {
        case .ftp: return "Plain FTP sends passwords and files unencrypted. Prefer SFTP or FTPS."
        case .webdav: return "Plain HTTP sends passwords and files unencrypted. Prefer HTTPS."
        case .s3 where site.s3UsePlainHTTP && !isAWS: return "Plain HTTP sends data unencrypted."
        default: return nil
        }
    }

    var resolved: ResolvedSiteSettings { app.resolver.resolve(site) }

    var hasStoredPassword: Bool { app.secrets.read(KeychainAccountName.sitePassword(site.id)) != nil }

    private func applyPort() {
        let t = portText.trimmingCharacters(in: .whitespaces)
        site.port = t.isEmpty ? nil : Int(t)
    }

    private func save() {
        guard validationError == nil else { return }
        applyPort()
        site.host = site.host.trimmingCharacters(in: .whitespaces)
        if site.name.trimmingCharacters(in: .whitespaces).isEmpty {
            site.name = site.host.isEmpty ? site.s3Bucket : site.host
        }
        if !password.isEmpty, site.accountID == nil {
            try? app.secrets.write(password, for: KeychainAccountName.sitePassword(site.id))
        }
        if isNew { app.library.addSite(site) } else { app.library.updateSite(site) }
        dismiss()
    }

    private func test() {
        testResult = nil
        guard validationError == nil else { return }
        applyPort()
        testing = true
        let s = site
        let r = resolved
        let pw = password
        Task {
            let result = await SiteConnectionTester.test(site: s, resolved: r, unsavedPassword: pw,
                                                         knownHosts: app.knownHosts, secrets: app.secrets,
                                                         interaction: app.prompts)
            testResult = result
            testing = false
        }
    }
}

/// Folder editor: name and defaults inherited by the folder's servers. With an
/// account selected, username, key and auth order come from the account.
struct FolderEditView: View {
    let original: SiteFolder
    let isNew: Bool
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder = SiteFolder(name: "")
    @FocusState private var nameFocused: Bool

    var sortedAccounts: [Account] {
        app.accounts.accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $folder.name)
                        .multilineTextAlignment(.trailing)
                        .focused($nameFocused)
                }
                Section {
                    Picker("Account", selection: $folder.accountID) {
                        Text("None").tag(UUID?.none)
                        if !sortedAccounts.isEmpty { Divider() }
                        ForEach(sortedAccounts) { a in Text(a.name).tag(UUID?.some(a.id)) }
                    }
                    if folder.accountID == nil {
                        TextField("Username", text: $folder.username, prompt: Text("Not set (each server decides)"))
                            .multilineTextAlignment(.trailing)
                        KeyPicker(selection: $folder.key, allowInherit: true,
                                  inheritLabel: "Inherit from global (\(app.keys.key(app.settings.defaultKeyID)?.alias ?? "no key"))")
                        AuthOrderPicker(selection: $folder.authOrder,
                                        inheritLabel: "Inherit from global (\(app.settings.defaultAuthOrder.displayName))")
                    }
                } header: {
                    Text("Defaults for servers in this folder")
                } footer: {
                    Text("Settings made on a server override these. The account is used by servers that have no account or username of their own.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    if folder.name.trimmingCharacters(in: .whitespaces).isEmpty { folder.name = "Folder" }
                    if folder.accountID != nil {
                        // The account supplies these.
                        folder.username = ""
                        folder.key = .inherit
                        folder.authOrder = nil
                    }
                    if isNew { app.library.addFolder(folder) } else { app.library.updateFolder(folder) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 500, height: 460)
        .onAppear {
            folder = original
            nameFocused = true
        }
    }
}
