import Foundation

/// POSIX shell quoting.
public enum ShellQuote {
    /// Wraps `s` in single quotes, escaping embedded single quotes (`'\''`).
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes only when needed (for display).
    public static func quoteIfNeeded(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return quote(s)
    }
}
