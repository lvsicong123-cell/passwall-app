import Foundation
import Testing
import PasswallCore
@testable import PasswallMac

@Suite("Mac bulk connection")
struct BulkConnectionTests {
    @Test("Download frames enforce the accepted byte count")
    func downloadByteCount() async throws {
        let transferID = TransferID()
        let receiver = BulkFrameReceiver(transferID: transferID, expectedBytes: 3)

        let chunk = try BulkFrame(
            kind: .chunk,
            transferID: transferID,
            sequence: 1,
            payload: Data([1, 2, 3])
        )
        let first = try await receiver.append(chunk.encoded())
        #expect(first.frames == [chunk])
        #expect(!first.isFinished)

        let complete = try BulkFrame(
            kind: .complete,
            transferID: transferID,
            sequence: 2
        )
        let terminal = try await receiver.append(complete.encoded())
        #expect(terminal.frames == [complete])
        #expect(terminal.isFinished)
    }

    @Test("Download completion rejects a short body")
    func rejectsShortDownload() async throws {
        let transferID = TransferID()
        let receiver = BulkFrameReceiver(transferID: transferID, expectedBytes: 2)
        let complete = try BulkFrame(
            kind: .complete,
            transferID: transferID,
            sequence: 1
        )

        await #expect(throws: BulkConnectionError.sizeMismatch) {
            try await receiver.append(complete.encoded())
        }
    }

    @Test("Download cancellation may terminate a partial body")
    func downloadCancellation() async throws {
        let transferID = TransferID()
        let receiver = BulkFrameReceiver(transferID: transferID, expectedBytes: 10)
        let cancel = try BulkFrame(
            kind: .cancel,
            transferID: transferID,
            sequence: 1
        )

        let result = try await receiver.append(cancel.encoded())
        #expect(result.isFinished)
    }
}
