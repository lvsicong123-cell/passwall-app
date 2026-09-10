import AppKit
import Foundation
import Testing
@testable import PasswallCore
@testable import PasswallMac

@MainActor
@Suite("Clipboard monitor")
struct ClipboardMonitorTests {
    @Test("Start baselines current content and later rich content emits once")
    func baselinesAndEmitsRichContent() throws {
        let board = makePasteboard()
        board.clearContents()
        board.setString("existing", forType: .string)
        let monitor = ClipboardMonitor(pasteboard: board)
        var emitted: [ClipboardContent] = []
        monitor.onLocalChange = { emitted.append($0) }

        monitor.start()
        monitor.poll()
        #expect(emitted.isEmpty)

        board.clearContents()
        board.setString("new", forType: .string)
        board.setData(Data("{\\rtf1\\b new}".utf8), forType: .rtf)
        board.setString("<b>new</b>", forType: .html)
        monitor.poll()
        monitor.poll()

        #expect(emitted.count == 1)
        #expect(emitted[0].plainText == "new")
        #expect(emitted[0].rtf == Data("{\\rtf1\\b new}".utf8))
        #expect(emitted[0].html == "<b>new</b>")
    }

    @Test("Remote state writes all formats, ignores stale revisions, and does not echo")
    func appliesRemoteWithoutEcho() throws {
        let board = makePasteboard()
        board.clearContents()
        board.setString("local", forType: .string)
        let monitor = ClipboardMonitor(pasteboard: board)
        var sendCount = 0
        monitor.onLocalChange = { _ in sendCount += 1 }
        monitor.start()

        let first = try ClipboardContent(
            plainText: "first",
            rtf: Data("{\\rtf1 first}".utf8),
            html: "<i>first</i>"
        )
        monitor.apply(.init(revision: 2, content: first))
        monitor.apply(.init(
            revision: 1,
            content: try ClipboardContent(plainText: "stale")
        ))
        monitor.poll()

        #expect(board.string(forType: .string) == "first")
        #expect(board.data(forType: .rtf) == first.rtf)
        #expect(board.string(forType: .html) == first.html)
        #expect(sendCount == 0)
    }

    @Test("Oversized local content reports one error and is not emitted")
    func rejectsOversizedLocalContent() {
        let board = makePasteboard()
        let monitor = ClipboardMonitor(pasteboard: board)
        var sendCount = 0
        var errors: [ClipboardContentError] = []
        monitor.onLocalChange = { _ in sendCount += 1 }
        monitor.onError = { error in
            if let error = error as? ClipboardContentError {
                errors.append(error)
            }
        }
        monitor.start()

        board.clearContents()
        board.setString(
            String(repeating: "x", count: ClipboardContent.maximumRawByteCount + 1),
            forType: .string
        )
        monitor.poll()
        monitor.poll()

        #expect(sendCount == 0)
        #expect(errors == [.payloadTooLarge(524_289)])
    }

    @Test("Local PNG emits bulk bytes and remote image writes without echo")
    func transfersSingleImageWithoutEcho() throws {
        let board = makePasteboard()
        let monitor = ClipboardMonitor(pasteboard: board)
        let bytes = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        var emitted: [(ClipboardContent, Data)] = []
        var sendCount = 0
        monitor.onLocalChange = { _ in sendCount += 1 }
        monitor.onLocalImage = { emitted.append(($0, $1)) }
        monitor.start()

        board.clearContents()
        board.setData(bytes, forType: .png)
        monitor.poll()

        #expect(emitted.count == 1)
        #expect(emitted[0].1 == bytes)
        #expect(emitted[0].0.image?.format == .png)

        let remoteBytes = bytes
        let remoteContent = try ClipboardContent(image: ClipboardImageMetadata(
            transferID: TransferID(),
            format: .png,
            data: remoteBytes
        ))
        try monitor.apply(.init(revision: 2, content: remoteContent), imageData: remoteBytes)
        monitor.poll()

        #expect(board.data(forType: .png) == remoteBytes)
        #expect(sendCount == 0)
    }

    @Test("Invalid remote image does not replace the clipboard")
    func rejectsInvalidRemoteImageBeforeWrite() throws {
        let board = makePasteboard()
        board.clearContents()
        board.setString("keep", forType: .string)
        let monitor = ClipboardMonitor(pasteboard: board)
        monitor.start()
        let invalid = Data("not-an-image".utf8)
        let content = try ClipboardContent(image: ClipboardImageMetadata(
            transferID: TransferID(),
            format: .png,
            data: invalid
        ))

        #expect(throws: ClipboardMonitorError.unsupportedImage) {
            try monitor.apply(.init(revision: 1, content: content), imageData: invalid)
        }
        #expect(board.string(forType: .string) == "keep")
    }

    @Test("JPEG clipboard representation is preserved")
    func transfersJPEG() throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let representation = try #require(NSBitmapImageRep(data: png))
        let jpeg = try #require(representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.9]
        ))
        let board = makePasteboard()
        let monitor = ClipboardMonitor(pasteboard: board)
        var emitted: (ClipboardContent, Data)?
        monitor.onLocalImage = { emitted = ($0, $1) }
        monitor.start()

        board.clearContents()
        board.setData(jpeg, forType: .init("public.jpeg"))
        monitor.poll()

        #expect(emitted?.0.image?.format == .jpeg)
        #expect(emitted?.1 == jpeg)
    }

    @Test("Image acknowledgement does not hide a newer local change")
    func acknowledgementPreservesNewerLocalChange() throws {
        let board = makePasteboard()
        let monitor = ClipboardMonitor(pasteboard: board)
        let bytes = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        var texts: [String] = []
        monitor.onLocalChange = { texts.append($0.plainText) }
        monitor.start()

        board.clearContents()
        board.setData(bytes, forType: .png)
        monitor.poll()
        board.clearContents()
        board.setString("newer", forType: .string)

        let image = try ClipboardImageMetadata(
            transferID: TransferID(),
            format: .png,
            data: bytes
        )
        monitor.acknowledge(.init(
            revision: 1,
            content: try ClipboardContent(image: image)
        ))
        monitor.poll()

        #expect(texts == ["newer"])
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("com.passwall.tests.\(UUID().uuidString)"))
    }
}
