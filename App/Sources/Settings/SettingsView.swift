import SwiftUI
import AppKit
import UniformTypeIdentifiers
import xFinderKit

/// Settings window with toolbar tabs; the window title follows the tab.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        TabView {
            GeneralSettingsTab(updates: app.updates).tabItem { Label("General", systemImage: "gearshape") }
            KeysSettingsTab().tabItem { Label("Keys", systemImage: "key") }
            AccountsSettingsTab().tabItem { Label("Accounts", systemImage: "person.badge.key") }
            TerminalSettingsTab().tabItem { Label("Terminal", systemImage: "terminal") }
            OpenWithSettingsTab().tabItem { Label("Open With", systemImage: "square.and.pencil") }
            SecuritySettingsTab().tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 700, height: 540)
    }
}

/// Small grey explanatory text.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

struct GeneralSettingsTab: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var updates: UpdateController

    var body: some View {
        Form {
            Section {
                LabeledContent("Double-clicking a favorite") {
                    Picker("Double-clicking a favorite", selection: $app.settings.doubleClickAction) {
                        Text("Opens it in the browser").tag(DoubleClickAction.browser)
                        Text("Opens it in a terminal").tag(DoubleClickAction.terminal)
                    }
                    .trailingRadioGroup()
                }
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Hidden files (dotfiles)") {
                        Picker("Hidden files (dotfiles)", selection: $app.settings.showHiddenFiles) {
                            Text("Show by default").tag(true)
                            Text("Hide by default").tag(false)
                        }
                        .trailingRadioGroup()
                    }
                    Footnote("Applies to all tabs. Each tab can still toggle hidden files with ⇧⌘. or the eye button in the toolbar.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Keep folders above files", isOn: $app.settings.foldersFirst)
                        .toggleStyle(.switch)
                    Footnote("When off, folders and files are sorted together by the selected column.")
                }
            }
            Section("Transfers") {
                Stepper("Simultaneous transfers: \(app.settings.maxConcurrentTransfers)",
                        value: $app.settings.maxConcurrentTransfers, in: 1...8)
                Picker("When a file already exists", selection: $app.settings.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Download folder") {
                    HStack {
                        Text(KeyLibrary.abbreviate(app.settings.downloadDirectory)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseDownloadFolder() }
                    }
                }
            }
            Section("Import / Export") {
                HStack {
                    Button("Import Settings…") { app.importExport.importSettings() }
                    Button("Export Settings…") { app.importExport.exportSettings() }
                }
                Footnote("Includes these preferences, Open With rules, the key list (file paths only) and saved accounts. Passwords, favorites and trusted host keys are not included.")
            }
            UpdatesSettingsSection(updates: updates)
        }
        .formStyle(.grouped)
    }

    private func chooseDownloadFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.directoryURL = app.settings.downloadDirectoryURL
        if p.runModal() == .OK, let url = p.url { app.settings.downloadDirectory = url.path }
    }
}

// MARK: Keys

