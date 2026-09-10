import Foundation

public struct PointerDelta: Sendable, Equatable, Codable {
    public var dx: Double
    public var dy: Double
    public var gain: Double?

    public init(dx: Double, dy: Double, gain: Double? = nil) {
        self.dx = dx
        self.dy = dy
        self.gain = gain
    }
}

public struct PointerPosition: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScrollDelta: Sendable, Equatable, Codable {
    public var horizontal: Double
    public var vertical: Double
    public var phase: String
    public var navigationEnabled: Bool?
    public var gain: Double?

    public init(
        horizontal: Double,
        vertical: Double,
        phase: String,
        navigationEnabled: Bool? = nil,
        gain: Double? = nil
    ) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.phase = phase
        self.navigationEnabled = navigationEnabled
        self.gain = gain
    }
}

public enum PointerButton: String, Sendable, Equatable, Codable {
    case left
    case right
    case middle
    case back
    case forward
}

public struct ButtonInput: Sendable, Equatable, Codable {
    public var button: PointerButton
    public var isDown: Bool

    public init(button: PointerButton, isDown: Bool) {
        self.button = button
        self.isDown = isDown
    }
}

public struct KeyInput: Sendable, Equatable, Codable {
    public var usbHIDUsage: UInt16
    public var isDown: Bool

    public init(usbHIDUsage: UInt16, isDown: Bool) {
        self.usbHIDUsage = usbHIDUsage
        self.isDown = isDown
    }
}

public struct RemoteEnter: Sendable, Equatable, Codable {
    public var remotePosition: ScreenEdge
    public var entryFraction: Double
    public var activationDistance: Double

    public init(
        remotePosition: ScreenEdge,
        entryFraction: Double,
        activationDistance: Double
    ) {
        self.remotePosition = remotePosition
        self.entryFraction = entryFraction
        self.activationDistance = activationDistance
    }
}

public struct RemoteExit: Sendable, Equatable, Codable {
    public var entryFraction: Double

    public init(entryFraction: Double) {
        self.entryFraction = entryFraction
    }
}

public struct TransferOffer: Sendable, Equatable, Codable {
    public var transferID: TransferID
    public var kind: TransferKind
    public var direction: TransferDirection
    public var totalBytes: UInt64
    public var manifest: FileTransferManifest?

    private enum CodingKeys: String, CodingKey {
        case transferID
        case kind
        case direction
        case totalBytes
        case manifest
    }

    public init(
        transferID: TransferID,
        kind: TransferKind,
        direction: TransferDirection,
        totalBytes: UInt64,
        manifest: FileTransferManifest? = nil
    ) throws {
        let maximum = kind == .image
            ? TransferLimits.maximumImageBytes
            : TransferLimits.maximumBatchBytes
        guard totalBytes <= maximum else {
            throw TransferOfferError.payloadTooLarge(totalBytes)
        }
        switch kind {
        case .image:
            guard manifest == nil else { throw TransferOfferError.unexpectedManifest }
        case .files:
            guard let manifest else { throw TransferOfferError.missingManifest }
            guard manifest.totalBytes == totalBytes else {
                throw TransferOfferError.manifestSizeMismatch
            }
        }
        self.transferID = transferID
        self.kind = kind
        self.direction = direction
        self.totalBytes = totalBytes
        self.manifest = manifest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            transferID: container.decode(TransferID.self, forKey: .transferID),
            kind: container.decode(TransferKind.self, forKey: .kind),
            direction: container.decode(TransferDirection.self, forKey: .direction),
            totalBytes: container.decode(UInt64.self, forKey: .totalBytes),
            manifest: container.decodeIfPresent(FileTransferManifest.self, forKey: .manifest)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transferID, forKey: .transferID)
        try container.encode(kind, forKey: .kind)
        try container.encode(direction, forKey: .direction)
        try container.encode(totalBytes, forKey: .totalBytes)
        try container.encodeIfPresent(manifest, forKey: .manifest)
    }
}

public enum TransferOfferError: Error, Sendable, Equatable {
    case payloadTooLarge(UInt64)
    case missingManifest
    case unexpectedManifest
    case manifestSizeMismatch
}

public struct TransferReference: Sendable, Equatable, Codable {
    public var transferID: TransferID

    public init(transferID: TransferID) {
        self.transferID = transferID
    }
}

