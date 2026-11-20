import Foundation

/// Imports favorites from a Transmit `.transmitservers` export (property list).
/// Only SFTP and FTP servers are imported; nested folders become "Parent / Child".
public enum TransmitImporter {
    public struct Server: Equatable, Sendable {
        public var name: String
        public var folderPath: [String]
        public var protocolName: String
        public var host: String
        public var port: Int
        public var username: String
        public var remotePath: String
    }

    public struct Parsed: Sendable {
        public var servers: [Server] = []
        public var skipped: [String] = []
    }

    static func string(_ d: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = d[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    static func int(_ d: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            if let n = d[k] as? Int { return n }
            if let n = d[k] as? NSNumber { return n.intValue }
            if let s = d[k] as? String, let n = Int(s) { return n }
        }
        return nil
    }

    public static func parse(_ data: Data) throws -> Parsed {
        let plist: Any
        do { plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) { plist = json } else {
                throw RemoteError.invalidResponse("This is not a Transmit favorites export.")
            }
        }
        guard plist is [Any] || plist is [String: Any] else {
            throw RemoteError.invalidResponse("This is not a Transmit favorites export.")
        }
        var out = Parsed()
        walk(plist, folder: [], into: &out)
        return out
    }

    static func walk(_ node: Any, folder: [String], into out: inout Parsed) {
        if let array = node as? [Any] {
            for item in array { walk(item, folder: folder, into: &out) }
            return
        }
        guard let d = node as? [String: Any] else { return }
        let host = string(d, ["server", "address", "host", "hostname"])
        let name = string(d, ["nickname", "name", "title"]) ?? host ?? "Untitled"
        if let host {
            let proto = (string(d, ["protocol", "type", "connectionType"]) ?? "SFTP").uppercased()
            guard proto.contains("SFTP") || proto == "FTP" else {
                out.skipped.append("\(name): \(proto) is not supported")
                return
            }
            out.servers.append(Server(name: name, folderPath: folder, protocolName: proto.contains("SFTP") ? "SFTP" : "FTP",
                                      host: host, port: int(d, ["port"]) ?? 0,
                                      username: string(d, ["username", "user"]) ?? "",
                                      remotePath: string(d, ["remotePath", "initialPath", "path"]) ?? ""))
            return
        }
        let childKeys = ["children", "items", "favorites", "servers", "collections", "Children", "Items"]
        var found = false
        for k in childKeys {
            if let children = d[k] {
                found = true
                let isRoot = folder.isEmpty && (d["nickname"] == nil && d["name"] == nil && d["title"] == nil)
                walk(children, folder: isRoot ? folder : folder + [name], into: &out)
            }
        }
        if !found {
            for (_, v) in d where v is [Any] || v is [String: Any] { walk(v, folder: folder, into: &out) }
        }
    }

    public static func importServers(_ parsed: Parsed, library: inout SiteLibrary) -> ImportReport {
        var report = ImportReport()
        report.skipped = parsed.skipped
        var folderIDs: [String: UUID] = [:]
        for s in parsed.servers {
            if let problem = SiteValidation.validateHost(s.host) { report.skipped.append("\(s.name): \(problem)"); continue }
            var site = Site(name: library.uniqueSiteName(s.name), protocolType: s.protocolName == "SFTP" ? .sftp : .ftp,
                            host: s.host, username: s.username)
            let defaultPort = site.protocolType.defaultPort
            site.port = (s.port == 0 || s.port == defaultPort) ? nil : s.port
            site.initialPath = s.remotePath
            if !s.folderPath.isEmpty {
                let fname = s.folderPath.joined(separator: " / ")
                if folderIDs[fname] == nil {
                    let f = SiteFolder(name: library.uniqueFolderName(fname))
                    library.addFolder(f)
                    folderIDs[fname] = f.id
                    report.foldersAdded += 1
                }
                site.folderID = folderIDs[fname]
            }
            library.addSite(site)
            report.sitesAdded += 1
        }
        return report
    }
}