struct KeysSettingsTab: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: UUID?

    struct Row: Identifiable {
        let entry: SSHKeyEntry
        let info: SSHKeyInfo?
        let exists: Bool
        var id: UUID { entry.id }
        var type: String { info.map { $0.type?.rawValue ?? $0.typeName } ?? "—" }
        var fingerprint: String { info?.fingerprint ?? "—" }
        var status: String { info != nil ? "OK" : (exists ? "Unreadable" : "Missing") }
    }

    var rows: [Row] {
        app.keys.keys.map { k in
            Row(entry: k, info: app.keyInfo(k), exists: FileManager.default.fileExists(atPath: k.expandedPath))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Picker("Global default key", selection: Binding(
                    get: { app.settings.defaultKeyID.map(KeyChoice.key) ?? .none },
                    set: { app.settings.defaultKeyID = $0.keyID })) {
                    Text("No key").tag(KeyChoice.none)
                    if !app.keys.keys.isEmpty { Divider() }
                    ForEach(app.keys.keys) { k in Text(app.keyLabel(k)).tag(KeyChoice.key(k.id)) }
                }
                Picker("Global auth order", selection: $app.settings.defaultAuthOrder) {
                    ForEach(AuthOrder.allCases) { Text($0.displayName).tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 110)
            Footnote("Only the location of each key file is stored; private keys are never copied. Aliases are used only in this app. Servers and folders can only use keys added here — other keys in ~/.ssh are never tried automatically. Supported: Ed25519, RSA and ECDSA in OpenSSH format (passphrase-protected or not) and unencrypted PEM.")
                .padding(.horizontal, 20)
            Table(rows, selection: $selection) {
                TableColumn("Alias") { r in AliasField(entry: r.entry) }
                    .width(min: 80, ideal: 110)
                TableColumn("Type") { r in Text(r.type) }
                    .width(min: 60, ideal: 90)
                TableColumn("Fingerprint") { r in
                    Text(r.fingerprint).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail).help(r.fingerprint)
                }
                .width(min: 100, ideal: 170)
                TableColumn("Path") { r in
                    Text(KeyLibrary.abbreviate(r.entry.path)).lineLimit(1).truncationMode(.middle).help(r.entry.expandedPath)
                }
                .width(min: 90, ideal: 140)
                TableColumn("Status") { r in
                    Text(r.status).foregroundStyle(r.status == "OK" ? Color.secondary : Color.red)
                }
                .width(min: 50, ideal: 70)
            }
            .padding(.horizontal, 20)
            HStack {
                Button("Add…") { addKey() }
                Button("Change Location…") { if let id = selection { repoint(id) } }.disabled(selection == nil)
                Button("Forget Saved Passphrase") {
                    if let id = selection { app.secrets.delete(KeychainAccountName.keyPassphrase(id)) }
                }
                .disabled(selection.map { app.secrets.read(KeychainAccountName.keyPassphrase($0)) == nil } ?? true)
                Spacer()
                Button("Delete…") { if let id = selection { removeKey(id) } }.disabled(selection == nil)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func addKey() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        p.showsHiddenFiles = true
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            if let e = app.keys.key(atPath: url.path) { selection = e.id; continue }
            do { _ = try SSHPrivateKeyLoader.info(path: url.path) } catch {
                let a = NSAlert()
                a.messageText = "“\(url.lastPathComponent)” is not a supported private key"
                a.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                a.runModal()
                continue
            }
            selection = app.keys.add(path: url.path).id
        }
    }

    private func repoint(_ id: UUID) {
        guard var e = app.keys.key(id) else { return }
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: e.expandedPath).deletingLastPathComponent()
        p.showsHiddenFiles = true
        guard p.runModal() == .OK, let url = p.url else { return }
        e.path = KeyLibrary.canonicalPath(url.path)
        app.keys.update(e)
    }

    private func removeKey(_ id: UUID) {
        let usage = app.library.usages(ofKey: id)
        let accountsUsing = app.accounts.accounts.filter { $0.key == .key(id) }
        let total = usage.sites.count + usage.folders.count + accountsUsing.count
        var replacement: KeyChoice = .none
        if total > 0 {
            let a = NSAlert()
            a.messageText = "This key is used by \(total) item(s)"
            a.informativeText = (usage.sites.map(\.displayName) + usage.folders.map(\.name) + accountsUsing.map(\.name)).prefix(10).joined(separator: ", ")
                + "\n\nChoose what they should use instead."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            popup.addItem(withTitle: "Inherit")
            popup.addItem(withTitle: "No key")
            let others = app.keys.keys.filter { $0.id != id }
            for k in others { popup.addItem(withTitle: k.alias) }
            popup.selectItem(at: 0)
            a.accessoryView = popup
            a.addButton(withTitle: "Remove")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            switch popup.indexOfSelectedItem {
            case 0: replacement = .inherit
            case 1: replacement = .none
            default: replacement = .key(others[popup.indexOfSelectedItem - 2].id)
            }
        }
        app.library.replaceKey(id, with: replacement)
        var accounts = app.accounts
        for var acc in accounts.accounts where acc.key == .key(id) {
            acc.key = replacement == .inherit ? .none : replacement
            accounts.update(acc)
        }
        app.accounts = accounts
        if app.settings.defaultKeyID == id { app.settings.defaultKeyID = nil }
        app.secrets.delete(KeychainAccountName.keyPassphrase(id))
        app.keys.remove(id)
        selection = nil
    }
}

/// Inline alias editor in the key table.
struct AliasField: View {
    @EnvironmentObject var app: AppModel
    let entry: SSHKeyEntry
    @State private var text = ""

