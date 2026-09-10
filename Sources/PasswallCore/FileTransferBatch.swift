import CryptoKit
import Foundation

public struct FileTransferBatch: Sendable {
    public let manifest: FileTransferManifest
    public let fileURLs: [URL]

    public static func build(from selectedURLs: [URL]) throws -> Self {
        var entries: [FileManifestEntry] = []
        var files: [URL] = []
        var totalBytes: UInt64 = 0
        for url in selectedURLs {
            try Task.checkCancellation()
            try append(
                url,
                path: url.lastPathComponent,
                entries: &entries,
                files: &files,
                totalBytes: &totalBytes
            )
        }
        return try Self(manifest: FileTransferManifest(entries: entries), fileURLs: files)
    }

    private static func append(
        _ url: URL,
        path: String,
        entries: inout [FileManifestEntry],
        files: inout [URL],
        totalBytes: inout UInt64,
        enumerateDescendants: Bool = true
    ) throws {
        try Task.checkCancellation()
        guard entries.count < TransferLimits.maximumBatchEntries else {
            throw FileTransferManifestError.invalidEntryCount(entries.count + 1)
        }
        let values = try url.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey
        ])
        guard values.isSymbolicLink != true else {
            throw FileTransferBatchError.unsupportedItem(path)
        }
        if values.isDirectory == true {
            entries.append(.directory(path: path))
            guard enumerateDescendants else { return }
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw FileTransferBatchError.unsupportedItem(path)
            }
            var children: [(url: URL, path: String)] = []
            while let child = enumerator.nextObject() as? URL {
                guard entries.count + children.count < TransferLimits.maximumBatchEntries else {
                    throw FileTransferManifestError.invalidEntryCount(
                        entries.count + children.count + 1
                    )
                }
                let relativePath = child.pathComponents
                    .suffix(enumerator.level)
                    .joined(separator: "/")
                children.append((child, "\(path)/\(relativePath)"))
            }
            if let enumerationError { throw enumerationError }
            for child in children.sorted(by: { $0.path < $1.path }) {
                try append(
                    child.url,
                    path: child.path,
                    entries: &entries,
                    files: &files,
                    totalBytes: &totalBytes,
                    enumerateDescendants: false
                )
            }
            return
        }
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw FileTransferBatchError.unsupportedItem(path)
        }
        let sum = totalBytes.addingReportingOverflow(UInt64(size))
        guard !sum.overflow, sum.partialValue <= TransferLimits.maximumBatchBytes else {
            throw FileTransferManifestError.payloadTooLarge
        }
        totalBytes = sum.partialValue
        entries.append(.file(
            path: path,
            byteCount: UInt64(size),
            sha256: try digest(url)
        ))
        files.append(url)
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: {
            guard
                let data = try handle.read(upToCount: BulkFrame.maximumChunkSize),
                !data.isEmpty
            else { return false }
            try Task.checkCancellation()
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public final class FileTransferBatchReader {
    private let batch: FileTransferBatch
    private let files: [FileManifestEntry]
    private let chunkSize: Int
    private var index = 0
    private var handle: FileHandle?
    private var bytesRead: UInt64 = 0
    private var hasher = SHA256()

    public init(batch: FileTransferBatch, chunkSize: Int = BulkFrame.maximumChunkSize) {
        self.batch = batch
        files = batch.manifest.entries.filter { $0.kind == .file }
        self.chunkSize = max(1, min(chunkSize, BulkFrame.maximumChunkSize))
    }

    deinit { try? handle?.close() }

    public func nextChunk() throws -> Data? {
        while index < files.count {
            if handle == nil {
                handle = try FileHandle(forReadingFrom: batch.fileURLs[index])
                bytesRead = 0
                hasher = SHA256()
            }
            if let data = try handle?.read(upToCount: chunkSize), !data.isEmpty {
                bytesRead += UInt64(data.count)
                guard bytesRead <= files[index].byteCount else {
                    throw FileTransferBatchError.sourceChanged(files[index].path)
                }
                hasher.update(data: data)
                return data
            }
            try handle?.close()
            handle = nil
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard bytesRead == files[index].byteCount, digest == files[index].sha256 else {
                throw FileTransferBatchError.sourceChanged(files[index].path)
            }
            index += 1
        }
        return nil
    }
}

public enum FileTransferBatchError: Error, Sendable, Equatable {
    case unsupportedItem(String)
    case sourceChanged(String)
}

public enum FileTransferStatus: String, Sendable, Codable {
    case queued
    case awaitingApproval
    case transferring
    case verifying
    case completed
    case rejected
    case canceled
    case failed
}

public struct FileTransferNameMapping: Sendable, Equatable, Codable {
    public let original: String
    public let local: String

    public init(original: String, local: String) {
        self.original = original
        self.local = local
    }
}

public struct FileTransferHistoryEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: TransferID { transferID }
    public let transferID: TransferID
    public let name: String
    public let direction: TransferDirection
    public let totalBytes: UInt64
    public let deviceName: String
    public let startedAt: Date
    public var status: FileTransferStatus
    public let nameMappings: [FileTransferNameMapping]

    public init(
        transferID: TransferID,
        name: String,
        direction: TransferDirection,
        totalBytes: UInt64,
        deviceName: String,
        startedAt: Date,
        status: FileTransferStatus,
        nameMappings: [FileTransferNameMapping] = []
    ) {
        self.transferID = transferID
        self.name = name
        self.direction = direction
        self.totalBytes = totalBytes
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.status = status
        self.nameMappings = nameMappings
    }
}

public struct FileTransferHistoryStore: Sendable, Equatable, Codable {
    public static let maximumCount = 100
    public private(set) var entries: [FileTransferHistoryEntry] = []

    public init() {}

    public mutating func record(_ entry: FileTransferHistoryEntry) {
        entries.removeAll { $0.transferID == entry.transferID }
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumCount { entries.removeLast() }
    }

    public mutating func update(_ transferID: TransferID, status: FileTransferStatus) {
        guard let index = entries.firstIndex(where: { $0.transferID == transferID }) else { return }
        entries[index].status = status
    }

    public mutating func clear() { entries.removeAll() }
}
