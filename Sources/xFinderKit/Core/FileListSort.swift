import Foundation

/// Sort column for the file list.
public enum FileSortKey: String, Sendable, CaseIterable {
    case name, size, date, permissions, owner, group
}

/// Ordering of a remote directory listing.
public enum FileListSort {
    /// Sorts `list` by `key` in the given direction. Ties (and the name column)
    /// use natural name order. With `foldersFirst`, folders (and symlinks to
    /// folders) are always listed above files regardless of direction;
    /// otherwise folders and files are mixed purely by the column.
    public static func sorted(_ list: [RemoteItem], by key: FileSortKey, ascending asc: Bool,
                              foldersFirst: Bool) -> [RemoteItem] {
        func cmp<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
            switch (a, b) {
            case let (x?, y?): return x == y ? nil : (asc ? x < y : x > y)
            case (nil, _?): return asc
            case (_?, nil): return !asc
            default: return nil
            }
        }
        return list.sorted { a, b in
            if foldersFirst, a.isDirectoryLike != b.isDirectoryLike {
                return a.isDirectoryLike
            }
            let r: Bool?
            switch key {
            case .name: r = nil
            case .size: r = cmp(a.isDirectoryLike ? nil : a.size, b.isDirectoryLike ? nil : b.size)
            case .date: r = cmp(a.modificationDate, b.modificationDate)
            case .permissions: r = cmp(a.permissions, b.permissions)
            case .owner: r = cmp(a.owner, b.owner)
            case .group: r = cmp(a.group, b.group)
            }
            if let r { return r }
            let n = NaturalSort.less(a.name, b.name)
            if n == NaturalSort.less(b.name, a.name) { return a.name < b.name }
            return key == .name ? (asc ? n : !n) : n
        }
    }
}
