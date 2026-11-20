import SwiftUI
import AppKit
import xFinderKit

/// Favorites outline (NSOutlineView): multi-selection, drag and drop with an
/// insertion line, dropping onto a folder moves into it.
struct SitesOutline: NSViewRepresentable {
    @ObservedObject var controller: SidebarController
    let library: SiteLibrary
    let search: String

    static let dragType = NSPasteboard.PasteboardType("dev.skylan.xfinder.library-items")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SitesOutlineView()
        outline.coordinator = context.coordinator
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.allowsMultipleSelection = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.registerForDraggedTypes([Self.dragType])
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.menu = NSMenu()
        outline.menu?.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        context.coordinator.reload()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let c = context.coordinator
        let changed = c.parent.library != library || c.parent.search != search
        c.parent = self
        if changed { c.reload() }
        if c.lastExpandToken != controller.expandAllToken {
            c.applyExpandAll(controller.expandAllToken > c.lastExpandToken)
            c.lastExpandToken = controller.expandAllToken
        }
    }

    final class Node: NSObject {
        let ref: LibraryItemRef
        init(_ ref: LibraryItemRef) { self.ref = ref }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: SitesOutline
        weak var outline: SitesOutlineView?
        var roots: [Node] = []
        var folderChildren: [UUID: [Node]] = [:]
        var collapsed = Set<UUID>()
        var lastExpandToken = 0
        private var reloading = false

        init(_ parent: SitesOutline) { self.parent = parent }

        var app: AppModel { parent.controller.app }
        var library: SiteLibrary { parent.library }
        var searching: Bool { !parent.search.trimmingCharacters(in: .whitespaces).isEmpty }

        func reload() {
            guard let outline else { return }
            reloading = true
            defer { reloading = false }
            if searching {
                roots = library.search(parent.search).map { Node(.site($0.id)) }
                folderChildren = [:]
            } else {
                roots = library.topLevel.map(Node.init)
                folderChildren = [:]
                for f in library.folders { folderChildren[f.id] = f.siteIDs.map { Node(.site($0)) } }
            }
            outline.reloadData()
            for n in roots {
                if case .folder(let id) = n.ref, !collapsed.contains(id) { outline.expandItem(n) }
            }
            var rows = IndexSet()
            for ref in parent.controller.selection {
                if let n = node(for: ref) {
                    let r = outline.row(forItem: n)
                    if r >= 0 { rows.insert(r) }
                }
            }
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }

        func node(for ref: LibraryItemRef) -> Node? {
            if let n = roots.first(where: { $0.ref == ref }) { return n }
            for list in folderChildren.values { if let n = list.first(where: { $0.ref == ref }) { return n } }
            return nil
        }

        func applyExpandAll(_ expand: Bool) {
            guard let outline else { return }
            for n in roots {
                guard case .folder(let id) = n.ref else { continue }
                if expand { collapsed.remove(id); outline.expandItem(n) } else { collapsed.insert(id); outline.collapseItem(n) }
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let n = item as? Node else { return roots.count }
            if case .folder(let id) = n.ref { return folderChildren[id]?.count ?? 0 }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let n = item as? Node, case .folder(let id) = n.ref else { return roots[index] }
            return folderChildren[id]![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let n = item as? Node, case .folder = n.ref else { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? Node else { return nil }
            switch n.ref {
            case .folder(let id):
                let cell = (outlineView.makeView(withIdentifier: .init("folder"), owner: self) as? SidebarCell) ?? SidebarCell(identifier: "folder", twoLines: false)
                let f = library.folder(id)
                cell.textField?.stringValue = f?.name ?? ""
                cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                cell.toolTip = "\(f?.siteIDs.count ?? 0) servers"
                return cell
            case .site(let id):
                let cell = (outlineView.makeView(withIdentifier: .init("site"), owner: self) as? SidebarCell) ?? SidebarCell(identifier: "site", twoLines: true)
                let s = library.site(id)
                cell.textField?.stringValue = s?.displayName ?? ""
                cell.detailField?.stringValue = s.map { "\($0.protocolType.shortName) · \($0.protocolType == .s3 && $0.host.isEmpty ? $0.s3Bucket : $0.host)" } ?? ""
                cell.imageView?.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
                cell.toolTip = s.map { "\($0.protocolType.shortName) · \($0.username.isEmpty ? "" : $0.username + "@")\($0.host)" }
                return cell
            }
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let n = item as? Node, case .site = n.ref else { return 24 }
            return 36
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let outline else { return }
            parent.controller.selection = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.ref }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !reloading, let n = notification.userInfo?["NSObject"] as? Node, case .folder(let id) = n.ref else { return }
            collapsed.insert(id)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !reloading, let n = notification.userInfo?["NSObject"] as? Node, case .folder(let id) = n.ref else { return }
            collapsed.remove(id)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
            if case .site(let id) = n.ref, let s = library.site(id) { parent.controller.activate(s) }
        }

        func activateSelection() {
            let sites = parent.controller.selectedSites
            if sites.count == 1 { parent.controller.activate(sites[0]) } else { app.tabs.openAll(sites) }
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard !searching, let n = item as? Node else { return nil }
            let pi = NSPasteboardItem()
            pi.setData((try? JSONEncoder().encode(n.ref)) ?? Data(), forType: SitesOutline.dragType)
            return pi
        }

        private func draggedRefs(_ info: NSDraggingInfo) -> [LibraryItemRef] {
            (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
                $0.data(forType: SitesOutline.dragType).flatMap { try? JSONDecoder().decode(LibraryItemRef.self, from: $0) }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard !searching else { return [] }
            let refs = draggedRefs(info)
            guard !refs.isEmpty else { return [] }
            let hasFolder = refs.contains { if case .folder = $0 { return true }; return false }
            if let n = item as? Node {
                switch n.ref {
                case .site:
                    return [] // cannot drop onto a server
                case .folder:
                    if hasFolder { return [] } // folders are single-level
                }
            }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let refs = draggedRefs(info)
            var parentFolder: UUID?
            if let n = item as? Node, case .folder(let id) = n.ref { parentFolder = id }
            let idx: Int? = index == NSOutlineViewDropOnItemIndex ? nil : index
            app.library.move(refs, toFolder: parentFolder, at: idx)
            parent.controller.selection = refs
            return true
        }

        // MARK: Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            if outline.clickedRow >= 0, !outline.selectedRowIndexes.contains(outline.clickedRow) {
                outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false)
            }
            let c = parent.controller
            let sel = outline.clickedRow >= 0 ? c.selection : []
            let sites = outline.clickedRow >= 0 ? c.selectedSites : []
            func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let mi = ClosureMenuItem(title: title, action: action)
                mi.isEnabled = enabled
                menu.addItem(mi)
            }
            if sites.count == 1, sel.count == 1, case .site = sel[0] {
                let s = sites[0]
                add("Open in Browser") { self.app.tabs.open(s) }
                add("Open in Terminal", enabled: s.protocolType.isSSH) { self.app.terminal.open(site: s, path: nil) }
                menu.addItem(.separator())
                add("Edit…") { c.edit(siteID: s.id) }
                add("Duplicate") { if let d = self.app.library.duplicateSite(s.id) { c.selection = [.site(d.id)] } }
            } else if sites.count > 1 || sel.contains(where: { if case .folder = $0 { return true }; return false }) {
                add(sites.count == 1 ? "Open in Tab" : "Open \(sites.count) Servers in Tabs", enabled: !sites.isEmpty) {
                    self.app.tabs.openAll(sites)
                }
                if sel.count == 1, case .folder(let fid) = sel[0] {
                    add("Edit Folder…") { c.edit(folderID: fid) }
                    add("New Server in Folder…") { c.newSite(in: fid) }
                    add("Sort Folder by Name") { self.app.library.sortByName(.folder(fid)) }
                }
            }
            if sel.count == 1 {
                menu.addItem(.separator())
                add("Move Up") { self.app.library.move(sel[0], by: -1) }
                add("Move Down") { self.app.library.move(sel[0], by: 1) }
            }
            if !sel.isEmpty {
                menu.addItem(.separator())
                add("Delete…") { c.deleteRequest = .init(items: sel) }
            }
            if outline.clickedRow < 0 {
                add("New Server…") { c.newSite(in: nil) }
                add("New Folder…") { c.newFolder() }
                menu.addItem(.separator())
                add("Expand All Folders") { c.expandAllToken = abs(c.expandAllToken) + 1 }
                add("Collapse All Folders") { c.expandAllToken = -(abs(c.expandAllToken) + 1) }
                menu.addItem(.separator())
                add("Import from Transmit…") { self.app.importExport.importTransmit() }
                menu.addItem(.separator())
                add("Open All in Tabs", enabled: !library.sites.isEmpty) { self.app.tabs.openAll(self.library.orderedSites) }
                add("Sort Top Level by Name") { self.app.library.sortByName(.topLevel) }
                add("Sort Everything by Name") { self.app.library.sortByName(.all) }
            }
        }
    }
}

