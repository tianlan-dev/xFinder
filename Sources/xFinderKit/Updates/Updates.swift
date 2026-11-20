import Foundation
import Crypto

/// `MAJOR.MINOR.PATCH[-PRERELEASE]`, optionally prefixed with `v`.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable, Hashable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Dot-separated pre-release identifiers ("beta.2" -> ["beta", "2"]).
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }   // build metadata is ignored
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".").map(String.init)
            s = String(s[..<dash])
            if pre.isEmpty { return nil }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            nums.append(n)
        }
        while nums.count < 3 { nums.append(0) }
        self.init(major: nums[0], minor: nums[1], patch: nums[2], prerelease: pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // A release is newer than its pre-releases.
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// The parts of a GitHub release (`GET /repos/{owner}/{repo}/releases/latest`) the updater uses.
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var size: UInt64
        public var browserDownloadURL: URL
        /// "sha256:<hex>" when GitHub computed it.
        public var digest: String?

        public init(name: String, size: UInt64, browserDownloadURL: URL, digest: String? = nil) {
            self.name = name
            self.size = size
            self.browserDownloadURL = browserDownloadURL
            self.digest = digest
        }

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var name: String?
    public var body: String?
    public var htmlURL: URL?
    public var draft: Bool
    public var prerelease: Bool
    public var publishedAt: String?
    public var assets: [Asset]

    public init(tagName: String, name: String? = nil, body: String? = nil, htmlURL: URL? = nil, draft: Bool = false,
                prerelease: Bool = false, publishedAt: String? = nil, assets: [Asset]) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
        self.publishedAt = publishedAt
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    public var version: SemanticVersion? { SemanticVersion(tagName) }
}

/// An update that can be installed: the release, its zip and the expected checksum source.
public struct AvailableUpdate: Equatable, Sendable {
    public var release: GitHubRelease
    public var version: SemanticVersion
    public var zip: GitHubRelease.Asset
    /// `SHA256SUMS.txt` or `<zip>.sha256`.
    public var checksums: GitHubRelease.Asset?

    public var notes: String { release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

public enum UpdateCatalog {
    public static let checkInterval: TimeInterval = 24 * 3600
    public static let launchDelay: TimeInterval = 5

    /// Picks the app zip: `xFinder-<version>.zip` if present, otherwise any `xFinder*.zip`.
    public static func zipAsset(in release: GitHubRelease, version: SemanticVersion) -> GitHubRelease.Asset? {
        let zips = release.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        return zips.first { $0.name == "xFinder-\(version).zip" }
            ?? zips.first { $0.name.lowercased().hasPrefix("xfinder") }
    }

    public static func checksumAsset(in release: GitHubRelease, for zip: GitHubRelease.Asset) -> GitHubRelease.Asset? {
        release.assets.first { $0.name == zip.name + ".sha256" }
            ?? release.assets.first { $0.name.uppercased() == "SHA256SUMS.TXT" || $0.name.uppercased() == "SHA256SUMS" }
    }

    /// The release if it is newer than `currentVersion`, not a draft/pre-release, not skipped, and has a zip.
    public static func availableUpdate(_ release: GitHubRelease, currentVersion: String,
                                       skippedVersion: String? = nil) -> AvailableUpdate? {
        guard !release.draft, !release.prerelease, let v = release.version else { return nil }
        let current = SemanticVersion(currentVersion) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        guard v > current else { return nil }
        if let skippedVersion, SemanticVersion(skippedVersion) == v { return nil }
        guard let zip = zipAsset(in: release, version: v) else { return nil }
        return AvailableUpdate(release: release, version: v, zip: zip, checksums: checksumAsset(in: release, for: zip))
    }

    /// Finds the hash for `fileName` in `sha256sum`/`shasum -a 256` output.
    public static func checksum(for fileName: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }   // binary-mode marker
            if (name == fileName || (name as NSString).lastPathComponent == fileName),
               hash.count == 64, hash.allSatisfy(\.isHexDigit) {
                return hash
            }
        }
        return nil
    }

