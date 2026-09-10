import AppKit
import Foundation
import ImageIO
import PasswallCore
import UniformTypeIdentifiers

enum ClipboardMonitorError: Error, LocalizedError {
    case unavailable
    case unsupportedImage

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Clipboard is unavailable"
        case .unsupportedImage:
            "Clipboard image could not be converted to PNG or JPEG"
        }
    }
}

@MainActor
final class ClipboardMonitor {
    var onLocalChange: ((ClipboardContent) -> Void)?
    var onLocalImage: ((ClipboardContent, Data) -> Void)?
    var onError: ((Error) -> Void)?

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var baselineChangeCount: Int
    private var lastAcceptedRevision: UInt64 = 0

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        baselineChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        baselineChangeCount = pasteboard.changeCount
        lastAcceptedRevision = 0

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != baselineChangeCount else { return }
        baselineChangeCount = changeCount

        do {
            let plainText = pasteboard.string(forType: .string) ?? ""
            let rtf = plainText.isEmpty ? nil : pasteboard.data(forType: .rtf)
            let html = plainText.isEmpty ? nil : pasteboard.string(forType: .html)
            if let (format, data) = try readImage() {
                let image = try ClipboardImageMetadata(
                    transferID: TransferID(),
                    format: format,
                    data: data
                )
                let content = try ClipboardContent(
                    plainText: plainText,
                    rtf: rtf,
                    html: html,
                    image: image
                )
                onLocalImage?(content, data)
                return
            }
            guard !plainText.isEmpty else { return }
            let content = try ClipboardContent(
                plainText: plainText,
                rtf: rtf,
                html: html
            )
            onLocalChange?(content)
        } catch {
            if let plainText = pasteboard.string(forType: .string), !plainText.isEmpty,
               let fallback = try? ClipboardContent(
                   plainText: plainText,
                   rtf: pasteboard.data(forType: .rtf),
                   html: pasteboard.string(forType: .html)
               ) {
                onLocalChange?(fallback)
            } else {
                onError?(error)
            }
        }
    }

    func apply(_ state: ClipboardState) {
        guard state.revision > lastAcceptedRevision else { return }

        guard state.content.image == nil else {
            onError?(ClipboardMonitorError.unsupportedImage)
            return
        }

        write(state, imageData: nil)
    }

    func apply(_ state: ClipboardState, imageData: Data) throws {
        guard state.revision > lastAcceptedRevision else { return }
        guard let image = state.content.image else {
            throw ClipboardMonitorError.unsupportedImage
        }
        try image.validate(imageData)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == image.format.typeIdentifier else {
            throw ClipboardMonitorError.unsupportedImage
        }
        guard write(state, imageData: imageData) else {
            throw ClipboardMonitorError.unavailable
        }
    }

    func acknowledge(_ state: ClipboardState) {
        guard state.revision > lastAcceptedRevision else { return }
        lastAcceptedRevision = state.revision
    }

    private func readImage() throws -> (ClipboardImageFormat, Data)? {
        if let png = pasteboard.data(forType: .png) {
            return (.png, png)
        }
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        if let jpeg = pasteboard.data(forType: jpegType) {
            return (.jpeg, jpeg)
        }
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        guard tiff.count <= Int(TransferLimits.maximumImageBytes),
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            throw ClipboardMonitorError.unsupportedImage
        }
        return (.png, png)
    }

    @discardableResult
    private func write(_ state: ClipboardState, imageData: Data?) -> Bool {
        let content = state.content

        let item = NSPasteboardItem()
        guard (content.plainText.isEmpty || item.setString(content.plainText, forType: .string)),
              content.rtf.map({ item.setData($0, forType: .rtf) }) ?? true,
              content.html.map({ item.setString($0, forType: .html) }) ?? true,
              content.image.map({ image in
                  guard let imageData else { return false }
                  let type: NSPasteboard.PasteboardType = image.format == .png
                      ? .png
                      : .init("public.jpeg")
                  return item.setData(imageData, forType: type)
              }) ?? true else {
            onError?(ClipboardMonitorError.unavailable)
            return false
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            onError?(ClipboardMonitorError.unavailable)
            return false
        }

        lastAcceptedRevision = state.revision
        baselineChangeCount = pasteboard.changeCount
        return true
    }
}

private extension ClipboardImageFormat {
    var typeIdentifier: String {
        switch self {
        case .png:
            UTType.png.identifier
        case .jpeg:
            UTType.jpeg.identifier
        }
    }
}
