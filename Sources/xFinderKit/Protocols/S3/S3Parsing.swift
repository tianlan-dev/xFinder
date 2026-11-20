import Foundation

public struct S3ListResult: Equatable, Sendable {
    public struct Object: Equatable, Sendable {
        public var key: String
        public var size: UInt64
        public var lastModified: Date?
    }
    public var objects: [Object] = []
    public var prefixes: [String] = []
    public var isTruncated = false
    public var continuationToken: String?
}

public struct S3ErrorInfo: Equatable, Sendable {
    public var code: String
    public var message: String
    public var region: String?
}

public enum S3Parsing {
    public static func parseList(_ data: Data) throws -> S3ListResult {
        let root = try SimpleXML.parse(data)
        var r = S3ListResult()
        for c in root.children(named: "Contents") {
            guard let key = c.child("Key")?.text else { continue }
            r.objects.append(.init(key: key, size: UInt64(c.child("Size")?.text ?? "") ?? 0,
                                   lastModified: c.child("LastModified").flatMap { HTTPDates.parse($0.text) }))
        }
        for p in root.children(named: "CommonPrefixes") {
            if let s = p.child("Prefix")?.text { r.prefixes.append(s) }
        }
        r.isTruncated = root.child("IsTruncated")?.text == "true"
        r.continuationToken = root.child("NextContinuationToken")?.text
        return r
    }

    public static func parseError(_ data: Data) -> S3ErrorInfo? {
        guard let root = try? SimpleXML.parse(data), root.name == "Error" else { return nil }
        return S3ErrorInfo(code: root.child("Code")?.text ?? "", message: root.child("Message")?.text ?? "",
                           region: root.child("Region")?.text)
    }

    /// Maps an S3 error response to a RemoteError.
    public static func error(status: Int, info: S3ErrorInfo?, path: String) -> RemoteError? {
        if (200..<300).contains(status) { return nil }
        switch info?.code ?? "" {
        case "RequestTimeTooSkewed": return .clockSkew
        case "InvalidAccessKeyId", "SignatureDoesNotMatch": return .authenticationFailed(info?.message ?? "")
        case "AccessDenied", "AllAccessDisabled": return .permissionDenied(path)
        case "NoSuchKey": return .notFound(path)
        case "NoSuchBucket": return .notFound("Bucket does not exist: \(info?.message ?? path)")
        case "EntityTooLarge": return .unsupported("Objects larger than 5 GB need multipart upload, which is not supported.")
        default: break
        }
        switch status {
        case 401: return .authenticationFailed(info?.message ?? "")
        case 403: return .permissionDenied(path)
        case 404: return .notFound(path)
        case 507: return .insufficientStorage
        default:
            let detail = info.map { "\($0.code): \($0.message)" } ?? "HTTP \(status)"
            return .protocolError("S3 error for \(path): \(detail)")
        }
    }
}

/// Tiny DOM for small XML documents (namespaces stripped).
final class SimpleXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(name: String) { self.name = name }
        func child(_ n: String) -> Node? { children.first { $0.name == n } }
        func children(named n: String) -> [Node] { children.filter { $0.name == n } }
    }

    private var stack: [Node] = []
    private var root: Node?

    static func parse(_ data: Data) throws -> Node {
        let d = SimpleXML()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = d
        guard p.parse(), let root = d.root else {
            throw RemoteError.invalidResponse("Malformed XML response")
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let n = Node(name: elementName)
        stack.last?.children.append(n)
        stack.append(n)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let n = stack.removeLast()
        n.text = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.isEmpty { root = n }
    }
}
