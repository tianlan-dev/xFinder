import SwiftUI
import xFinderKit

/// Get Info (⌘I): refreshed from the server when opened.
struct ItemInfoSheet: View {
    @ObservedObject var session: ConnectionSession
    let item: RemoteItem
    @State private var info: RemoteItem?
    @State private var stale = false
    @State private var targetKind: String?
    @State private var resolvedTarget: String?
    @Environment(\.dismiss) private var dismiss

    var shown: RemoteItem { info ?? item }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: shown.isDirectoryLike ? "folder.fill" : "doc.fill")
                    .font(.largeTitle).foregroundStyle(Color.accentColor)
                Text(shown.name).font(.title3.bold()).textSelection(.enabled)
            }
            if stale {
                Label("Could not refresh from the server; showing the information from the file list.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            Form {
                LabeledContent("Path") { Text(shown.path).textSelection(.enabled) }
                LabeledContent("Kind", value: kind)
                if !shown.isDirectoryLike, let size = shown.size {
                    LabeledContent("Size", value: "\(size.formatted()) bytes (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
                }
                if let d = shown.modificationDate {
                    LabeledContent("Modified", value: d.formatted(date: .long, time: .standard))
                }
                if let p = shown.permissions {
                    LabeledContent("Permissions", value: "\(PermissionFormatter.symbolic(p))  (\(PermissionFormatter.octal(p)))")
                }
                if let o = shown.owner { LabeledContent("Owner", value: o) }
                if let g = shown.group { LabeledContent("Group", value: g) }
                if item.type == .symlink {
                    LabeledContent("Link target") {
                        Text(resolvedTarget ?? item.symlinkTarget ?? "Unknown").textSelection(.enabled)
                    }
                    LabeledContent("Target is", value: targetKind ?? "…")
                }
            }
            .formStyle(.grouped)
            HStack {
                if item.type == .symlink, let t = resolvedTarget ?? item.symlinkTarget {
                    Button("Copy Target Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t, forType: .string)
                    }
                    Button("Go to Target") {
                        let folder = targetKind == "Folder" ? t : RemotePath.parent(t)
                        session.navigate(to: folder)
                        dismiss()
                    }
                    .disabled(targetKind == "Missing")
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await refresh() }
    }

    var kind: String {
        switch shown.type {
        case .directory: return "Folder"
        case .file: return "File"
        case .symlink: return "Symbolic link"
        case .other: return "Special file"
        }
    }

    private func refresh() async {
        guard let fs = session.fileSystem else { stale = true; return }
        do {
            var fresh = try await fs.stat(item.path)
            if item.type == .symlink { fresh.type = .symlink; fresh.name = item.name }
            info = fresh
        } catch {
            stale = true
        }
        if item.type == .symlink {
            do {
                let target = try await fs.symlinkTarget(item.path)
                resolvedTarget = target
                if let t = try? await fs.stat(target) {
                    targetKind = t.isDirectory ? "Folder" : "File"
                } else {
                    targetKind = "Missing"
                }
            } catch {
                targetKind = "Missing"
            }
        }
    }
}
