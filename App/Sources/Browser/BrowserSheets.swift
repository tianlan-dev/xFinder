import SwiftUI
import xFinderKit

struct BrowserSheetView: View {
    @ObservedObject var session: ConnectionSession
    let sheet: BrowserSheet

    var body: some View {
        switch sheet {
        case .newFolder(let parent):
            NameSheet(title: "New Folder", prompt: "Create a folder in \(parent)", initial: "untitled folder", action: "Create") { name in
                await session.createFolder(named: name, in: parent)
            }
        case .rename(let item):
            NameSheet(title: "Rename", prompt: "New name for \"\(item.name)\"", initial: item.name, action: "Rename") { name in
                await session.rename(item, to: name)
            }
        case .permissions(let item):
            PermissionsSheet(session: session, item: item)
        case .info(let item):
            ItemInfoSheet(session: session, item: item)
        case .goToFolder:
            GoToFolderSheet(session: session)
        case .confirmDelete(let items):
            DeleteConfirmSheet(session: session, items: items)
        }
    }
}

/// Generic single-name input sheet with validation.
struct NameSheet: View {
    let title: String
    let prompt: String
    let initial: String
    let action: String
    let commit: (String) async -> Bool
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(prompt).foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { submit() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { name = initial }
    }

    private func submit() {
        if let e = RemotePath.validateName(name) { error = e; return }
        busy = true
        Task {
            let ok = await commit(name)
            busy = false
            if ok { dismiss() } else { error = "The operation failed. See the message in the browser." }
        }
    }
}

struct GoToFolderSheet: View {
    @ObservedObject var session: ConnectionSession
    @State private var path = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder").font(.headline)
            TextField("Path", text: $path, prompt: Text("/var/www or ~/projects"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { go() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go") { go() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { path = session.currentPath }
    }

    private func go() {
        session.navigate(to: session.resolveUserPath(path))
        dismiss()
    }
}

struct DeleteConfirmSheet: View {
    @ObservedObject var session: ConnectionSession
    let items: [RemoteItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash").font(.largeTitle).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 6) {
                    Text(items.count == 1 ? "Delete \"\(items[0].name)\"?" : "Delete \(items.count) items?").font(.headline)
                    Text(items.contains(where: { $0.type == .directory })
                         ? "Folders are deleted with everything inside them. This cannot be undone."
                         : "This cannot be undone.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    let targets = items
                    dismiss()
                    Task { await session.delete(targets) }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct PermissionsSheet: View {
    @ObservedObject var session: ConnectionSession
    let item: RemoteItem
    @State private var mode: UInt32 = 0o644
    @State private var octal = "0644"
    @Environment(\.dismiss) private var dismiss

    private let labels = ["Owner", "Group", "Others"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions of \"\(item.name)\"").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Read"); Text("Write"); Text("Execute")
                }
                ForEach(0..<3) { row in
                    GridRow {
                        Text(labels[row])
                        ForEach(0..<3) { col in
                            Toggle("", isOn: bit(UInt32(1 << (8 - (row * 3 + col)))))
                                .labelsHidden()
                        }
                    }
                }
            }
            HStack {
                Text("Octal")
                TextField("", text: $octal)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let v = UInt32(octal, radix: 8) { mode = v & 0o7777 } }
                Text(PermissionFormatter.symbolic(mode)).font(.system(.body, design: .monospaced))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let v = UInt32(octal, radix: 8) { mode = v & 0o7777 }
                    let m = mode
                    Task { if await session.setPermissions(item, mode: m) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            mode = (item.permissions ?? 0o644) & 0o7777
            octal = PermissionFormatter.octal(mode)
        }
        .onChange(of: mode) { _, m in octal = PermissionFormatter.octal(m) }
    }

    private func bit(_ b: UInt32) -> Binding<Bool> {
        Binding(get: { mode & b != 0 }, set: { on in mode = on ? (mode | b) : (mode & ~b) })
    }
}