    public static func isCheckDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }
}

/// GitHub Releases feed of the public repository (no token needed).
public struct UpdateFeed: Sendable {
    public static let defaultRepository = "tianlan-dev/xFinder"
    /// "owner/repository"
    public var repository: String

    public init(repository: String = UpdateFeed.defaultRepository) { self.repository = repository }

    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    static func request(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("xFinder-updater", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 60
        return r
    }

    /// The latest published release, or nil when the repository has none yet.
    public func fetchLatest(session: URLSession = .shared) async throws -> GitHubRelease? {
        let (data, resp) = try await session.data(for: Self.request(latestReleaseURL))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw UpdateError.server(code) }
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.invalidArchive("Unexpected release data from GitHub.")
        }
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case server(Int)
    case checksumMissing
    case checksumMismatch
    case invalidArchive(String)
    case wrongBundle(String)
    case wrongVersion(expected: String, found: String)
    case signatureInvalid(String)
    case translocated
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .server(let c): return "GitHub returned HTTP \(c)."
        case .checksumMissing: return "The release has no SHA-256 checksum for the download."
        case .checksumMismatch: return "The downloaded update is damaged (SHA-256 mismatch)."
        case .invalidArchive(let m): return "The update archive is invalid: \(m)"
        case .wrongBundle(let id): return "The update contains a different app (\(id))."
        case .wrongVersion(let e, let f): return "The update contains version \(f), expected \(e)."
        case .signatureInvalid(let m): return "The update's code signature is invalid: \(m)"
        case .translocated: return "xFinder is running from a temporary location. Move it to the Applications folder, open it from there and try again."
        case .installFailed(let m): return "Installing the update failed: \(m)"
        }
    }
}

/// A verified new app bundle waiting to be swapped in after xFinder quits.
public struct PreparedUpdate: Sendable {
    public var newApp: URL
    public var workDirectory: URL
    public var version: SemanticVersion
}

/// Downloads and verifies an update, then hands the swap to a helper script
/// that runs after xFinder quits. Any failure leaves the installed app untouched.
public struct UpdateInstaller: Sendable {
    public var appURL: URL
    public var bundleIdentifier: String

    public init(appURL: URL, bundleIdentifier: String) {
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
    }

    public static func isTranslocated(_ url: URL) -> Bool { url.path.contains("/AppTranslocation/") }

