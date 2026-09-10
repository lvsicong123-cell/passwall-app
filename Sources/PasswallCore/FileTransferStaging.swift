import CryptoKit
import Foundation

public enum FileTransferStagingError: Error, Sendable, Equatable {
    case sizeMismatch
    case digestMismatch(String)
    case alreadyFinished
    case insufficientSpace
    case stagingCollision
}

public final class FileTransferStaging {
    public let partialDirectory: URL

    private let destinationRoot: URL
    private let manifest: FileTransferManifest
    private let files: [FileManifestEntry]
    private var fileIndex = 0
    private var byteCount: UInt64 = 0
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var finished = false

    public static func removeAbandonedPartials(in destinationRoot: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(
            at: destinationRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for item in items where Self.partialTransferID(from: item.lastPathComponent) != nil {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try FileManager.default.removeItem(at: item)
            }
        }
    }

    public init(
        destinationRoot: URL,
        transferID: TransferID,
        manifest: FileTransferManifest
    ) throws {
        self.destinationRoot = destinationRoot
        self.manifest = manifest
        files = manifest.entries.filter { $0.kind == .file }
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        let volume = try destinationRoot.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let capacity = volume.volumeAvailableCapacityForImportantUsage
            ?? volume.volumeAvailableCapacity.map(Int64.init)
        guard Self.hasEnoughSpace(
            availableBytes: capacity,
            requiredBytes: manifest.totalBytes
        ) else {
            throw FileTransferStagingError.insufficientSpace
        }
        partialDirectory = destinationRoot.appendingPathComponent(
            ".passwall-\(transferID.description).partial",
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: partialDirectory.path) else {
            throw FileTransferStagingError.stagingCollision
        }
        try FileManager.default.createDirectory(
            at: partialDirectory,
            withIntermediateDirectories: true
        )
        do {
            for entry in manifest.entries where entry.kind == .directory {
                try FileManager.default.createDirectory(
                    at: Self.url(for: entry, under: partialDirectory),
                    withIntermediateDirectories: true
                )
            }
            try prepareNextFile()
        } catch {
            cleanup()
            throw error
        }
    }

    deinit { cleanup() }

    public func append(_ data: Data) throws {
        guard !finished else { throw FileTransferStagingError.alreadyFinished }
        do {
            var offset = data.startIndex
            while offset < data.endIndex {
                guard fileIndex < files.count, let handle else {
                    throw FileTransferStagingError.sizeMismatch
                }
                let remaining = files[fileIndex].byteCount - byteCount
                let count = min(Int(remaining), data.distance(from: offset, to: data.endIndex))
                let chunk = data[offset..<(offset + count)]
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                byteCount += UInt64(count)
                offset += count
                if byteCount == files[fileIndex].byteCount {
                    try finalizeCurrentFile()
                }
            }
        } catch {
            cleanup()
            throw error
        }
    }

    public func finish() throws -> URL {
        guard !finished else { throw FileTransferStagingError.alreadyFinished }
        do {
            try prepareNextFile()
            guard fileIndex == files.count else {
                throw FileTransferStagingError.sizeMismatch
            }
            let destination = resolvedDestination()
            try FileManager.default.moveItem(at: partialDirectory, to: destination)
            finished = true
            return destination
        } catch {
            cleanup()
            throw error
        }
    }

    public func cancel() { cleanup() }

    static func hasEnoughSpace(availableBytes: Int64?, requiredBytes: UInt64) -> Bool {
        guard let availableBytes, availableBytes >= 0 else { return false }
        return UInt64(availableBytes) >= requiredBytes
    }

    private func prepareNextFile() throws {
        while fileIndex < files.count {
            let entry = files[fileIndex]
            let fileURL = Self.url(for: entry, under: partialDirectory)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw FileTransferStagingError.stagingCollision
            }
            handle = try FileHandle(forWritingTo: fileURL)
            byteCount = 0
            hasher = SHA256()
            if entry.byteCount != 0 { return }
            try finalizeCurrentFile()
        }
    }

    private func finalizeCurrentFile() throws {
        let entry = files[fileIndex]
        try handle?.close()
        handle = nil
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else {
            throw FileTransferStagingError.digestMismatch(entry.path)
        }
        fileIndex += 1
        try prepareNextFile()
    }

    private func resolvedDestination() -> URL {
        let stem = "Passwall-\(UUID().uuidString.lowercased())"
        var candidate = destinationRoot.appendingPathComponent(stem, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destinationRoot.appendingPathComponent("\(stem) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func cleanup() {
        try? handle?.close()
        handle = nil
        guard !finished else { return }
        try? FileManager.default.removeItem(at: partialDirectory)
    }

    private static func url(for entry: FileManifestEntry, under root: URL) -> URL {
        root.appendingPathComponent(entry.path, isDirectory: entry.kind == .directory)
    }

    private static func partialTransferID(from name: String) -> UUID? {
        let prefix = ".passwall-"
        let suffix = ".partial"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }
}
