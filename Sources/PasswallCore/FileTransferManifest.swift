import Foundation

public enum FileManifestEntryKind: String, Sendable, Equatable, Codable {
    case file
    case directory
}

public struct FileManifestEntry: Sendable, Equatable, Codable {
    public let path: String
    public let kind: FileManifestEntryKind
    public let byteCount: UInt64
    public let sha256: String?

    public static func file(path: String, byteCount: UInt64, sha256: String) -> Self {
        Self(path: path, kind: .file, byteCount: byteCount, sha256: sha256)
    }

    public static func directory(path: String) -> Self {
        Self(path: path, kind: .directory, byteCount: 0, sha256: nil)
    }
}

public struct FileTransferManifest: Sendable, Equatable, Codable {
    public let entries: [FileManifestEntry]
    public let totalBytes: UInt64

    public init(entries: [FileManifestEntry]) throws {
        guard !entries.isEmpty, entries.count <= TransferLimits.maximumBatchEntries else {
            throw FileTransferManifestError.invalidEntryCount(entries.count)
        }

        var paths = Set<String>()
        var filePaths = Set<String>()
        var parentPaths = Set<String>()
        var totalBytes: UInt64 = 0
        for entry in entries {
            try Self.validate(entry)
            guard paths.insert(entry.path).inserted else {
                throw FileTransferManifestError.duplicatePath(entry.path)
            }
            let parents = Self.parents(of: entry.path)
            guard parents.allSatisfy({ !filePaths.contains($0) }),
                  entry.kind != .file || !parentPaths.contains(entry.path) else {
                throw FileTransferManifestError.invalidPath(entry.path)
            }
            parentPaths.formUnion(parents)
            if entry.kind == .file { filePaths.insert(entry.path) }
            let sum = totalBytes.addingReportingOverflow(entry.byteCount)
            guard !sum.overflow, sum.partialValue <= TransferLimits.maximumBatchBytes else {
                throw FileTransferManifestError.payloadTooLarge
            }
            totalBytes = sum.partialValue
        }
        self.entries = entries
        self.totalBytes = totalBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(entries: container.decode([FileManifestEntry].self, forKey: .entries))
    }

    private static func validate(_ entry: FileManifestEntry) throws {
        guard isRelativePath(entry.path) else {
            throw FileTransferManifestError.invalidPath(entry.path)
        }
        switch entry.kind {
        case .directory:
            guard entry.byteCount == 0, entry.sha256 == nil else {
                throw FileTransferManifestError.invalidDirectory(entry.path)
            }
        case .file:
            guard let sha256 = entry.sha256, isSHA256(sha256) else {
                throw FileTransferManifestError.invalidDigest(entry.path)
            }
        }
    }

    private static func isRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\\"), !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isSHA256(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func parents(of path: String) -> [String] {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts[..<$0].joined(separator: "/") }
    }
}

public enum FileTransferManifestError: Error, Sendable, Equatable {
    case invalidEntryCount(Int)
    case invalidPath(String)
    case duplicatePath(String)
    case invalidDirectory(String)
    case invalidDigest(String)
    case payloadTooLarge
}