    var body: some View {
        TextField("Alias", text: $text)
            .textFieldStyle(.plain)
            .onAppear { text = entry.alias }
            .onSubmit(commit)
            .onDisappear(perform: commit)
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != entry.alias, var e = app.keys.key(entry.id) else { text = entry.alias; return }
        e.alias = t
        app.keys.update(e)
    }
}

// MARK: Accounts

struct AccountsSettingsTab: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: UUID?
    @State private var editing: AccountEditing?

    struct AccountEditing: Identifiable {
        let account: Account
        let isNew: Bool
        var id: UUID { account.id }
    }

    var sorted: [Account] {
        app.accounts.accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Footnote("Saved sign-ins that servers and folders can use: a username with a key, a password, or both. Keys come from the Keys tab (or Add Key File… in the editor); passwords are kept in the Keychain. Changing an account updates every server that uses it.")
            Table(sorted, selection: $selection) {
                TableColumn("Name") { a in Text(a.name) }
                TableColumn("Username") { a in Text(a.username) }
                TableColumn("Signs in with") { a in Text(signsInWith(a)).foregroundStyle(.secondary) }
                TableColumn("Used by") { a in Text(usedBy(a)).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let a = app.accounts.account(id) {
                    Button("Edit…") { editing = .init(account: a, isNew: false) }
                    Button("Delete…") { remove(id) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let a = app.accounts.account(id) { editing = .init(account: a, isNew: false) }
            }
            HStack {
                Button("Add…") {
                    editing = .init(account: Account(name: app.accounts.uniqueName("New Account", excluding: nil), username: ""), isNew: true)
                }
                Button("Edit…") {
                    if let id = selection, let a = app.accounts.account(id) { editing = .init(account: a, isNew: false) }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Delete…") { if let id = selection { remove(id) } }.disabled(selection == nil)
            }
        }
        .padding(20)
        .sheet(item: $editing) { e in
            AccountEditorSheet(account: e.account, isNew: e.isNew) { saved in selection = saved.id }
                .environmentObject(app)
        }
    }

    func signsInWith(_ a: Account) -> String {
        var parts: [String] = []
        if let k = app.keys.key(a.key.keyID) { parts.append("key \(k.alias)") }
        if a.usePassword {
            parts.append(app.secrets.read(KeychainAccountName.accountPassword(a.id)) != nil ? "saved password" : "password (asked)")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    func usedBy(_ a: Account) -> String {
        let u = app.library.usages(ofAccount: a.id)
        var parts: [String] = []
        if !u.sites.isEmpty { parts.append(u.sites.count == 1 ? "1 server" : "\(u.sites.count) servers") }
        if !u.folders.isEmpty { parts.append(u.folders.count == 1 ? "1 folder" : "\(u.folders.count) folders") }
        return parts.isEmpty ? "Not used" : parts.joined(separator: ", ")
    }

    private func remove(_ id: UUID) {
        let usage = app.library.usages(ofAccount: id)
        let a = NSAlert()
        a.messageText = "Delete the account “\(app.accounts.account(id)?.name ?? "")”?"
        a.informativeText = usage.sites.isEmpty && usage.folders.isEmpty
            ? "Its saved password is removed from the Keychain."
            : "\(usedBy(app.accounts.account(id)!)) use it. They fall back to their own settings. Its saved password is removed from the Keychain."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var lib = app.library
        for s in usage.sites { var s = s; s.accountID = nil; lib.updateSite(s) }
        for f in usage.folders { var f = f; f.accountID = nil; lib.updateFolder(f) }
        app.library = lib
        app.secrets.delete(KeychainAccountName.accountPassword(id))
        app.accounts.remove(id)
        selection = nil
    }
}

struct AccountEditorSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var account: Account
    let isNew: Bool
    let onSave: (Account) -> Void
    @State private var password = ""

    init(account: Account, isNew: Bool, onSave: @escaping (Account) -> Void) {
        _account = State(initialValue: account)
        self.isNew = isNew
        self.onSave = onSave
    }

    var hasPassword: Bool { app.secrets.read(KeychainAccountName.accountPassword(account.id)) != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $account.name).multilineTextAlignment(.trailing)
                    TextField("Username", text: $account.username).multilineTextAlignment(.trailing)
                }
                Section("Sign in with") {
                    HStack {
                        KeyPicker(selection: $account.key, allowInherit: false)
                        Button("Add Key File…") { addKeyFile() }
                    }
                    Toggle("Password", isOn: $account.usePassword)
                    if account.usePassword {
                        SecureField("Password", text: $password,
                                    prompt: Text(hasPassword ? "Saved in Keychain" : "Optional, asked when connecting"))
                            .multilineTextAlignment(.trailing)
                        if hasPassword {
                            Button("Forget Saved Password") { app.secrets.delete(KeychainAccountName.accountPassword(account.id)); password = "" }
                        }
                    }
                    AuthOrderPicker(selection: $account.authOrder,
                                    inheritLabel: "Inherit from global (\(app.settings.defaultAuthOrder.displayName))")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 420)
    }

    private func addKeyFile() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        p.showsHiddenFiles = true
        guard p.runModal() == .OK, let url = p.url else { return }
        if let e = app.keys.key(atPath: url.path) { account.key = .key(e.id); return }
        guard (try? SSHPrivateKeyLoader.info(path: url.path)) != nil else {
            let a = NSAlert()
            a.messageText = "“\(url.lastPathComponent)” is not a supported private key"
            a.runModal()
            return
        }
        account.key = .key(app.keys.add(path: url.path).id)
    }

    private func save() {
        var a = account
        let base = a.name.trimmingCharacters(in: .whitespaces)
        a.name = app.accounts.uniqueName(base.isEmpty ? a.username : base, excluding: a.id)
        if isNew { a = app.accounts.add(a) } else { app.accounts.update(a) }
        if a.usePassword {
            if !password.isEmpty { try? app.secrets.write(password, for: KeychainAccountName.accountPassword(a.id)) }
        } else {
            app.secrets.delete(KeychainAccountName.accountPassword(a.id))
        }
        onSave(a)
        dismiss()
    }
}