final class SitesOutlineView: NSOutlineView {
    weak var coordinator: SitesOutline.Coordinator?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 { coordinator?.activateSelection(); return }
        if (event.keyCode == 51 || event.keyCode == 117), flags.contains(.command) || event.keyCode == 117,
           let c = coordinator, !c.parent.controller.selection.isEmpty {
            c.parent.controller.deleteRequest = .init(items: c.parent.controller.selection)
            return
        }
        super.keyDown(with: event)
    }
}

/// Sidebar row: icon plus a name and, for servers, a secondary "PROTOCOL · host" line.
final class SidebarCell: NSTableCellView {
    var detailField: NSTextField?

    init(identifier: String, twoLines: Bool) {
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.symbolConfiguration = .init(pointSize: twoLines ? 15 : 13, weight: .regular)
        addSubview(iv)
        imageView = iv
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tf)
        textField = tf
        var constraints = [
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: twoLines ? 20 : 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ]
        if twoLines {
            let d = NSTextField(labelWithString: "")
            d.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            d.textColor = .secondaryLabelColor
            d.lineBreakMode = .byTruncatingTail
            d.translatesAutoresizingMaskIntoConstraints = false
            addSubview(d)
            detailField = d
            constraints += [
                tf.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                d.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                d.leadingAnchor.constraint(equalTo: tf.leadingAnchor),
                d.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            ]
        } else {
            constraints.append(tf.centerYAnchor.constraint(equalTo: centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // White secondary text on the blue selection.
            detailField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        }
    }
}
