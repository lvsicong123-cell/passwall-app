import CryptoKit
import Foundation

public enum ClipboardContentError: Error, Sendable, Equatable, LocalizedError {
    case missingPlainText
    case invalidRTF
    case payloadTooLarge(Int)
    case invalidImageMetadata
    case imageTooLarge(Int)
    case imageDigestMismatch

    public var errorDescription: String? {
        switch self {
        case .missingPlainText:
            "Clipboard requires a plain-text fallback"
        case .invalidRTF:
            "Clipboard contains invalid RTF"
        case .payloadTooLarge:
            "Clipboard item exceeds 512 KiB"
        case .invalidImageMetadata:
            "Clipboard image metadata is invalid"
        case .imageTooLarge:
            "Clipboard image exceeds 32 MiB"
        case .imageDigestMismatch:
            "Clipboard image failed integrity validation"
        }
    }
}

public enum ClipboardImageFormat: String, Sendable, Equatable, Codable {
    case png = "image/png"
    case jpeg = "image/jpeg"
}

public struct ClipboardImageMetadata: Sendable, Equatable, Codable {
    public let transferID: TransferID
    public let format: ClipboardImageFormat
    public let byteCount: UInt64
    public let sha256: String

    private enum CodingKeys: String, CodingKey {
        case transferID
        case format = "mediaType"
        case byteCount
        case sha256
    }

    public init(
        transferID: TransferID,
        format: ClipboardImageFormat,
        byteCount: UInt64,
        sha256: String
    ) throws {
        guard byteCount > 0, byteCount <= TransferLimits.maximumImageBytes else {
            throw ClipboardContentError.imageTooLarge(Int(clamping: byteCount))
        }
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ClipboardContentError.invalidImageMetadata
        }
        self.transferID = transferID
        self.format = format
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public init(
        transferID: TransferID,
        format: ClipboardImageFormat,
        data: Data
    ) throws {
        try self.init(
            transferID: transferID,
            format: format,
            byteCount: UInt64(data.count),
            sha256: Self.digest(data)
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            transferID: container.decode(TransferID.self, forKey: .transferID),
            format: container.decode(ClipboardImageFormat.self, forKey: .format),
            byteCount: container.decode(UInt64.self, forKey: .byteCount),
            sha256: container.decode(String.self, forKey: .sha256)
        )
    }

    @discardableResult
    public func validate(_ data: Data) throws -> Bool {
        guard data.count <= Int(TransferLimits.maximumImageBytes) else {
            throw ClipboardContentError.imageTooLarge(data.count)
        }
        guard UInt64(data.count) == byteCount, Self.digest(data) == sha256 else {
            throw ClipboardContentError.imageDigestMismatch
        }
        return true
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClipboardContent: Sendable, Equatable {
    public static let maximumRawByteCount = 524_288

    public let plainText: String
    public let rtf: Data?
    public let html: String?
    public let image: ClipboardImageMetadata?

    public init(
        plainText: String = "",
        rtf: Data? = nil,
        html: String? = nil,
        image: ClipboardImageMetadata? = nil
    ) throws {
        guard !plainText.isEmpty || image != nil else {
            throw ClipboardContentError.missingPlainText
        }
        let rawByteCount = plainText.utf8.count
            + (rtf?.count ?? 0)
            + (html?.utf8.count ?? 0)
        guard rawByteCount <= Self.maximumRawByteCount else {
            throw ClipboardContentError.payloadTooLarge(rawByteCount)
        }

        self.plainText = plainText
        self.rtf = rtf
        self.html = html
        self.image = image
    }
}

extension ClipboardContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case plainText
        case rtfBase64
        case html
        case image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let plainText = try container.decodeIfPresent(String.self, forKey: .plainText) ?? ""
        let html = try container.decodeIfPresent(String.self, forKey: .html)
        let image = try container.decodeIfPresent(ClipboardImageMetadata.self, forKey: .image)
        let rtf: Data?
        if let encoded = try container.decodeIfPresent(String.self, forKey: .rtfBase64) {
            guard let decoded = Data(base64Encoded: encoded) else {
                throw ClipboardContentError.invalidRTF
            }
            rtf = decoded
        } else {
            rtf = nil
        }
        try self.init(plainText: plainText, rtf: rtf, html: html, image: image)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(plainText, forKey: .plainText)
        try container.encodeIfPresent(rtf?.base64EncodedString(), forKey: .rtfBase64)
        try container.encodeIfPresent(html, forKey: .html)
        try container.encodeIfPresent(image, forKey: .image)
    }
}

public struct ClipboardControl: Sendable, Equatable, Codable {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct ClipboardSet: Sendable, Equatable, Codable {
    public let content: ClipboardContent

    public init(content: ClipboardContent) {
        self.content = content
    }
}

public struct ClipboardState: Sendable, Equatable, Codable {
    public let revision: UInt64
    public let content: ClipboardContent

    public init(revision: UInt64, content: ClipboardContent) {
        self.revision = revision
        self.content = content
    }
}
