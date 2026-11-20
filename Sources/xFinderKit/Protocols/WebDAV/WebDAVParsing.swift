import Foundation

/// One `<response>` of a PROPFIND multistatus.
public struct WebDAVEntry: Equatable, Sendable {
    public var href: String
    public var isCollection: Bool
    public var size: UInt64?
    public var modificationDate: Date?
    public var status: Int
}

public enum WebDAVParsing {
    public static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
    """

    public static func parseMultistatus(_ data: Data) throws -> [WebDAVEntry] {
        let delegate = MultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw RemoteError.invalidResponse("Malformed PROPFIND response: \(parser.parserError?.localizedDescription ?? "")")
        }
        return delegate.entries
    }

    /// Converts an href (absolute URL or path, percent-encoded) to a decoded path.
    public static func hrefPath(_ href: String) -> String {
        var path = href
        if let url = URL(string: href), url.scheme != nil {
            path = url.path(percentEncoded: true)
        }
        return path.removingPercentEncoding ?? path
    }

    /// Maps a decoded server path to an xFinder path relative to `basePath`.
    public static func relativePath(_ serverPath: String, basePath: String) -> String? {
        let base = RemotePath.normalize(basePath.isEmpty ? "/" : (basePath.hasPrefix("/") ? basePath : "/" + basePath))
        let p = RemotePath.normalize(serverPath)
        if base == "/" { return p }
        if p == base { return "/" }
        guard p.hasPrefix(base + "/") else { return nil }
        return String(p.dropFirst(base.count))
    }

    /// Error for an HTTP status (WebDAV semantics).
    public static func error(status: Int, path: String) -> RemoteError? {
        switch status {
        case 200..<300: return nil
        case 401: return .authenticationFailed("")
        case 403: return .permissionDenied(path)
        case 404: return .notFound(path)
        case 409: return .parentMissing(path)
        case 405, 412: return .alreadyExists(path)
        case 423: return .locked(path)
        case 507: return .insufficientStorage
        default: return .protocolError("The server returned HTTP \(status) for \(path).")
        }
    }
}

private final class MultistatusParser: NSObject, XMLParserDelegate {
    var entries: [WebDAVEntry] = []
    private var text = ""
    private var href: String?
    private var inPropstat = false
    private var propIsCollection = false
    private var propSize: UInt64?
    private var propDate: Date?
    private var propStatus = 200
    private var best: (Bool, UInt64?, Date?)?
    private var responseStatus: Int?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response":
            href = nil; best = nil; responseStatus = nil
        case "propstat":
            inPropstat = true
            propIsCollection = false; propSize = nil; propDate = nil; propStatus = 200
        case "collection":
            if inPropstat { propIsCollection = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            if href == nil { href = value }
        case "getcontentlength":
            if inPropstat { propSize = UInt64(value) }
        case "getlastmodified":
            if inPropstat { propDate = HTTPDates.parse(value) }
        case "status":
            let code = Self.statusCode(value)
            if inPropstat { propStatus = code ?? 200 } else { responseStatus = code }
        case "propstat":
            inPropstat = false
            if (200..<300).contains(propStatus) {
                let prev = best
                best = (propIsCollection || (prev?.0 ?? false), propSize ?? prev?.1, propDate ?? prev?.2)
            }
        case "response":
            if let href {
                let b = best ?? (false, nil, nil)
                entries.append(WebDAVEntry(href: href, isCollection: b.0, size: b.1, modificationDate: b.2,
                                           status: responseStatus ?? (best == nil ? 404 : 200)))
            }
        default: break
        }
        text = ""
    }

    static func statusCode(_ line: String) -> Int? {
        // "HTTP/1.1 200 OK"
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
}
