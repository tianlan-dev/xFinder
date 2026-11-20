import Foundation

/// Reference to a top-level library entry.
public enum LibraryItemRef: Hashable, Sendable, Codable {
    case site(UUID)
    case folder(UUID)

    public var id: UUID {
        switch self {
        case .site(let id), .folder(let id): return id
        }
    }

    enum CodingKeys: String, CodingKey { case site, folder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .site) { self = .site(id); return }
        if let id = try c.decodeIfPresent(UUID.self, forKey: .folder) { self = .folder(id); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid library item"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .site(let id): try c.encode(id, forKey: .site)
        case .folder(let id): try c.encode(id, forKey: .folder)
        }
    }
}

/// Natural ("Finder-like") name ordering: `srv2` < `srv10`.
public enum NaturalSort {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  range: nil, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func less(_ a: String, _ b: String) -> Bool {
        let r = compare(a, b)
        if r == .orderedSame { return a < b }
        return r == .orderedAscending
    }
}

/// Sort scopes for "Sort by Name".
public enum LibrarySortScope: Sendable {
    /// Only the sites inside one folder.
    case folder(UUID)
    /// Only the top-level ordering (folders and loose sites together).
    case topLevel
    /// Top level and every folder.
    case all
}

/// Favorites library (`sites.json`, data format v2).
///
/// Top-level sites and folders share one ordering (`topLevel`); each folder keeps
/// the order of its own sites (`SiteFolder.siteIDs`).
public struct SiteLibrary: Codable, Hashable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var sites: [Site]
    public var folders: [SiteFolder]
    public var topLevel: [LibraryItemRef]
    public var globalBookmarks: [Bookmark]

    public init(sites: [Site] = [], folders: [SiteFolder] = [], topLevel: [LibraryItemRef] = [],
                globalBookmarks: [Bookmark] = []) {
        self.version = Self.currentVersion
        self.sites = sites
        self.folders = folders
        self.topLevel = topLevel
        self.globalBookmarks = globalBookmarks
        normalize()
    }

    enum CodingKeys: String, CodingKey { case version, sites, folders, topLevel, globalBookmarks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sites = try c.decodeIfPresent([Site].self, forKey: .sites) ?? []
        folders = try c.decodeIfPresent([SiteFolder].self, forKey: .folders) ?? []
        globalBookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .globalBookmarks) ?? []
        if v < 2 {
            // v1: folders were listed before loose sites, and folder membership
            // order followed the order of the `sites` array.
            topLevel = folders.map { .folder($0.id) } + sites.filter { $0.folderID == nil }.map { .site($0.id) }
            for i in folders.indices {
                let fid = folders[i].id
                folders[i].siteIDs = sites.filter { $0.folderID == fid }.map(\.id)
            }
        } else {
            topLevel = try c.decodeIfPresent([LibraryItemRef].self, forKey: .topLevel) ?? []
        }
        version = Self.currentVersion
        normalize()
    }

    // MARK: - Persistence

    public static func load(from url: URL) throws -> SiteLibrary {
        try JSONFile.load(SiteLibrary.self, from: url) ?? SiteLibrary()
    }

    public func save(to url: URL) throws {
        try JSONFile.save(self, to: url)
    }

    // MARK: - Consistency

    /// Repairs ordering so every site/folder appears exactly once.
    public mutating func normalize() {
        let siteIDs = Set(sites.map(\.id))
        let folderIDs = Set(folders.map(\.id))
        // Sites pointing at unknown folders become top-level.
        for i in sites.indices where sites[i].folderID.map({ !folderIDs.contains($0) }) ?? false {
            sites[i].folderID = nil
        }
        var seen = Set<UUID>()
        for i in folders.indices {
            let fid = folders[i].id
            var ids: [UUID] = []
            for sid in folders[i].siteIDs where siteIDs.contains(sid) && !seen.contains(sid) {
                if let s = sites.first(where: { $0.id == sid }), s.folderID == fid {
                    ids.append(sid); seen.insert(sid)
                }
            }
            for s in sites where s.folderID == fid && !seen.contains(s.id) {
                ids.append(s.id); seen.insert(s.id)
            }
            folders[i].siteIDs = ids
        }
        var top: [LibraryItemRef] = []
        var seenTop = Set<UUID>()
        for ref in topLevel {
            switch ref {
            case .folder(let id) where folderIDs.contains(id) && !seenTop.contains(id):
                top.append(ref); seenTop.insert(id)
            case .site(let id) where siteIDs.contains(id) && !seenTop.contains(id) && !seen.contains(id):
                top.append(ref); seenTop.insert(id)
            default: break
            }
        }
        for f in folders where !seenTop.contains(f.id) { top.append(.folder(f.id)); seenTop.insert(f.id) }
        for s in sites where s.folderID == nil && !seenTop.contains(s.id) { top.append(.site(s.id)); seenTop.insert(s.id) }
        topLevel = top
    }

    // MARK: - Lookup

    public func site(_ id: UUID) -> Site? { sites.first { $0.id == id } }
    public func folder(_ id: UUID) -> SiteFolder? { folders.first { $0.id == id } }
    public func folder(of site: Site) -> SiteFolder? { site.folderID.flatMap { folder($0) } }

    /// Sites in display order (top-level order, folders expanded in place).
    public var orderedSites: [Site] {
        var out: [Site] = []
        for ref in topLevel {
            switch ref {
            case .site(let id): if let s = site(id) { out.append(s) }
            case .folder(let fid): out += sites(inFolder: fid)
            }
        }
        return out
    }

    public func sites(inFolder fid: UUID) -> [Site] {
        (folder(fid)?.siteIDs ?? []).compactMap { site($0) }
    }

    /// Case-insensitive search on name and address.
    public func search(_ query: String) -> [Site] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return orderedSites }
        return orderedSites.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.host.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Sites

    /// Adds a site at the end of its folder (or of the top level), or after `afterID`.
    public mutating func addSite(_ site: Site, after afterID: UUID? = nil) {
        sites.append(site)
        if let fid = site.folderID, let fi = folders.firstIndex(where: { $0.id == fid }) {
            if let a = afterID, let idx = folders[fi].siteIDs.firstIndex(of: a) {
                folders[fi].siteIDs.insert(site.id, at: idx + 1)
            } else {
                folders[fi].siteIDs.append(site.id)
            }
        } else {
            if let a = afterID, let idx = topLevel.firstIndex(where: { $0.id == a }) {
                topLevel.insert(.site(site.id), at: idx + 1)
            } else {
                topLevel.append(.site(site.id))
            }
        }
        normalize()
    }

    /// Replaces a site; moves it if its folder changed.
    public mutating func updateSite(_ site: Site) {
        guard let i = sites.firstIndex(where: { $0.id == site.id }) else { return }
        let oldFolder = sites[i].folderID
        sites[i] = site
        if oldFolder != site.folderID {
            detach(site.id)
            attach(site.id, toFolder: site.folderID, at: nil)
        }
        normalize()
    }

    /// Removes sites and returns them (caller deletes their keychain passwords).
    @discardableResult
    public mutating func removeSites(_ ids: Set<UUID>) -> [Site] {
        let removed = sites.filter { ids.contains($0.id) }
        sites.removeAll { ids.contains($0.id) }
        topLevel.removeAll { if case .site(let id) = $0 { return ids.contains(id) }; return false }
        for i in folders.indices { folders[i].siteIDs.removeAll { ids.contains($0) } }
        normalize()
        return removed
    }

    /// Duplicates a site right after the original, with a unique name.
    @discardableResult
    public mutating func duplicateSite(_ id: UUID) -> Site? {
        guard var copy = site(id) else { return nil }
        copy.id = UUID()
        copy.name = uniqueSiteName(copy.displayName + " copy")
        copy.bookmarks = copy.bookmarks.map { Bookmark(name: $0.name, path: $0.path) }
        addSite(copy, after: id)
        return copy
    }

    public func uniqueSiteName(_ base: String) -> String {
        Self.uniqueName(base, existing: Set(sites.map { $0.name.lowercased() }))
    }

    public func uniqueFolderName(_ base: String) -> String {
        Self.uniqueName(base, existing: Set(folders.map { $0.name.lowercased() }))
    }

    /// `Name`, `Name (2)`, `Name (3)`…
    public static func uniqueName(_ base: String, existing: Set<String>) -> String {
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base) (\(n))".lowercased()) { n += 1 }
        return "\(base) (\(n))"
    }

    // MARK: - Folders

    public mutating func addFolder(_ folder: SiteFolder) {
        var f = folder
        f.siteIDs = []
        folders.append(f)
        topLevel.append(.folder(f.id))
        for sid in folder.siteIDs {
            if let i = sites.firstIndex(where: { $0.id == sid }) {
                detach(sid)
                sites[i].folderID = f.id
                attach(sid, toFolder: f.id, at: nil)
            }
        }
        normalize()
    }

    public mutating func updateFolder(_ folder: SiteFolder) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let ids = folders[i].siteIDs
        folders[i] = folder
        folders[i].siteIDs = ids
    }

    /// Removes a folder. With `keepSites`, its sites move to the top level in place
    /// of the folder; otherwise they are deleted and returned.
    @discardableResult
    public mutating func removeFolder(_ id: UUID, keepSites: Bool) -> [Site] {
        guard let f = folder(id) else { return [] }
        var removed: [Site] = []
        let topIndex = topLevel.firstIndex(of: .folder(id)) ?? topLevel.count
        topLevel.removeAll { $0 == .folder(id) }
        folders.removeAll { $0.id == id }
        if keepSites {
            let refs = f.siteIDs.map { LibraryItemRef.site($0) }
            for sid in f.siteIDs {
                if let i = sites.firstIndex(where: { $0.id == sid }) { sites[i].folderID = nil }
            }
            topLevel.insert(contentsOf: refs, at: min(topIndex, topLevel.count))
        } else {
            removed = removeSites(Set(f.siteIDs))
        }
        normalize()
        return removed
    }

    // MARK: - Moving

    private mutating func detach(_ siteID: UUID) {
        topLevel.removeAll { $0 == .site(siteID) }
        for i in folders.indices { folders[i].siteIDs.removeAll { $0 == siteID } }
    }

    private mutating func attach(_ siteID: UUID, toFolder fid: UUID?, at index: Int?) {
        if let fid, let fi = folders.firstIndex(where: { $0.id == fid }) {
            let idx = min(max(index ?? folders[fi].siteIDs.count, 0), folders[fi].siteIDs.count)
            folders[fi].siteIDs.insert(siteID, at: idx)
        } else {
            let idx = min(max(index ?? topLevel.count, 0), topLevel.count)
            topLevel.insert(.site(siteID), at: idx)
        }
    }

    /// Moves items (drag and drop). `parent` nil = top level. `index` is the
    /// insertion index in the destination list *before* removal of the moved items
    /// (like `NSOutlineView` drop indices); nil = append. Folders can only be moved
    /// within the top level; dropping a folder into a folder places it at top level.
    public mutating func move(_ items: [LibraryItemRef], toFolder parent: UUID?, at index: Int?) {
        // Translate the index to account for moved items that sit before it.
        var adjusted = index
        if let idx = index {
            let destList: [UUID] = parent.flatMap { folder($0)?.siteIDs } ?? topLevel.map(\.id)
            let movedIDs = Set(items.map(\.id))
            let before = destList.prefix(idx).filter { movedIDs.contains($0) }.count
            adjusted = idx - before
        }
        var siteInserts: [UUID] = []
        var folderInserts: [UUID] = []
        for item in items {
            switch item {
            case .site(let sid):
                guard let i = sites.firstIndex(where: { $0.id == sid }) else { continue }
                detach(sid)
                sites[i].folderID = parent
                siteInserts.append(sid)
            case .folder(let fid):
                guard folder(fid) != nil else { continue }
                topLevel.removeAll { $0 == .folder(fid) }
                folderInserts.append(fid)
            }
        }
        if let parent, let fi = folders.firstIndex(where: { $0.id == parent }) {
            var idx = min(adjusted ?? folders[fi].siteIDs.count, folders[fi].siteIDs.count)
            for sid in siteInserts { folders[fi].siteIDs.insert(sid, at: idx); idx += 1 }
            // Folders dropped into a folder go to the end of the top level.
            for fid in folderInserts { topLevel.append(.folder(fid)) }
        } else {
            var idx = min(adjusted ?? topLevel.count, topLevel.count)
            for item in items {
                switch item {
                case .site(let sid) where siteInserts.contains(sid):
                    topLevel.insert(.site(sid), at: idx); idx += 1
                case .folder(let fid) where folderInserts.contains(fid):
                    topLevel.insert(.folder(fid), at: idx); idx += 1
                default: break
                }
            }
        }
        normalize()
    }

    /// Moves an item one position up (-1) or down (+1) within its list.
    public mutating func move(_ item: LibraryItemRef, by delta: Int) {
        if case .site(let sid) = item, let fid = site(sid)?.folderID,
           let fi = folders.firstIndex(where: { $0.id == fid }),
           let idx = folders[fi].siteIDs.firstIndex(of: sid) {
            let n = idx + delta
            guard n >= 0, n < folders[fi].siteIDs.count else { return }
            folders[fi].siteIDs.swapAt(idx, n)
            return
        }
        guard let idx = topLevel.firstIndex(of: item) else { return }
        let n = idx + delta
        guard n >= 0, n < topLevel.count else { return }
        topLevel.swapAt(idx, n)
    }

    public func displayName(of ref: LibraryItemRef) -> String {
        switch ref {
        case .site(let id): return site(id)?.displayName ?? ""
        case .folder(let id): return folder(id)?.name ?? ""
        }
    }

    /// Natural-order sort by name.
    public mutating func sortByName(_ scope: LibrarySortScope) {
        let snapshot = self
        func siteName(_ id: UUID) -> String { snapshot.site(id)?.displayName ?? "" }
        func sortFolder(_ fi: Int) {
            var ids = folders[fi].siteIDs
            ids.sort { NaturalSort.less(siteName($0), siteName($1)) }
            folders[fi].siteIDs = ids
        }
        func sortTop() {
            var refs = topLevel
            refs.sort { NaturalSort.less(snapshot.displayName(of: $0), snapshot.displayName(of: $1)) }
            topLevel = refs
        }
        switch scope {
        case .folder(let fid):
            if let fi = folders.firstIndex(where: { $0.id == fid }) { sortFolder(fi) }
        case .topLevel:
            sortTop()
        case .all:
            sortTop()
            for fi in folders.indices { sortFolder(fi) }
        }
    }

    // MARK: - Bookmarks

    /// Bookmarks shown for a site: global → folder → site's own, duplicates removed.
    public func visibleBookmarks(for siteID: UUID?) -> [(bookmark: Bookmark, scope: BookmarkScope)] {
        var out: [(Bookmark, BookmarkScope)] = []
        var seen = Set<String>()
        func add(_ list: [Bookmark], _ scope: BookmarkScope) {
            for b in list where !seen.contains(RemotePath.normalize(b.path)) {
                seen.insert(RemotePath.normalize(b.path))
                out.append((b, scope))
            }
        }
        add(globalBookmarks, .global)
        if let siteID, let s = site(siteID) {
            if let f = folder(of: s) { add(f.bookmarks, .folder) }
            add(s.bookmarks, .site)
        }
        return out.map { (bookmark: $0.0, scope: $0.1) }
    }

    /// Adds a bookmark for a site in the given scope. Folder scope falls back to
    /// site scope when the site is not in a folder.
    public mutating func addBookmark(_ bookmark: Bookmark, scope: BookmarkScope, siteID: UUID?, at index: Int? = nil) {
        func insert(into list: inout [Bookmark]) {
            list.removeAll { RemotePath.normalize($0.path) == RemotePath.normalize(bookmark.path) }
            let i = min(index ?? list.count, list.count)
            list.insert(bookmark, at: i)
        }
        switch scope {
        case .global:
            insert(into: &globalBookmarks)
        case .folder:
            if let siteID, let s = site(siteID), let fid = s.folderID,
               let fi = folders.firstIndex(where: { $0.id == fid }) {
                insert(into: &folders[fi].bookmarks)
            } else {
                addBookmark(bookmark, scope: .site, siteID: siteID, at: index)
            }
        case .site:
            if let siteID, let si = sites.firstIndex(where: { $0.id == siteID }) {
                insert(into: &sites[si].bookmarks)
            }
        }
    }

    /// Removes a bookmark (by id) from wherever it lives.
    @discardableResult
    public mutating func removeBookmark(_ id: UUID) -> Bookmark? {
        if let i = globalBookmarks.firstIndex(where: { $0.id == id }) { return globalBookmarks.remove(at: i) }
        for fi in folders.indices {
            if let i = folders[fi].bookmarks.firstIndex(where: { $0.id == id }) { return folders[fi].bookmarks.remove(at: i) }
        }
        for si in sites.indices {
            if let i = sites[si].bookmarks.firstIndex(where: { $0.id == id }) { return sites[si].bookmarks.remove(at: i) }
        }
        return nil
    }

    /// Changes the visibility scope of a bookmark ("Show For").
    public mutating func setBookmarkScope(_ id: UUID, scope: BookmarkScope, siteID: UUID?, at index: Int? = nil) {
        guard let b = removeBookmark(id) else { return }
        addBookmark(b, scope: scope, siteID: siteID, at: index)
    }

    public mutating func renameBookmark(_ id: UUID, to name: String) {
        if let i = globalBookmarks.firstIndex(where: { $0.id == id }) { globalBookmarks[i].name = name; return }
        for fi in folders.indices {
            if let i = folders[fi].bookmarks.firstIndex(where: { $0.id == id }) { folders[fi].bookmarks[i].name = name; return }
        }
        for si in sites.indices {
            if let i = sites[si].bookmarks.firstIndex(where: { $0.id == id }) { sites[si].bookmarks[i].name = name; return }
        }
    }

    // MARK: - References

    /// Sites and folders that use an account.
    public func usages(ofAccount id: UUID) -> (sites: [Site], folders: [SiteFolder]) {
        (sites.filter { $0.accountID == id }, folders.filter { $0.accountID == id })
    }

    /// Sites and folders that reference a key.
    public func usages(ofKey id: UUID) -> (sites: [Site], folders: [SiteFolder]) {
        (sites.filter { $0.key == .key(id) }, folders.filter { $0.key == .key(id) })
    }

    /// Replaces references to a key (e.g. before deleting it).
    public mutating func replaceKey(_ id: UUID, with replacement: KeyChoice) {
        for i in sites.indices where sites[i].key == .key(id) { sites[i].key = replacement }
        for i in folders.indices where folders[i].key == .key(id) { folders[i].key = replacement }
    }

    public mutating func clearAccount(_ id: UUID) {
        for i in sites.indices where sites[i].accountID == id { sites[i].accountID = nil }
        for i in folders.indices where folders[i].accountID == id { folders[i].accountID = nil }
    }
}
