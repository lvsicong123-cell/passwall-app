import Foundation

public struct TransferID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(_ rawValue: UUID) throws {
        guard Self.isVersion4(rawValue) else {
            throw BulkFrameError.invalidTransferID
        }
        self.rawValue = rawValue
    }

    public init(_ string: String) throws {
        guard let uuid = UUID(uuidString: string), Self.isVersion4(uuid) else {
            throw BulkFrameError.invalidTransferID
        }
        rawValue = uuid
    }

    public var description: String { rawValue.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    fileprivate init(bytes: ArraySlice<UInt8>) throws {
        guard bytes.count == 16 else { throw BulkFrameError.invalidTransferID }
        var value = UUID().uuid
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyBytes(from: bytes)
        }
        try self.init(UUID(uuid: value))
    }

    fileprivate var bytes: [UInt8] {
        var value = rawValue.uuid
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    private static func isVersion4(_ uuid: UUID) -> Bool {
        var value = uuid.uuid
        return withUnsafeBytes(of: &value) { bytes in
            bytes[6] & 0xf0 == 0x40 && bytes[8] & 0xc0 == 0x80
        }
    }
}

public enum TransferDirection: String, Sendable, Codable {
    case upload
    case download
}

public enum TransferKind: String, Sendable, Codable {
    case image
    case files
}

public enum TransferLimits {
    public static let maximumImageBytes: UInt64 = 32 * 1024 * 1024
    public static let maximumBatchBytes: UInt64 = 100 * 1024 * 1024 * 1024
    public static let maximumBatchEntries = 10_000
}

public enum TrustedSessionBinding: Sendable, Equatable {
    case input
    case bulk(transferID: TransferID, direction: TransferDirection)

    public var wireLine: String {
        switch self {
        case .input:
            "SESSION input"
        case let .bulk(transferID, direction):
            "SESSION bulk \(transferID) \(direction.rawValue)"
        }
    }

    public init(wireLine: String) throws {
        let parts = wireLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.first == "SESSION" else {
            throw SessionBindingError.invalidDeclaration
        }
        if parts == ["SESSION", "input"] {
            self = .input
            return
        }
        guard
            parts.count == 4,
            parts[1] == "bulk",
            let direction = TransferDirection(rawValue: String(parts[3]))
        else {
            throw SessionBindingError.invalidDeclaration
        }
        guard let transferID = try? TransferID(String(parts[2])) else {
            throw SessionBindingError.invalidDeclaration
        }
        self = .bulk(transferID: transferID, direction: direction)
    }
}

public enum SessionBindingError: Error, Sendable, Equatable {
    case invalidDeclaration
}

public enum BulkFrameKind: UInt8, Sendable {
    case chunk = 1
    case cancel = 2
    case complete = 3
}

public struct BulkFrame: Sendable, Equatable {
    public static let headerSize = 29
    public static let maximumChunkSize = 256 * 1024
    public static let maximumEncodedSize = headerSize + maximumChunkSize

    public let kind: BulkFrameKind
    public let transferID: TransferID
    public let sequence: UInt64
    public let payload: Data

    public init(
        kind: BulkFrameKind,
        transferID: TransferID,
        sequence: UInt64,
        payload: Data = Data()
    ) throws {
        guard sequence > 0 else { throw BulkFrameError.invalidSequence }
        guard payload.count <= Self.maximumChunkSize else {
            throw BulkFrameError.payloadTooLarge(payload.count)
        }
        guard kind == .chunk || payload.isEmpty else {
            throw BulkFrameError.unexpectedPayload
        }
        self.kind = kind
        self.transferID = transferID
        self.sequence = sequence
        self.payload = payload
    }

    public func encoded() -> Data {
        var result = Data(capacity: Self.headerSize + payload.count)
        result.append(kind.rawValue)
        result.append(contentsOf: transferID.bytes)
        var sequence = sequence.bigEndian
        withUnsafeBytes(of: &sequence) { result.append(contentsOf: $0) }
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }

