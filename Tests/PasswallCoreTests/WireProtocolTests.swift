import Foundation
import Testing
@testable import PasswallCore

@Suite("Wire protocol")
struct WireProtocolTests {
    @Test("Clipboard messages preserve rich representations")
    func clipboardRoundTrip() throws {
        let content = try ClipboardContent(
            plainText: "Passwall 链接",
            rtf: Data("{\\rtf1\\b Passwall}".utf8),
            html: "<p><strong>Passwall</strong> 链接</p>"
        )
        let message = WireMessage(
            sessionID: "session-a",
            sequence: 7,
            sentAtMicros: 100,
            payload: .clipboardState(.init(revision: 3, content: content))
        )

        let data = try JSONEncoder().encode(message)
        let json = String(decoding: data, as: UTF8.self)

        #expect(WireMessage.currentVersion == 3)
        #expect(json.contains("\"type\":\"clipboard_state\""))
        #expect(json.contains("\"rtfBase64\":"))
        #expect(try JSONDecoder().decode(WireMessage.self, from: data) == message)
    }

    @Test("Image clipboard metadata preserves format, digest, and optional text fallback")
    func imageClipboardRoundTrip() throws {
        let bytes = Data("png-image".utf8)
        let image = try ClipboardImageMetadata(
            transferID: TransferID(),
            format: .png,
            data: bytes
        )
        let content = try ClipboardContent(image: image)
        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ClipboardContent.self, from: encoded)

