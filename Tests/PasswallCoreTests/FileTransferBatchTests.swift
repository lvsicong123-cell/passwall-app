import Foundation
import Testing
@testable import PasswallCore

@Suite("File transfer batch")
struct FileTransferBatchTests {
    @Test("Manifest accepts exact public-alpha limits and rejects overflow")
    func enforcesManifestLimits() throws {
        let digest = String(repeating: "a", count: 64)
        let entries = (0..<TransferLimits.maximumBatchEntries).map {
            FileManifestEntry.file(path: "item-\($0)", byteCount: 0, sha256: digest)
        }

        #expect(try FileTransferManifest(entries: entries).entries.count == entries.count)
        #expect(throws: FileTransferManifestError.invalidEntryCount(entries.count + 1)) {
            try FileTransferManifest(entries: entries + [
                .file(path: "overflow", byteCount: 0, sha256: digest)
            ])
        }
        #expect(try FileTransferManifest(entries: [
            .file(path: "exact", byteCount: TransferLimits.maximumBatchBytes, sha256: digest)
        ]).totalBytes == TransferLimits.maximumBatchBytes)
        #expect(throws: FileTransferManifestError.payloadTooLarge) {
            try FileTransferManifest(entries: [
                .file(
                    path: "overflow",
                    byteCount: TransferLimits.maximumBatchBytes + 1,
                    sha256: digest
                )
            ])
        }
    }

    @Test("Oversized sources are rejected before file contents are read")
    func rejectsOversizedSourceBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileBatchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("oversized.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: TransferLimits.maximumBatchBytes + 1)
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)

        #expect(throws: FileTransferManifestError.payloadTooLarge) {
            try FileTransferBatch.build(from: [file])
        }
    }

    @Test("Outgoing discovery stops at the batch entry limit")
    func stopsDiscoveryAtEntryLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileBatchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let selections = Array(
            repeating: root,
            count: TransferLimits.maximumBatchEntries + 1
        )

        #expect(throws: FileTransferManifestError.invalidEntryCount(selections.count)) {
            try FileTransferBatch.build(from: selections)
        }
    }

    @Test("Selected files and folders produce a deterministic bounded stream")
    func buildsAndStreams() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileBatchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("one.txt"))
        try Data("!".utf8).write(to: root.appendingPathComponent("two.txt"))

        let batch = try FileTransferBatch.build(from: [folder, root.appendingPathComponent("two.txt")])
        let reader = FileTransferBatchReader(batch: batch, chunkSize: 2)
        var body = Data()
        while let chunk = try reader.nextChunk() { body.append(chunk) }

        #expect(batch.manifest.entries.map(\.path) == ["folder", "folder/one.txt", "two.txt"])
        #expect(batch.manifest.totalBytes == 6)
        #expect(body == Data("hello!".utf8))
    }

    @Test("Symbolic links are rejected before an offer is created")
    func rejectsSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileBatchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: FileTransferBatchError.unsupportedItem("link.txt")) {
            try FileTransferBatch.build(from: [link])
        }
    }

    @Test("Retry rebuilds the batch from the current source")
    func retriesFromStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileBatchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("item.txt")
        try Data("first".utf8).write(to: file)
        let stale = try FileTransferBatch.build(from: [file])
        try Data("newer".utf8).write(to: file)
        let staleReader = FileTransferBatchReader(batch: stale)
        _ = try staleReader.nextChunk()
        #expect(throws: FileTransferBatchError.sourceChanged("item.txt")) {
            _ = try staleReader.nextChunk()
        }

        let retry = try FileTransferBatch.build(from: [file])
        let retryReader = FileTransferBatchReader(batch: retry)
        #expect(try retryReader.nextChunk() == Data("newer".utf8))
        #expect(try retryReader.nextChunk() == nil)
    }

    @Test("Large files remain split into bounded chunks")
    func streamsLargeFileInChunks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileBatchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let size = BulkFrame.maximumChunkSize * 2 + 1
        let file = root.appendingPathComponent("large.bin")
        try Data(repeating: 0x5a, count: size).write(to: file)

        let reader = FileTransferBatchReader(batch: try FileTransferBatch.build(from: [file]))
        var chunkSizes: [Int] = []
        while let chunk = try reader.nextChunk() { chunkSizes.append(chunk.count) }

        #expect(chunkSizes == [BulkFrame.maximumChunkSize, BulkFrame.maximumChunkSize, 1])
    }

    @Test("History is metadata-only, bounded, updateable, and clearable")
    func boundedHistory() {
        var history = FileTransferHistoryStore()
        for index in 0...FileTransferHistoryStore.maximumCount {
            history.record(.init(
                transferID: TransferID(),
                name: "batch-\(index)",
                direction: .upload,
                totalBytes: UInt64(index),
                deviceName: "Test PC",
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                status: .queued
            ))
        }
        #expect(history.entries.count == FileTransferHistoryStore.maximumCount)
        #expect(history.entries.first?.name == "batch-100")
        let newest = history.entries[0].transferID
        history.update(newest, status: .failed)
        #expect(history.entries[0].status == .failed)
        history.clear()
        #expect(history.entries.isEmpty)
    }
}