    fileprivate static func decode(_ data: Data) throws -> BulkFrame {
        guard data.count >= headerSize else { throw BulkFrameError.incompleteHeader }
        let bytes = [UInt8](data)
        guard let kind = BulkFrameKind(rawValue: bytes[0]) else {
            throw BulkFrameError.invalidKind(bytes[0])
        }
        let transferID = try TransferID(bytes: bytes[1..<17])
        let sequence = bytes[17..<25].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let length = bytes[25..<29].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let payloadLength = Int(length)
        guard payloadLength <= maximumChunkSize else {
            throw BulkFrameError.payloadTooLarge(payloadLength)
        }
        guard data.count == headerSize + payloadLength else {
            throw BulkFrameError.incompletePayload(
                expected: payloadLength,
                actual: data.count - headerSize
            )
        }
        return try BulkFrame(
            kind: kind,
            transferID: transferID,
            sequence: sequence,
            payload: data.suffix(payloadLength)
        )
    }
}

public enum BulkFrameError: Error, Sendable, Equatable {
    case incompleteHeader
    case incompletePayload(expected: Int, actual: Int)
    case invalidKind(UInt8)
    case invalidTransferID
    case invalidSequence
    case payloadTooLarge(Int)
    case unexpectedPayload
}

public struct BulkFrameStreamDecoder: Sendable {
    private var buffer = Data()
    public private(set) var peakBufferedByteCount = 0

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append<Bytes: DataProtocol>(_ bytes: Bytes) throws -> [BulkFrame] {
        let incoming = Data(bytes)
        var offset = 0
        var frames: [BulkFrame] = []

        do {
            while offset < incoming.count {
                if buffer.count < BulkFrame.headerSize {
                    let count = min(BulkFrame.headerSize - buffer.count, incoming.count - offset)
                    buffer.append(incoming[offset..<(offset + count)])
                    offset += count
                    peakBufferedByteCount = max(peakBufferedByteCount, buffer.count)
                    if buffer.count < BulkFrame.headerSize { continue }
                }

                let length = buffer[25..<29].reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                }
                let payloadLength = Int(length)
                guard payloadLength <= BulkFrame.maximumChunkSize else {
                    throw BulkFrameError.payloadTooLarge(payloadLength)
                }
                let frameSize = BulkFrame.headerSize + payloadLength
                let count = min(frameSize - buffer.count, incoming.count - offset)
                if count > 0 {
                    buffer.append(incoming[offset..<(offset + count)])
                    offset += count
                    peakBufferedByteCount = max(peakBufferedByteCount, buffer.count)
                }
                if buffer.count == frameSize {
                    frames.append(try BulkFrame.decode(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            return frames
        } catch {
            buffer.removeAll(keepingCapacity: true)
            throw error
        }
    }
}

public enum BulkFrameValidationError: Error, Sendable, Equatable {
    case transferMismatch
    case nonIncreasingSequence(received: UInt64, lastAccepted: UInt64)
    case transferFinished
}

public struct BulkFrameSequenceValidator: Sendable {
    public let expectedTransferID: TransferID
    public private(set) var lastAcceptedSequence: UInt64 = 0
    public private(set) var isFinished = false

    public init(expectedTransferID: TransferID) {
        self.expectedTransferID = expectedTransferID
    }

    public mutating func accept(_ frame: BulkFrame) throws {
        guard !isFinished else { throw BulkFrameValidationError.transferFinished }
        guard frame.transferID == expectedTransferID else {
            throw BulkFrameValidationError.transferMismatch
        }
        guard frame.sequence > lastAcceptedSequence else {
            throw BulkFrameValidationError.nonIncreasingSequence(
                received: frame.sequence,
                lastAccepted: lastAcceptedSequence
            )
        }
        lastAcceptedSequence = frame.sequence
        isFinished = frame.kind == .cancel || frame.kind == .complete
    }
}
