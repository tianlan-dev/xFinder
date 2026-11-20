import SwiftUI
import AppKit
import UniformTypeIdentifiers
import xFinderKit

/// Callbacks from the file table to the browser.
struct RemoteFileTableHandlers {
    var open: (RemoteItem) -> Void
    var menu: (_ clicked: RemoteItem?, _ menu: NSMenu) -> Void
    var delete: () -> Void
    var copy: () -> Void
    var paste: (_ folder: String) -> Void
    var dropFiles: (_ urls: [URL], _ folder: String) -> Void
    var dropRemote: (_ payload: RemoteDragPayload, _ folder: String, _ copy: Bool) -> Void
    var promiseProvider: (_ item: RemoteItem) -> NSPasteboardWriting?
    var focusChanged: (Bool) -> Void
}

/// Outline-based file list (NSOutlineView): sortable, reorderable columns,
/// in-place folder expansion, drag and drop.
struct RemoteFileTable: NSViewRepresentable {
    @ObservedObject var session: ConnectionSession
    let showHidden: Bool
    let foldersFirst: Bool
    let handlers: RemoteFileTableHandlers

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileOutlineView()
        outline.coordinator = context.coordinator
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.style = .fullWidth
        outline.rowSizeStyle = .default
        outline.autosaveName = "RemoteFileTable"
        outline.autosaveTableColumns = true
        outline.autosaveExpandedItems = false

