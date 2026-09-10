import Foundation
import Testing
@testable import PasswallCore

@Suite("File transfer staging")
struct FileTransferStagingTests {
    @Test("Disk-space decisions fail closed at the declared byte boundary")
    func checksAvailableCapacity() {
        #expect(FileTransferStaging.hasEnoughSpace(availableBytes: 5, requiredBytes: 5))
        #expect(!FileTransferStaging.hasEnoughSpace(availableBytes: 4, requiredBytes: 5))
        #expect(!FileTransferStaging.hasEnoughSpace(availableBytes: nil, requiredBytes: 0))
    }

    @Test("Staging streams manifest files then atomically commits the batch")
    func streamsAndCommits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileTransferTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try FileTransferManifest(entries: [
            .directory(path: "报告"),
            .file(path: "报告/one.txt", byteCount: 5,
                  sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"),
            .file(path: "two.txt", byteCount: 0,
                  sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        ])
        let staging = try FileTransferStaging(
            destinationRoot: root,
            transferID: TransferID(),
            manifest: manifest
        )

        try staging.append(Data("he".utf8))
        try staging.append(Data("llo".utf8))
        let committed = try staging.finish()

        #expect(try String(contentsOf: committed.appendingPathComponent("报告/one.txt")) == "hello")
        #expect(try Data(contentsOf: committed.appendingPathComponent("two.txt")).isEmpty)
    }

    @Test("Digest failure removes the transfer-owned partial directory")
    func removesPartialOnDigestFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileTransferTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try FileTransferManifest(entries: [
            .file(path: "item.txt", byteCount: 1, sha256: String(repeating: "a", count: 64))
        ])
        let staging = try FileTransferStaging(
            destinationRoot: root,
            transferID: TransferID(),
            manifest: manifest
        )

        #expect(throws: FileTransferStagingError.digestMismatch("item.txt")) {
            try staging.append(Data("x".utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: staging.partialDirectory.path))

        let abandoned = root.appendingPathComponent(".passwall-\(UUID().uuidString.lowercased()).partial")
        let lookalike = root.appendingPathComponent(".passwall-not-a-transfer.partial")
        let unrelated = root.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try FileTransferStaging.removeAbandonedPartials(in: root)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Cancellation removes the transfer-owned partial directory")
    func removesPartialOnCancel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallFileTransferTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = try FileTransferStaging(
            destinationRoot: root,
            transferID: TransferID(),
            manifest: FileTransferManifest(entries: [
                .file(path: "item.txt", byteCount: 5, sha256: String(repeating: "a", count: 64))
            ])
        )

        try staging.append(Data("he".utf8))
        staging.cancel()

        #expect(!FileManager.default.fileExists(atPath: staging.partialDirectory.path))
    }
}
