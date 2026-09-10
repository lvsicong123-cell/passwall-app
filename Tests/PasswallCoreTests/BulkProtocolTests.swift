import Foundation
import Testing
@testable import PasswallCore

@Suite("Bulk protocol")
struct BulkProtocolTests {
    @Test("Session declarations bind input or one transfer direction")
    func sessionBinding() throws {
        let transferID = TransferID()
        let bulk = TrustedSessionBinding.bulk(
            transferID: transferID,
            direction: .download
        )

        #expect(try TrustedSessionBinding(wireLine: "SESSION input") == .input)
        #expect(try TrustedSessionBinding(wireLine: bulk.wireLine) == bulk)
        #expect(throws: SessionBindingError.invalidDeclaration) {
            try TrustedSessionBinding(wireLine: "SESSION bulk")
        }
        #expect(throws: SessionBindingError.invalidDeclaration) {
            try TrustedSessionBinding(
                wireLine: "SESSION bulk 11111111-2222-3333-4444-555555555555 upload"
            )
        }
    }

    @Test("Chunk frames round trip incrementally with bounded buffering")
    func chunkRoundTrip() throws {
        let transferID = TransferID()
        let frame = try BulkFrame(
            kind: .chunk,
            transferID: transferID,
            sequence: 1,
            payload: Data(repeating: 0xa5, count: BulkFrame.maximumChunkSize)
        )
        let encoded = frame.encoded()
        var decoder = BulkFrameStreamDecoder()

        #expect(try decoder.append(encoded.prefix(12)).isEmpty)
        let decoded = try decoder.append(encoded.dropFirst(12))

        #expect(decoded == [frame])
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.peakBufferedByteCount <= BulkFrame.maximumEncodedSize)
    }

    @Test("Binary framing matches the cross-platform vector")
    func crossPlatformVector() throws {
        let frame = try BulkFrame(
            kind: .chunk,
            transferID: TransferID("11111111-2222-4333-8444-555555555555"),
            sequence: 1,
            payload: Data([0xaa])
        )

        #expect(frame.encoded().map { String(format: "%02x", $0) }.joined() ==
            "0111111111222243338444555555555555000000000000000100000001aa")
    }

    @Test("Oversized chunks are rejected from their header")
    func rejectsOversizedChunk() throws {
        let transferID = TransferID()
        var encoded = try BulkFrame(
            kind: .chunk,
            transferID: transferID,
            sequence: 1,
            payload: Data([1])
        ).encoded()
        let oversized = UInt32(BulkFrame.maximumChunkSize + 1).bigEndian
        withUnsafeBytes(of: oversized) { bytes in
            encoded.replaceSubrange(25..<29, with: bytes)
        }
        var decoder = BulkFrameStreamDecoder()

        #expect(throws: BulkFrameError.payloadTooLarge(BulkFrame.maximumChunkSize + 1)) {
            try decoder.append(encoded.prefix(BulkFrame.headerSize))
        }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("Sequence validation binds a transfer and closes on cancellation")
    func sequenceValidation() throws {
        let transferID = TransferID()
        let otherID = TransferID()
        var validator = BulkFrameSequenceValidator(expectedTransferID: transferID)
        let first = try BulkFrame(
            kind: .chunk,
            transferID: transferID,
            sequence: 1,
            payload: Data([1])
        )

        try validator.accept(first)
        #expect(throws: BulkFrameValidationError.nonIncreasingSequence(
            received: 1,
            lastAccepted: 1
        )) {
            try validator.accept(first)
        }
        #expect(throws: BulkFrameValidationError.transferMismatch) {
            try validator.accept(BulkFrame(
                kind: .chunk,
                transferID: otherID,
                sequence: 2,
                payload: Data([2])
            ))
        }

        try validator.accept(BulkFrame(
            kind: .cancel,
            transferID: transferID,
            sequence: 2
        ))
        #expect(throws: BulkFrameValidationError.transferFinished) {
            try validator.accept(BulkFrame(
                kind: .complete,
                transferID: transferID,
                sequence: 3
            ))
        }
    }
}
