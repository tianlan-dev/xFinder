import Foundation

public enum DoubleClickAction: String, Codable, CaseIterable, Sendable {
    case browser
    case terminal
}

public enum ConflictPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case ask
    case overwrite
    case overwriteIfNewer
    case skip
    case keepBoth

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .ask: return "Ask every time"
        case .overwrite: return "Replace"
        case .overwriteIfNewer: return "Replace if newer"
        case .skip: return "Skip"
        case .keepBoth: return "Keep both"
        }
    }
}

public enum TerminalApp: String, Codable, CaseIterable, Sendable, Identifiable {
    case terminal
    case iTerm2
    case ghostty

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }
}

/// Persistent update-check state.
public struct UpdatePreferences: Codable, Hashable, Sendable {
    public var automaticallyCheck: Bool = true
    public var lastCheck: Date?
    /// Release version the user chose to skip (automatic checks only).
    public var skippedVersion: String?

    public init(automaticallyCheck: Bool = true, lastCheck: Date? = nil, skippedVersion: String? = nil) {
        self.automaticallyCheck = automaticallyCheck
        self.lastCheck = lastCheck
        self.skippedVersion = skippedVersion
    }
}

/// Preferences (`settings.json`).
public struct AppSettings: Codable, Hashable, Sendable {
    public static let defaultDownloadDirectory = "~/Downloads"
    public static let concurrencyRange = 1...8

    public var doubleClickAction: DoubleClickAction = .browser
    public var showHiddenFiles: Bool = false
    /// List folders above files regardless of the sort column.
    public var foldersFirst: Bool = true
    public var maxConcurrentTransfers: Int = 3
    public var conflictPolicy: ConflictPolicy = .ask
    public var downloadDirectory: String = AppSettings.defaultDownloadDirectory
    public var terminalApp: TerminalApp = .terminal
    public var defaultKeyID: UUID?
    public var defaultAuthOrder: AuthOrder = .keyFirst
    public var openWithRules: [OpenWithRule] = []
    public var updates = UpdatePreferences()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case doubleClickAction, showHiddenFiles, foldersFirst, maxConcurrentTransfers, conflictPolicy, downloadDirectory
        case terminalApp, defaultKeyID, defaultAuthOrder, openWithRules, updates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        doubleClickAction = (try? c.decodeIfPresent(DoubleClickAction.self, forKey: .doubleClickAction)) ?? d.doubleClickAction
        showHiddenFiles = (try? c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles)) ?? d.showHiddenFiles
        foldersFirst = (try? c.decodeIfPresent(Bool.self, forKey: .foldersFirst)) ?? d.foldersFirst
        maxConcurrentTransfers = (try? c.decodeIfPresent(Int.self, forKey: .maxConcurrentTransfers)) ?? d.maxConcurrentTransfers
        conflictPolicy = (try? c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy)) ?? d.conflictPolicy
        downloadDirectory = (try? c.decodeIfPresent(String.self, forKey: .downloadDirectory)) ?? d.downloadDirectory
        terminalApp = (try? c.decodeIfPresent(TerminalApp.self, forKey: .terminalApp)) ?? d.terminalApp
        defaultKeyID = try? c.decodeIfPresent(UUID.self, forKey: .defaultKeyID)
        defaultAuthOrder = (try? c.decodeIfPresent(AuthOrder.self, forKey: .defaultAuthOrder)) ?? d.defaultAuthOrder
        openWithRules = (try? c.decodeIfPresent([OpenWithRule].self, forKey: .openWithRules)) ?? []
        updates = (try? c.decodeIfPresent(UpdatePreferences.self, forKey: .updates)) ?? UpdatePreferences()
        sanitize()
    }

    /// Clamps concurrency to 1–8 and resets a missing download directory.
    public mutating func sanitize(fileManager: FileManager = .default) {
        maxConcurrentTransfers = min(max(maxConcurrentTransfers, Self.concurrencyRange.lowerBound),
                                     Self.concurrencyRange.upperBound)
        var isDir: ObjCBool = false
        let expanded = (downloadDirectory as NSString).expandingTildeInPath
        if downloadDirectory.isEmpty || !fileManager.fileExists(atPath: expanded, isDirectory: &isDir) || !isDir.boolValue {
            downloadDirectory = Self.defaultDownloadDirectory
        }
    }

    public var downloadDirectoryURL: URL {
        URL(fileURLWithPath: (downloadDirectory as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static func load(from url: URL) -> AppSettings {
        (try? JSONFile.load(AppSettings.self, from: url)) ?? AppSettings()
    }

    public func save(to url: URL) throws {
        try JSONFile.save(self, to: url)
    }
}