        func column(_ id: String, _ title: String, width: CGFloat, min: CGFloat, key: FileSortKey) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = min
            c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            return c
        }
        let name = column("name", "Name", width: 320, min: 140, key: .name)
        outline.addTableColumn(name)
        outline.outlineTableColumn = name
        outline.addTableColumn(column("size", "Size", width: 90, min: 50, key: .size))
        outline.addTableColumn(column("date", "Date Modified", width: 160, min: 90, key: .date))
        outline.addTableColumn(column("permissions", "Permissions", width: 100, min: 70, key: .permissions))
        outline.addTableColumn(column("owner", "Owner", width: 80, min: 40, key: .owner))
        outline.addTableColumn(column("group", "Group", width: 80, min: 40, key: .group))

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.menu = NSMenu()
        outline.menu?.delegate = context.coordinator
        outline.registerForDraggedTypes([.fileURL, RemoteDragPayload.pasteboardType])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.outline = outline
        context.coordinator.reload(force: true)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload(force: false)
    }

    // MARK: - Coordinator

    final class Node {
        let item: RemoteItem
        init(_ item: RemoteItem) { self.item = item }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: RemoteFileTable
        weak var outline: FileOutlineView?
        private var roots: [Node] = []
        private var childNodes: [String: [Node]] = [:]
        private var lastRevision = -1
        private var lastShowHidden: Bool?
        private var lastSort: (FileSortKey, Bool, Bool)?
        private var reloading = false

        init(_ parent: RemoteFileTable) { self.parent = parent }

        var session: ConnectionSession { parent.session }

        static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            // "Nov 11, 2026 at 1:44 PM"
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = false
            return f
        }()

        func reload(force: Bool) {
            guard let outline else { return }
            let sort = (session.sortKey, session.sortAscending, parent.foldersFirst)
            if !force && lastRevision == session.revision && lastShowHidden == parent.showHidden
                && lastSort?.0 == sort.0 && lastSort?.1 == sort.1 && lastSort?.2 == sort.2 {
                return
            }
            lastRevision = session.revision
            lastShowHidden = parent.showHidden
            lastSort = sort
            reloading = true
            defer { reloading = false }
            roots = session.visibleItems.map(Node.init)
            childNodes = [:]
            for (path, _) in session.children {
                childNodes[path] = (session.visibleChildren(path) ?? []).map(Node.init)
            }
            outline.reloadData()
            // Re-expand (parents first).
            for path in session.expanded.sorted(by: { $0.count < $1.count }) {
                if let node = node(for: path) { outline.expandItem(node) }
            }
            // Restore selection.
            var rows = IndexSet()
            for path in session.selection {
                if let node = node(for: path) {
                    let r = outline.row(forItem: node)
                    if r >= 0 { rows.insert(r) }
                }
            }
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            outline.sortDescriptors = [NSSortDescriptor(key: sort.0.rawValue, ascending: sort.1)]
        }

        func node(for path: String) -> Node? {
            if let n = roots.first(where: { $0.item.path == path }) { return n }
            for list in childNodes.values { if let n = list.first(where: { $0.item.path == path }) { return n } }
            return nil
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let n = item as? Node else { return roots.count }
            return childNodes[n.item.path]?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let n = item as? Node else { return roots[index] }
            return childNodes[n.item.path]![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let n = item as? Node else { return false }
            return n.item.type == .directory
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !reloading, let d = outlineView.sortDescriptors.first, let key = d.key.flatMap(FileSortKey.init) else { return }
            session.sortKey = key
            session.sortAscending = d.ascending
            DispatchQueue.main.async { self.reload(force: true) }
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? Node, let column = tableColumn else { return nil }
            let id = column.identifier
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
            let it = n.item
            switch id.rawValue {
            case "name":
                var text = it.name
                if it.type == .symlink, let t = it.symlinkTarget { text += " → " + t }
                cell.textField?.stringValue = text
                cell.imageView?.image = icon(for: it)
                (cell as? FileCellView)?.isFolder = it.isDirectoryLike
            case "size":
                cell.textField?.stringValue = it.isDirectoryLike ? "--" : (it.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
                cell.textField?.alignment = .right
            case "date":
                cell.textField?.stringValue = it.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? ""
            case "permissions":
                cell.textField?.stringValue = it.symbolicPermissions.map { Self.typeCharacter(it) + $0 } ?? ""
                cell.textField?.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            case "owner":
                cell.textField?.stringValue = it.owner ?? ""
            case "group":
                cell.textField?.stringValue = it.group ?? ""
            default: break
            }
            return cell
        }

        static func typeCharacter(_ it: RemoteItem) -> String {
            switch it.type {
            case .directory: return "d"
            case .symlink: return "l"
            case .file: return "-"
            case .other: return "?"
            }
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = FileCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            if id.rawValue == "name" {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(iv)
                cell.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                ])
            } else {
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private var iconCache: [String: NSImage] = [:]

        private func icon(for item: RemoteItem) -> NSImage {
            let key = item.isDirectoryLike ? (item.type == .symlink ? "folder-link" : "folder") : "file"
            if let i = iconCache[key] { return i }
            let symbol: String
            switch key {
            case "folder": symbol = "folder.fill"
            case "folder-link": symbol = "folder.fill.badge.questionmark"
            default: symbol = "doc"
            }
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let image = (NSImage(systemSymbolName: key == "folder-link" ? "folder.fill" : symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)) ?? NSImage()
            image.isTemplate = true
            iconCache[key] = image
            return image
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let outline else { return }
            let paths = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.item.path }
            session.selection = Set(paths)
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard !reloading, let n = notification.userInfo?["NSObject"] as? Node else { return }
            session.expand(n.item.path)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !reloading, let n = notification.userInfo?["NSObject"] as? Node else { return }
            session.collapse(n.item.path)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
            parent.handlers.open(n.item)
        }

        func openSelected() {
            guard let outline else { return }
            let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
            if nodes.count == 1 { parent.handlers.open(nodes[0].item); return }
            for n in nodes where !n.item.isDirectoryLike { parent.handlers.open(n.item) }
        }

        // MARK: Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            var clicked: RemoteItem?
            if outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? Node {
                clicked = n.item
                if !outline.selectedRowIndexes.contains(outline.clickedRow) {
                    outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false)
                }
            }
            parent.handlers.menu(clicked, menu)
        }

        // MARK: Drag source

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let n = item as? Node else { return nil }
            return parent.handlers.promiseProvider(n.item)
        }

        // MARK: Drop destination

        private func dropFolder(item: Any?, childIndex: Int) -> String {
            if let n = item as? Node, n.item.isDirectoryLike, childIndex == NSOutlineViewDropOnItemIndex {
                return n.item.type == .symlink ? (n.item.symlinkTarget ?? n.item.path) : n.item.path
            }
            if let n = item as? Node, n.item.isDirectoryLike { return n.item.path }
            return session.currentPath
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard session.isConnected else { return [] }
            // Retarget drops onto files or between rows to the folder itself.
            if let n = item as? Node, !n.item.isDirectoryLike {
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else if item != nil, index != NSOutlineViewDropOnItemIndex {
                outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else if item == nil {
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            let pb = info.draggingPasteboard
            if let payload = RemoteDragPayload.from(pb) {
                if payload.sessionID == session.id {
                    let folder = dropFolder(item: item is Node && (item as! Node).item.isDirectoryLike ? item : nil,
                                            childIndex: NSOutlineViewDropOnItemIndex)
                    if payload.entries.contains(where: { RemotePath.isSameOrDescendant(folder, of: $0.path) || RemotePath.parent($0.path) == folder }) {
                        return []
                    }
                    return NSEvent.modifierFlags.contains(.option) ? .copy : .move
                }
                return .copy
            }
            if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
            return []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let folder = dropFolder(item: item, childIndex: NSOutlineViewDropOnItemIndex)
            let pb = info.draggingPasteboard
            if let payload = RemoteDragPayload.from(pb) {
                let copy = payload.sessionID != session.id || NSEvent.modifierFlags.contains(.option)
                parent.handlers.dropRemote(payload, folder, copy)
                return true
            }
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                parent.handlers.dropFiles(urls, folder)
                return true
            }
            return false
        }
    }
}

/// NSOutlineView subclass handling keyboard shortcuts and copy/paste.
final class FileOutlineView: NSOutlineView {
    weak var coordinator: RemoteFileTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return, Enter
            coordinator?.openSelected()
            return
        case 51, 117: // Delete, Forward Delete
            if flags.contains(.command) { coordinator?.parent.handlers.delete(); return }
        default: break
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { coordinator?.parent.handlers.copy() }

    @objc func paste(_ sender: Any?) {
        guard let c = coordinator else { return }
        c.parent.handlers.paste(c.session.currentPath)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.parent.handlers.focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.parent.handlers.focusChanged(false) }
        return ok
    }
}

/// File list cell: blue folder icons, white icons on the selected row.
final class FileCellView: NSTableCellView {
    var isFolder = false { didSet { updateTint() } }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTint() }
    }

    private func updateTint() {
        guard let iv = imageView else { return }
        if backgroundStyle == .emphasized {
            iv.contentTintColor = .alternateSelectedControlTextColor
        } else {
            iv.contentTintColor = isFolder ? .systemBlue : .secondaryLabelColor
        }
    }
}
