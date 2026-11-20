import SwiftUI
import AppKit
import xFinderKit

/// ⌘C / ⌘V for remote items (and pasting files copied in Finder).
@MainActor
final class RemoteClipboard {
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    func copy(_ items: [RemoteItem], from session: ConnectionSession) {
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let payload = RemoteDragPayload(session: session, items: items)
        pb.declareTypes([RemoteDragPayload.pasteboardType, .string], owner: nil)
        pb.setData(payload.data(), forType: RemoteDragPayload.pasteboardType)
        pb.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }

    var canPaste: Bool {
        let pb = NSPasteboard.general
        return pb.data(forType: RemoteDragPayload.pasteboardType) != nil
            || pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func paste(into folder: String, session: ConnectionSession) {
        let pb = NSPasteboard.general
        if let payload = RemoteDragPayload.from(pb) {
            app.transfers.pasteRemote(payload, into: folder, target: session)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            app.transfers.upload(urls, to: folder, session: session)
        }
    }
}
