import Foundation

/// Validation of favorites before saving or connecting.
public enum SiteValidation {
    public static func validateHost(_ host: String) -> String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return "Enter a server address." }
        if h.hasPrefix("-") { return "The server address cannot start with \"-\"." }
        if h.contains(where: { $0.isWhitespace }) { return "The server address cannot contain spaces." }
        if isIPv4(h) || isIPv6(h) { return nil }
        if h.utf8.count > 253 { return "The server address is longer than 253 characters." }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        for (i, label) in labels.enumerated() {
            if label.isEmpty {
                // Allow a single trailing dot (FQDN).
                if i == labels.count - 1 && labels.count > 1 { continue }
                return "The server address contains an empty label."
            }
            if label.utf8.count > 63 { return "Each part of the server address must be at most 63 characters." }
            if label.hasPrefix("-") || label.hasSuffix("-") { return "Parts of the server address cannot start or end with \"-\"." }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            if label.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                return "The server address contains invalid characters."
            }
        }
        return nil
    }

    public static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let v = Int(p) else { return false }
            return v <= 255
        }
    }

    public static func isIPv6(_ s: String) -> Bool {
        var str = s
        if str.hasPrefix("[") && str.hasSuffix("]") { str = String(str.dropFirst().dropLast()) }
        if let pct = str.firstIndex(of: "%") { str = String(str[..<pct]) }
        var addr = in6_addr()
        return str.contains(":") && inet_pton(AF_INET6, str, &addr) == 1
    }

    public static func validatePort(_ port: Int?) -> String? {
        guard let port else { return nil }
        return (1...65535).contains(port) ? nil : "The port must be between 1 and 65535."
    }

    /// All problems with a site, empty when valid.
    public static func validate(_ site: Site) -> [String] {
        var errors: [String] = []
        if site.protocolType == .s3 {
            if !site.host.isEmpty, let e = validateHost(site.host) { errors.append(e) }
            if site.s3Bucket.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter an S3 bucket name.") }
        } else if let e = validateHost(site.host) {
            errors.append(e)
        }
        if let e = validatePort(site.port) { errors.append(e) }
        return errors
    }
}
