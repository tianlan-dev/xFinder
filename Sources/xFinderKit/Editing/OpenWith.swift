import Foundation
import UniformTypeIdentifiers

/// A rule choosing the application used to open a remote file.
public struct OpenWithRule: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Exact file name, case-insensitive (e.g. `Dockerfile`).
        case fileName
        /// Comma-separated extensions (e.g. `py, sh, yaml`).
        case extensions
        /// A UTType identifier (e.g. `public.shell-script`); conforming types match.
        case fileType

        public var displayName: String {
            switch self {
            case .fileName: return "File name"
            case .extensions: return "Extensions"
            case .fileType: return "File type"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var pattern: String
    /// Path of the application bundle.
    public var applicationPath: String

    public init(id: UUID = UUID(), kind: Kind, pattern: String, applicationPath: String) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.applicationPath = applicationPath
    }

    public var applicationName: String {
        URL(fileURLWithPath: applicationPath).deletingPathExtension().lastPathComponent
    }

    public var extensionList: [String] {
        pattern.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
    }

    public func matches(fileName: String, type: UTType?) -> Bool {
        switch kind {
        case .fileName:
            return fileName.lowercased() == pattern.trimmingCharacters(in: .whitespaces).lowercased()
        case .extensions:
            let ext = (fileName as NSString).pathExtension.lowercased()
            return !ext.isEmpty && extensionList.contains(ext)
        case .fileType:
            guard let type, let target = UTType(pattern.trimmingCharacters(in: .whitespaces)) else { return false }
            return type.conforms(to: target)
        }
    }
}

public enum OpenWithResolver {
    /// Picks a rule by priority: exact file name > extension > file type. Within a
    /// priority level, rule order decides.
    public static func rule(for fileName: String, rules: [OpenWithRule]) -> OpenWithRule? {
        let ext = (fileName as NSString).pathExtension
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        for kind in [OpenWithRule.Kind.fileName, .extensions, .fileType] {
            if let r = rules.first(where: { $0.kind == kind && $0.matches(fileName: fileName, type: type) }) {
                return r
            }
        }
        return nil
    }
}