// MARK: Terminal

struct TerminalSettingsTab: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        Form {
            Section {
                Picker("Preferred terminal", selection: $app.settings.terminalApp) {
                    ForEach(TerminalApp.allCases, id: \.self) { t in
                        Text(t.displayName + (installed(t) ? "" : " (not installed)")).tag(t)
                    }
                }
                Footnote("Terminal mode uses the system ssh and only the key selected for the server in this app (IdentitiesOnly). A saved password (the server’s own or its account’s) is filled in automatically once; other prompts are answered in the terminal.")
                Footnote("The first time you use iTerm2, macOS asks for permission to let this app control iTerm2.")
            }
        }
        .formStyle(.grouped)
    }

    private func installed(_ t: TerminalApp) -> Bool {
        let id: String
        switch t {
        case .terminal: id = "com.apple.Terminal"
        case .iTerm2: id = "com.googlecode.iterm2"
        case .ghostty: id = "com.mitchellh.ghostty"
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }
}

// MARK: Open With

struct OpenWithSettingsTab: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: UUID?
    @State private var editing: RuleEditing?

    struct RuleEditing: Identifiable {
        let rule: OpenWithRule
        let isNew: Bool
        var id: UUID { rule.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Footnote("Choose which app opens remote files. When you save, the file is uploaded back to the server automatically.")
            Table(app.settings.openWithRules, selection: $selection) {
                TableColumn("Files") { r in Text(Self.filesLabel(r)) }
                TableColumn("Open With") { r in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: r.applicationPath)).resizable().frame(width: 16, height: 16)
                        Text(r.applicationName)
                    }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                if let id = ids.first, let r = app.settings.openWithRules.first(where: { $0.id == id }) {
                    editing = .init(rule: r, isNew: false)
                }
            }
            HStack {
                Button("Add…") {
                    editing = .init(rule: OpenWithRule(kind: .extensions, pattern: "", applicationPath: ""), isNew: true)
                }
                Button("Edit…") {
                    if let r = app.settings.openWithRules.first(where: { $0.id == selection }) { editing = .init(rule: r, isNew: false) }
                }
                .disabled(selection == nil)
                Button("Remove") { app.settings.openWithRules.removeAll { $0.id == selection }; selection = nil }
                    .disabled(selection == nil)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(selection == nil).help("Move Up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(selection == nil).help("Move Down")
            }
            Footnote("Matching order: exact file name, then extension, then file type. Files without a matching rule open with the system default app; if there is none, you are asked to choose one.")
        }
        .padding(20)
        .sheet(item: $editing) { e in
            OpenWithRuleEditor(rule: e.rule, isNew: e.isNew) { r in
                if let i = app.settings.openWithRules.firstIndex(where: { $0.id == r.id }) {
                    app.settings.openWithRules[i] = r
                } else {
                    app.settings.openWithRules.append(r)
                }
                selection = r.id
            }
        }
    }

    /// ".sh", ".md, .json", "Dockerfile" or a type identifier.
    static func filesLabel(_ r: OpenWithRule) -> String {
        switch r.kind {
        case .extensions: return r.extensionList.map { "." + $0 }.joined(separator: ", ")
        case .fileName: return r.pattern
        case .fileType:
            let t = UTType(r.pattern.trimmingCharacters(in: .whitespaces))
            return t?.localizedDescription.map { "\($0) (\(r.pattern))" } ?? r.pattern
        }
    }

    private func move(_ delta: Int) {
        guard let id = selection, let i = app.settings.openWithRules.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard app.settings.openWithRules.indices.contains(j) else { return }
        app.settings.openWithRules.swapAt(i, j)
    }
}

