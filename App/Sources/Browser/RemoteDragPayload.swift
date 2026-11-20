import Foundation
import AppKit
import UniformTypeIdentifiers
import xFinderKit

/// In-app pasteboard payload describing remote items (drag and drop, copy/paste).
struct RemoteDragPayload: Codable {
    static let type = UTType(exportedAs: "dev.skylan.xfinder.remote-items")
    static var pasteboardType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(type.identifier) }

    struct Entry: Codable {
        var path: String
        var name: String
        var isDirectory: Bool
        var size: UInt64?
    }

    var sessionID: UUID
    var siteID: UUID?
    var entries: [Entry]

    @MainActor init(session: ConnectionSession, items: [RemoteItem]) {
        sessionID = session.id
        siteID = session.site?.id
        entries = items.map { Entry(path: $0.path, name: $0.name, isDirectory: $0.isDirectoryLike && $0.type != .symlink, size: $0.size) }
    }

    func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// Merges the payloads of all pasteboard items (one per dragged row).
    static func from(_ pasteboard: NSPasteboard) -> RemoteDragPayload? {
        let payloads = (pasteboard.pasteboardItems ?? []).compactMap { from($0) }
        guard var first = payloads.first else {
            guard let d = pasteboard.data(forType: pasteboardType) else { return nil }
            return try? JSONDecoder().decode(RemoteDragPayload.self, from: d)
        }
        var seen = Set(first.entries.map(\.path))
        for p in payloads.dropFirst() where p.sessionID == first.sessionID {
            for e in p.entries where !seen.contains(e.path) {
                first.entries.append(e)
                seen.insert(e.path)
            }
        }
        return first
    }

    static func from(_ item: NSPasteboardItem) -> RemoteDragPayload? {
        guard let d = item.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(RemoteDragPayload.self, from: d)
    }
}