public struct TransferProgress: Sendable, Equatable, Codable {
    public var transferID: TransferID
    public var transferredBytes: UInt64

    public init(transferID: TransferID, transferredBytes: UInt64) {
        self.transferID = transferID
        self.transferredBytes = transferredBytes
    }
}

public struct TransferFailure: Sendable, Equatable, Codable {
    public var transferID: TransferID
    public var code: String

    public init(transferID: TransferID, code: String) {
        self.transferID = transferID
        self.code = code
    }
}

public enum InputPayload: Sendable, Equatable {
    case pointerMove(PointerDelta)
    case pointerWarp(PointerPosition)
    case scroll(ScrollDelta)
    case button(ButtonInput)
    case key(KeyInput)
    case remoteEnter(RemoteEnter)
    case remoteExit(RemoteExit)
    case clipboardControl(ClipboardControl)
    case clipboardSet(ClipboardSet)
    case clipboardState(ClipboardState)
    case transferOffer(TransferOffer)
    case transferAccept(TransferReference)
    case transferReject(TransferFailure)
    case transferProgress(TransferProgress)
    case transferCancel(TransferReference)
    case transferComplete(TransferReference)
    case transferError(TransferFailure)
    case releaseAll
    case heartbeat
}

extension InputPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    private enum EventType: String, Codable {
        case pointerMove = "pointer_move"
        case pointerWarp = "pointer_warp"
        case scroll
        case button
        case key
        case remoteEnter = "remote_enter"
        case remoteExit = "remote_exit"
        case clipboardControl = "clipboard_control"
        case clipboardSet = "clipboard_set"
        case clipboardState = "clipboard_state"
        case transferOffer = "transfer_offer"
        case transferAccept = "transfer_accept"
        case transferReject = "transfer_reject"
        case transferProgress = "transfer_progress"
        case transferCancel = "transfer_cancel"
        case transferComplete = "transfer_complete"
        case transferError = "transfer_error"
        case releaseAll = "release_all"
        case heartbeat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .pointerMove:
            self = .pointerMove(try container.decode(PointerDelta.self, forKey: .data))
        case .pointerWarp:
            self = .pointerWarp(try container.decode(PointerPosition.self, forKey: .data))
        case .scroll:
            self = .scroll(try container.decode(ScrollDelta.self, forKey: .data))
        case .button:
            self = .button(try container.decode(ButtonInput.self, forKey: .data))
        case .key:
            self = .key(try container.decode(KeyInput.self, forKey: .data))
        case .remoteEnter:
            self = .remoteEnter(try container.decode(RemoteEnter.self, forKey: .data))
        case .remoteExit:
            self = .remoteExit(try container.decode(RemoteExit.self, forKey: .data))
        case .clipboardControl:
            self = .clipboardControl(try container.decode(ClipboardControl.self, forKey: .data))
        case .clipboardSet:
            self = .clipboardSet(try container.decode(ClipboardSet.self, forKey: .data))
        case .clipboardState:
            self = .clipboardState(try container.decode(ClipboardState.self, forKey: .data))
        case .transferOffer:
            self = .transferOffer(try container.decode(TransferOffer.self, forKey: .data))
        case .transferAccept:
            self = .transferAccept(try container.decode(TransferReference.self, forKey: .data))
        case .transferReject:
            self = .transferReject(try container.decode(TransferFailure.self, forKey: .data))
        case .transferProgress:
            self = .transferProgress(try container.decode(TransferProgress.self, forKey: .data))
        case .transferCancel:
            self = .transferCancel(try container.decode(TransferReference.self, forKey: .data))
        case .transferComplete:
            self = .transferComplete(try container.decode(TransferReference.self, forKey: .data))
        case .transferError:
            self = .transferError(try container.decode(TransferFailure.self, forKey: .data))
        case .releaseAll:
            self = .releaseAll
        case .heartbeat:
            self = .heartbeat
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pointerMove(data):
            try container.encode(EventType.pointerMove, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .pointerWarp(data):
            try container.encode(EventType.pointerWarp, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .scroll(data):
            try container.encode(EventType.scroll, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .button(data):
            try container.encode(EventType.button, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .key(data):
            try container.encode(EventType.key, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .remoteEnter(data):
            try container.encode(EventType.remoteEnter, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .remoteExit(data):
            try container.encode(EventType.remoteExit, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .clipboardControl(data):
            try container.encode(EventType.clipboardControl, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .clipboardSet(data):
            try container.encode(EventType.clipboardSet, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .clipboardState(data):
            try container.encode(EventType.clipboardState, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .transferOffer(data):
            try container.encode(EventType.transferOffer, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .transferAccept(data):
            try container.encode(EventType.transferAccept, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .transferReject(data):
            try container.encode(EventType.transferReject, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .transferProgress(data):
            try container.encode(EventType.transferProgress, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .transferCancel(data):
            try container.encode(EventType.transferCancel, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .transferComplete(data):
            try container.encode(EventType.transferComplete, forKey: .type)
            try container.encode(data, forKey: .data)
        case let .transferError(data):
            try container.encode(EventType.transferError, forKey: .type)
            try container.encode(data, forKey: .data)
        case .releaseAll:
            try container.encode(EventType.releaseAll, forKey: .type)
        case .heartbeat:
            try container.encode(EventType.heartbeat, forKey: .type)
        }
    }
}

public struct WireMessage: Sendable, Equatable, Codable {
    public static let currentVersion = 3

    public var version: Int
    public var sessionID: String
    public var sequence: UInt64
    public var sentAtMicros: UInt64
    public var payload: InputPayload

    public init(
        version: Int = WireMessage.currentVersion,
        sessionID: String,
        sequence: UInt64,
        sentAtMicros: UInt64,
        payload: InputPayload
    ) {
        self.version = version
        self.sessionID = sessionID
        self.sequence = sequence
        self.sentAtMicros = sentAtMicros
        self.payload = payload
    }
}

public enum WireMessageValidationError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case sessionMismatch
    case nonIncreasingSequence(received: UInt64, lastAccepted: UInt64)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Unsupported protocol version: \(version)"
        case .sessionMismatch:
            "Message used the wrong session"
        case let .nonIncreasingSequence(received, lastAccepted):
            "Message sequence \(received) did not follow \(lastAccepted)"
        }
    }
}

public struct WireMessageSequenceValidator: Sendable {
    public let expectedSessionID: String
    public private(set) var lastAcceptedSequence: UInt64 = 0

    public init(expectedSessionID: String) {
        self.expectedSessionID = expectedSessionID
    }

    public mutating func accept(_ message: WireMessage) throws {
        guard message.version == WireMessage.currentVersion else {
            throw WireMessageValidationError.unsupportedVersion(message.version)
        }
        guard message.sessionID == expectedSessionID else {
            throw WireMessageValidationError.sessionMismatch
        }
        guard message.sequence > lastAcceptedSequence else {
            throw WireMessageValidationError.nonIncreasingSequence(
                received: message.sequence,
                lastAccepted: lastAcceptedSequence
            )
        }
        lastAcceptedSequence = message.sequence
    }
}

public enum FrameError: Error, Equatable {
    case incompleteHeader
    case incompletePayload(expected: Int, actual: Int)
    case payloadTooLarge(Int)
}

public enum LengthPrefixedFramer {
    public static let maximumPayloadSize = 1_048_576

    public static func frame(_ payload: Data) -> Data {
        precondition(payload.count <= maximumPayloadSize, "Payload exceeds protocol limit")
        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(payload)
        return result
    }

    public static func unframe(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else {
            throw FrameError.incompleteHeader
        }

        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let expected = Int(length)
        guard expected <= maximumPayloadSize else {
            throw FrameError.payloadTooLarge(expected)
        }

        let payload = frame.dropFirst(4)
        guard payload.count == expected else {
            throw FrameError.incompletePayload(expected: expected, actual: payload.count)
        }
        return Data(payload)
    }
}

public struct LengthPrefixedStreamDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append<Bytes: DataProtocol>(_ bytes: Bytes) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []

        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let payloadLength = Int(length)
            guard payloadLength <= LengthPrefixedFramer.maximumPayloadSize else {
                buffer.removeAll(keepingCapacity: false)
                throw FrameError.payloadTooLarge(payloadLength)
            }

            let frameLength = MemoryLayout<UInt32>.size + payloadLength
            guard buffer.count >= frameLength else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let frameEnd = buffer.index(buffer.startIndex, offsetBy: frameLength)
            frames.append(Data(buffer[payloadStart..<frameEnd]))
            buffer.removeSubrange(buffer.startIndex..<frameEnd)
        }

        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