@MainActor
func chooseApplication() -> URL? {
    let p = NSOpenPanel()
    p.directoryURL = URL(fileURLWithPath: "/Applications")
    p.allowedContentTypes = [.application]
    p.prompt = "Choose"
    return p.runModal() == .OK ? p.url : nil
}

struct OpenWithRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: OpenWithRule
    let isNew: Bool
    let onSave: (OpenWithRule) -> Void

    init(rule: OpenWithRule, isNew: Bool, onSave: @escaping (OpenWithRule) -> Void) {
        _rule = State(initialValue: rule)
        self.isNew = isNew
        self.onSave = onSave
    }

    var placeholder: String {
        switch rule.kind {
        case .fileName: return "Dockerfile"
        case .extensions: return "sh, xml, log"
        case .fileType: return "public.source-code"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Match", selection: $rule.kind) {
                    ForEach(OpenWithRule.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Files", text: $rule.pattern, prompt: Text(placeholder)).multilineTextAlignment(.trailing)
                LabeledContent("Open With") {
                    HStack {
                        if !rule.applicationPath.isEmpty {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: rule.applicationPath)).resizable().frame(width: 16, height: 16)
                            Text(rule.applicationName)
                        }
                        Button("Choose…") { if let u = chooseApplication() { rule.applicationPath = u.path } }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { onSave(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty || rule.applicationPath.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 260)
    }
}

// MARK: Security

struct SecuritySettingsTab: View {
    @EnvironmentObject var app: AppModel
    @State private var hostSelection: String?
    @State private var certSelection: String?

    var body: some View {
        let _ = app.trustRevision
        VStack(alignment: .leading, spacing: 8) {
            Text("Trusted server host keys (kept by this app, separate from ~/.ssh/known_hosts)").font(.headline)
            TrustList(entries: app.knownHosts.hostKeys, selection: $hostSelection)
            HStack {
                Spacer()
                Button("Remove") {
                    if let k = hostSelection { app.knownHosts.removeHostKey(k); hostSelection = nil; app.trustRevision += 1 }
                }
                .disabled(hostSelection == nil)
            }
            Text("Trusted TLS certificates (FTPS and WebDAV over HTTPS)").font(.headline)
            TrustList(entries: app.knownHosts.certificates, selection: $certSelection)
                .frame(maxHeight: 130)
            HStack {
                Spacer()
                Button("Remove") {
                    if let k = certSelection { app.knownHosts.removeCertificate(k); certSelection = nil; app.trustRevision += 1 }
                }
                .disabled(certSelection == nil)
            }
        }
        .padding(20)
    }
}

struct TrustList: View {
    let entries: [(key: String, value: TrustedFingerprint)]
    @Binding var selection: String?
    var body: some View {
        List(selection: $selection) {
            ForEach(entries, id: \.key) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.key)
                    Text("\(e.value.detail)  \(e.value.fingerprint)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .tag(e.key)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .overlay {
            if entries.isEmpty { Text("None").foregroundStyle(.secondary) }
        }
    }
}

private extension View {
    /// A horizontal radio group without its own label, pushed to the trailing
    /// edge of a `LabeledContent` row.
    func trailingRadioGroup() -> some View {
        self.pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
