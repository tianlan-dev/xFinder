import Foundation

/// Locations of persistent data and caches.
public struct AppPaths: Sendable {
    public let supportDirectory: URL
    public let cacheDirectory: URL

    public init(supportDirectory: URL, cacheDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.cacheDirectory = cacheDirectory
    }

    /// `~/Library/Application Support/xFinder` and `~/Library/Caches/xFinder`.
    public static let standard: AppPaths = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(xFinderKit.appName, isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(xFinderKit.appName, isDirectory: true)
        return AppPaths(supportDirectory: support, cacheDirectory: caches)
    }()

    /// A throwaway location (used by tests).
    public static func temporary() -> AppPaths {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xFinderTests-\(UUID().uuidString)")
        return AppPaths(supportDirectory: base.appendingPathComponent("Support"),
                        cacheDirectory: base.appendingPathComponent("Caches"))
    }

    public var sitesFile: URL { supportDirectory.appendingPathComponent("sites.json") }
    public var keysFile: URL { supportDirectory.appendingPathComponent("keys.json") }
    public var accountsFile: URL { supportDirectory.appendingPathComponent("accounts.json") }
    public var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public var knownHostsFile: URL { supportDirectory.appendingPathComponent("known_hosts.json") }

    public var editDirectory: URL { cacheDirectory.appendingPathComponent("Edit", isDirectory: true) }
    public var stagingDirectory: URL { cacheDirectory.appendingPathComponent("Staging", isDirectory: true) }
    public var terminalDirectory: URL { cacheDirectory.appendingPathComponent("terminal", isDirectory: true) }
    public var askpassDirectory: URL { cacheDirectory.appendingPathComponent("askpass", isDirectory: true) }

    /// Creates a private (0700) directory if needed and returns it.
    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
}