    /// True when the app and its folder can be replaced without administrator rights.
    public func canReplaceWithoutAdmin(fileManager: FileManager = .default) -> Bool {
        let dir = appURL.deletingLastPathComponent().path
        return fileManager.isWritableFile(atPath: dir) && fileManager.isWritableFile(atPath: appURL.path)
    }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    /// Verifies an unpacked app bundle: identifier, version and (ad-hoc or real) code signature.
    public static func verifyBundle(_ app: URL, bundleIdentifier: String, version: SemanticVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.invalidArchive("No Info.plist in \(app.lastPathComponent)")
        }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard id == bundleIdentifier else { throw UpdateError.wrongBundle(id) }
        let found = info["CFBundleShortVersionString"] as? String ?? ""
        guard SemanticVersion(found) == version else { throw UpdateError.wrongVersion(expected: "\(version)", found: found) }
        let (status, output) = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard status == 0 else { throw UpdateError.signatureInvalid(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Expected SHA-256 of the zip: GitHub's asset digest, else the checksum asset.
    static func expectedChecksum(_ update: AvailableUpdate, session: URLSession) async throws -> String {
        if let d = update.zip.digest?.lowercased(), d.hasPrefix("sha256:") {
            let hex = String(d.dropFirst(7))
            if hex.count == 64 { return hex }
        }
        guard let asset = update.checksums else { throw UpdateError.checksumMissing }
        let (data, resp) = try await session.data(for: UpdateFeed.request(asset.browserDownloadURL, accept: "application/octet-stream"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server((resp as? HTTPURLResponse)?.statusCode ?? 0) }
        guard let hash = UpdateCatalog.checksum(for: update.zip.name, in: String(decoding: data, as: UTF8.self)) else {
            throw UpdateError.checksumMissing
        }
        return hash
    }

    /// Downloads, verifies and unpacks the update. `progress` reports 0…1 for the download.
    public func prepare(_ update: AvailableUpdate, session: URLSession = .shared,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> PreparedUpdate {
        if Self.isTranslocated(appURL) { throw UpdateError.translocated }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("xfinder-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let expected = try await Self.expectedChecksum(update, session: session)
            let zip = work.appendingPathComponent(update.zip.name)
            try await Self.download(update.zip.browserDownloadURL, to: zip, expectedSize: update.zip.size,
                                    session: session, progress: progress)
            guard try Self.sha256(of: zip) == expected else { throw UpdateError.checksumMismatch }

            let unpacked = work.appendingPathComponent("unpacked")
            let (status, output) = try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            guard status == 0 else { throw UpdateError.invalidArchive(output) }
            guard let newApp = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.invalidArchive("No application found")
            }
            // Unsigned (ad-hoc) builds: make sure Gatekeeper does not block the relaunch.
            try Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            try Self.verifyBundle(newApp, bundleIdentifier: bundleIdentifier, version: update.version)
            try? fm.removeItem(at: zip)
            return PreparedUpdate(newApp: newApp, workDirectory: work, version: update.version)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    static func download(_ url: URL, to destination: URL, expectedSize: UInt64, session: URLSession,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, resp) = try await session.bytes(for: UpdateFeed.request(url, accept: "application/octet-stream"))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.server((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let total = max(Int64(expectedSize), http.expectedContentLength, 1)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        var lastReport = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try out.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let p = min(Double(received) / Double(total), 1)
                if p - lastReport >= 0.01 { lastReport = p; progress(p) }
            }
        }
        if !buffer.isEmpty { try out.write(contentsOf: buffer) }
        progress(1)
    }

    /// Shell script that waits for `pid` to exit, swaps the bundle (keeping a
    /// backup until the new app has launched) and opens the new version. With
    /// `asAdmin`, the swap runs through an administrator prompt; if that is
    /// cancelled or fails, the old app is reopened.
    public func swapScript(_ prepared: PreparedUpdate, pid: Int32, asAdmin: Bool) -> String {
        let app = ShellQuote.quote(appURL.path)
        let new = ShellQuote.quote(prepared.newApp.path)
        let backup = ShellQuote.quote(appURL.path + ".xfinder-backup")
        let work = ShellQuote.quote(prepared.workDirectory.path)
        let swap = "rm -rf \(backup) && mv \(app) \(backup) && mv \(new) \(app) || { [ -e \(app) ] || mv \(backup) \(app); exit 1; }"
        let restore = "rm -rf \(app) && mv \(backup) \(app)"
        let cleanup = "rm -rf \(backup)"
        func privileged(_ cmd: String) -> String {
            guard asAdmin else { return cmd }
            let apple = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            return "/usr/bin/osascript -e \(ShellQuote.quote(apple))"
        }
        return """
            i=0; while kill -0 \(pid) 2>/dev/null; do sleep 0.2; i=$((i+1)); [ $i -gt 300 ] && exit 1; done
            if \(privileged(swap)); then
              if /usr/bin/open \(app); then
                sleep 3; \(privileged(cleanup))
              else
                \(privileged(restore)); /usr/bin/open \(app)
              fi
            else
              /usr/bin/open \(app)
            fi
            rm -rf \(work)
            """
    }

    /// Starts the swap helper detached from xFinder. Call right before quitting.
    public func launchSwapHelper(_ prepared: PreparedUpdate, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let asAdmin = !canReplaceWithoutAdmin()
        let script = prepared.workDirectory.appendingPathComponent("swap.sh")
        try swapScript(prepared, pid: pid, asAdmin: asAdmin).write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup + background: the helper survives xFinder quitting.
        p.arguments = ["-c", "nohup /bin/sh \"$0\" >/dev/null 2>&1 &", script.path]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }
}
