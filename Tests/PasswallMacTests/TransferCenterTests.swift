import AppKit
import Foundation
import PasswallCore
import Testing
@testable import PasswallMac

@MainActor
@Suite("Transfer center")
struct TransferCenterTests {
    @Test("Destination and metadata-only history survive store recreation")
    func persistsTransferPreferences() throws {
        let suite = "com.passwall.transfer.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Passwall-Destination", isDirectory: true)
        let transferID = TransferID()
        let initial = AppStore(preferences: preferences)
        initial.fileTransferDestination = destination
        initial.fileTransferHistory.record(.init(
            transferID: transferID,
            name: "report.pdf",
            direction: .upload,
            totalBytes: 42,
            deviceName: "Windows PC",
            startedAt: Date(timeIntervalSince1970: 123),
            status: .completed
        ))

        let restored = AppStore(preferences: preferences)
        #expect(restored.fileTransferDestination == destination)
        #expect(restored.fileTransferHistory.entries == initial.fileTransferHistory.entries)

        restored.clearFileTransferHistory()
        #expect(AppStore(preferences: preferences).fileTransferHistory.entries.isEmpty)
    }

    @Test("Transfer is a first-class sidebar destination")
    func transferSection() {
        #expect(AppSection.allCases.contains(.transfer))
        #expect(AppSection.transfer.symbol == "arrow.left.arrow.right")
        #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    @Test("Incoming confirmation participates in quit protection")
    func incomingTransferIsActive() throws {
        let suite = "com.passwall.transfer-active.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = AppStore(preferences: preferences)
        #expect(!store.hasActiveFileTransfer)

        let manifest = try FileTransferManifest(entries: [.directory(path: "folder")])
        store.incomingFileOffer = try TransferOffer(
            transferID: TransferID(),
            kind: .files,
            direction: .download,
            totalBytes: 0,
            manifest: manifest
        )

        #expect(store.hasActiveFileTransfer)
        store.language = .chineseSimplified
        #expect(store.fileTransferMessage(FileTransferStagingError.insufficientSpace) == "磁盘空间不足")
    }

    @Test("Stale confirmation cannot act on a replacement offer")
    func staleConfirmationDoesNotReplaceCurrentOffer() throws {
        let suite = "com.passwall.transfer-stale-offer.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = AppStore(preferences: preferences)
        let manifest = try FileTransferManifest(entries: [.directory(path: "folder")])
        let first = try TransferOffer(
            transferID: TransferID(),
            kind: .files,
            direction: .download,
            totalBytes: 0,
            manifest: manifest
        )
        let replacement = try TransferOffer(
            transferID: TransferID(),
            kind: .files,
            direction: .download,
            totalBytes: 0,
            manifest: manifest
        )
        store.incomingFileOffer = replacement

        store.rejectIncomingFiles(first.transferID)
        try store.acceptIncomingFiles(first.transferID, to: store.fileTransferDestination)

        #expect(store.incomingFileOffer == replacement)
    }

    @Test("Interrupted metadata is failed on restart")
    func failsInterruptedHistoryOnRestore() throws {
        let suite = "com.passwall.transfer-restore.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var history = FileTransferHistoryStore()
        let transferID = TransferID()
        history.record(.init(
            transferID: transferID,
            name: "folder",
            direction: .download,
            totalBytes: 10,
            deviceName: "Windows PC",
            startedAt: .distantPast,
            status: .transferring
        ))
        preferences.set(try JSONEncoder().encode(history), forKey: "transfer.history")

        let restored = AppStore(preferences: preferences)
        #expect(restored.fileTransferHistory.entries.first?.status == .failed)
        #expect(!restored.hasActiveFileTransfer)
    }

    @Test("Outgoing selections queue and advance after cancellation")
    func queuesOutgoingSelections() async throws {
        let suite = "com.passwall.transfer-queue.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswallTransferQueue-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let store = AppStore(preferences: preferences)
        store.status = .connected
        store.sendFiles([first])
        store.sendFiles([second])
        try await waitUntil {
            store.fileTransferHistory.entries.contains {
                $0.name == "first.txt" && $0.status == .awaitingApproval
            }
        }
        let firstID = try #require(store.activeFileTransferID)
        #expect(store.fileTransferHistory.entries.contains {
            $0.name == "second.txt" && $0.status == .queued
        })

        store.cancelFiles(firstID)
        try await waitUntil {
            store.activeFileTransferID != nil && store.activeFileTransferID != firstID
        }
        #expect(store.fileTransferHistory.entries.first { $0.transferID == firstID }?.status == .canceled)
        store.cancelAllFiles()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for transfer state")
    }
}