        #expect(decoded == content)
        #expect(decoded.plainText.isEmpty)
        #expect(try decoded.image?.validate(bytes) == true)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let wireImage = try #require(json["image"] as? [String: Any])
        #expect(wireImage["mediaType"] as? String == "image/png")
        #expect(throws: ClipboardContentError.imageDigestMismatch) {
            try image.validate(Data("changed".utf8))
        }
        #expect(throws: ClipboardContentError.imageTooLarge(
            Int(TransferLimits.maximumImageBytes + 1)
        )) {
            try ClipboardImageMetadata(
                transferID: TransferID(),
                format: .jpeg,
                data: Data(count: Int(TransferLimits.maximumImageBytes + 1))
            )
        }
    }

    @Test("Transfer control messages preserve role-bound metadata")
    func transferControlRoundTrip() throws {
        let manifest = try FileTransferManifest(entries: [
            .directory(path: "reports"),
            .file(
                path: "reports/summary.txt",
                byteCount: 42,
                sha256: String(repeating: "a", count: 64)
            )
        ])
        let offer = try TransferOffer(
            transferID: TransferID(),
            kind: .files,
            direction: .upload,
            totalBytes: 42,
            manifest: manifest
        )
        let message = WireMessage(
            sessionID: "session-a",
            sequence: 8,
            sentAtMicros: 101,
            payload: .transferOffer(offer)
        )
        let data = try JSONEncoder().encode(message)

        #expect(String(decoding: data, as: UTF8.self).contains("\"type\":\"transfer_offer\""))
        #expect(try JSONDecoder().decode(WireMessage.self, from: data) == message)
        #expect(throws: FileTransferManifestError.invalidPath("../escape")) {
            try FileTransferManifest(entries: [
                .file(
                    path: "../escape",
                    byteCount: 1,
                    sha256: String(repeating: "a", count: 64)
                )
            ])
        }
        #expect(throws: FileTransferManifestError.duplicatePath("reports")) {
            try FileTransferManifest(entries: [
                .directory(path: "reports"),
                .directory(path: "reports")
            ])
        }
        #expect(throws: FileTransferManifestError.invalidPath("file/child")) {
            try FileTransferManifest(entries: [
                .file(path: "file", byteCount: 0,
                      sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
                .file(path: "file/child", byteCount: 0,
                      sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            ])
        }
        #expect(throws: TransferOfferError.missingManifest) {
            try TransferOffer(
                transferID: TransferID(),
                kind: .files,
                direction: .upload,
                totalBytes: 0
            )
        }
        #expect(throws: TransferOfferError.payloadTooLarge(
            TransferLimits.maximumImageBytes + 1
        )) {
            try TransferOffer(
                transferID: TransferID(),
                kind: .image,
                direction: .upload,
                totalBytes: TransferLimits.maximumImageBytes + 1
            )
        }
        let oversized = Data((
            "{\"transferID\":\"\(TransferID())\",\"kind\":\"image\"," +
            "\"direction\":\"upload\",\"totalBytes\":\(TransferLimits.maximumImageBytes + 1)}"
        ).utf8)
        #expect(throws: TransferOfferError.payloadTooLarge(
            TransferLimits.maximumImageBytes + 1
        )) {
            try JSONDecoder().decode(TransferOffer.self, from: oversized)
        }
    }

    @Test("Clipboard content validates fallback, Base64, and raw size")
    func clipboardValidation() throws {
        #expect(throws: ClipboardContentError.missingPlainText) {
            try ClipboardContent(plainText: "")
        }

        let invalidRTF = Data(#"{"plainText":"x","rtfBase64":"%%%"}"#.utf8)
        #expect(throws: ClipboardContentError.invalidRTF) {
            try JSONDecoder().decode(ClipboardContent.self, from: invalidRTF)
        }

        #expect(throws: ClipboardContentError.payloadTooLarge(524_289)) {
            try ClipboardContent(plainText: String(repeating: "x", count: 524_289))
        }
    }

    @Test("Input messages round trip with an explicit event type")
    func messageRoundTrip() throws {
        let message = WireMessage(
            sessionID: "test-session",
            sequence: 42,
            sentAtMicros: 1_234_567,
            payload: .pointerMove(.init(dx: 4.5, dy: -2.25, gain: 1.25))
        )

        let data = try JSONEncoder().encode(message)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"type\":\"pointer_move\""))
        #expect(json.contains("\"gain\":1.25"))
        #expect(try JSONDecoder().decode(WireMessage.self, from: data) == message)
    }

    @Test("Remote handoff control messages round trip with normalized edge positions")
    func remoteHandoffRoundTrip() throws {
        let enter = WireMessage(
            sessionID: "test-session",
            sequence: 43,
            sentAtMicros: 1_234_568,
            payload: .remoteEnter(.init(
                remotePosition: .right,
                entryFraction: 0.375,
                activationDistance: 28
            ))
        )
        let exit = WireMessage(
            sessionID: "test-session",
            sequence: 1,
            sentAtMicros: 1_234_569,
            payload: .remoteExit(.init(entryFraction: 0.625))
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let enterData = try encoder.encode(enter)
        let exitData = try encoder.encode(exit)

        #expect(String(decoding: enterData, as: UTF8.self).contains("\"type\":\"remote_enter\""))
        #expect(String(decoding: exitData, as: UTF8.self).contains("\"type\":\"remote_exit\""))
        #expect(try decoder.decode(WireMessage.self, from: enterData) == enter)
        #expect(try decoder.decode(WireMessage.self, from: exitData) == exit)
    }

    @Test("Frames use a four-byte network-order length prefix")
    func lengthPrefix() throws {
        let payload = Data("hello".utf8)
        let framed = LengthPrefixedFramer.frame(payload)

        #expect(Array(framed.prefix(4)) == [0, 0, 0, 5])
        #expect(try LengthPrefixedFramer.unframe(framed) == payload)
    }

    @Test("Stream decoder retains partial frames and emits consecutive frames")
    func streamDecoder() throws {
        let first = LengthPrefixedFramer.frame(Data("first".utf8))
        let second = LengthPrefixedFramer.frame(Data("second".utf8))
        var decoder = LengthPrefixedStreamDecoder()

        #expect(try decoder.append(first.prefix(3)).isEmpty)

        var remainder = Data(first.dropFirst(3))
        remainder.append(second)
        let frames = try decoder.append(remainder)

        #expect(frames == [Data("first".utf8), Data("second".utf8)])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("Stream decoder rejects an oversized frame before buffering its payload")
    func streamDecoderRejectsOversizedFrame() {
        let length = UInt32(LengthPrefixedFramer.maximumPayloadSize + 1)
        let header = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff)
        ])
        var decoder = LengthPrefixedStreamDecoder()

        #expect(throws: FrameError.payloadTooLarge(Int(length))) {
            try decoder.append(header)
        }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("Inbound validation rejects duplicate and stale sequence numbers")
    func rejectsNonIncreasingSequenceNumbers() throws {
        var validator = WireMessageSequenceValidator(expectedSessionID: "live-session")
        let first = WireMessage(
            sessionID: "live-session",
            sequence: 8,
            sentAtMicros: 100,
            payload: .heartbeat
        )
        let newer = WireMessage(
            sessionID: "live-session",
            sequence: 9,
            sentAtMicros: 101,
            payload: .heartbeat
        )

        try validator.accept(first)
        #expect(throws: WireMessageValidationError.nonIncreasingSequence(received: 8, lastAccepted: 8)) {
            try validator.accept(first)
        }
        try validator.accept(newer)
        #expect(throws: WireMessageValidationError.nonIncreasingSequence(received: 7, lastAccepted: 9)) {
            try validator.accept(WireMessage(
                sessionID: "live-session",
                sequence: 7,
                sentAtMicros: 102,
                payload: .heartbeat
            ))
        }
    }

    @Test("Inbound validation binds responses to the current connection session")
    func rejectsWrongSessionAndVersion() throws {
        var validator = WireMessageSequenceValidator(expectedSessionID: "live-session")

        #expect(throws: WireMessageValidationError.sessionMismatch) {
            try validator.accept(WireMessage(
                sessionID: "old-session",
                sequence: 1,
                sentAtMicros: 100,
                payload: .heartbeat
            ))
        }
        #expect(throws: WireMessageValidationError.unsupportedVersion(99)) {
            try validator.accept(WireMessage(
                version: 99,
                sessionID: "live-session",
                sequence: 1,
                sentAtMicros: 100,
                payload: .heartbeat
            ))
        }
    }

    @Test("Heartbeat activity extends the receiver deadline")
    func heartbeatDeadline() {
        var deadline = HeartbeatDeadline(startedAtNanoseconds: 1_000)

        #expect(!deadline.hasExpired(atNanoseconds: 1_000 + 1_999_999_999))
        #expect(deadline.hasExpired(atNanoseconds: 1_000 + 2_000_000_000))

        deadline.noteActivity(atNanoseconds: 1_500_000_000)
        #expect(!deadline.hasExpired(atNanoseconds: 3_000_000_000))
        #expect(deadline.hasExpired(atNanoseconds: 3_500_000_000))
    }
}
