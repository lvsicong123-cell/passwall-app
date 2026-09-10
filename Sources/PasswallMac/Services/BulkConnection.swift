import Foundation
import Network
import PasswallCore

enum BulkConnectionState: Equatable {
    case idle
    case connecting
    case ready
    case failed(String)
}

enum BulkConnectionError: LocalizedError, Equatable {
    case notReady
    case unexpectedEOF
    case sizeMismatch
    case inactivityTimeout
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            "Bulk connection is not ready"
        case .unexpectedEOF:
            "Bulk connection ended before completion"
        case .sizeMismatch:
            "Bulk content did not match its declared size"
        case .inactivityTimeout:
            "Bulk peer made no progress for 30 seconds"
        case let .transport(message):
            message
        }
    }
}

@MainActor
final class BulkConnection {
    private static let inactivityTimeout = Duration.seconds(30)

    var onStateChanged: ((BulkConnectionState) -> Void)?
    var onFrame: (@Sendable (BulkFrame) async throws -> Void)?

    private let verifier: TLSIdentityVerifier
    private var connection: NWConnection?
    private var transferID: TransferID?
    private var direction: TransferDirection?
    private var expectedBytes: UInt64 = 0
    private var transferredBytes: UInt64 = 0
    private var sequence: UInt64 = 0
    private var receiver: BulkFrameReceiver?
    private var receiveDeadline: Task<Void, Never>?
    private var sendDeadline: Task<Void, Never>?
    private var pendingSend: CheckedContinuation<Void, Error>?
    private(set) var state = BulkConnectionState.idle {
        didSet { onStateChanged?(state) }
    }

    init(verifier: TLSIdentityVerifier = TLSIdentityVerifier()) {
        self.verifier = verifier
        verifier.onStateChanged = { [weak self] verifierState in
            guard case let .failed(_, message) = verifierState else { return }
            self?.fail(message)
        }
        verifier.onAuthenticatedConnection = { [weak self] _, connection in
            self?.adopt(connection)
        }
    }

    func connect(
        to device: DiscoveredWindowsDevice,
        transferID: TransferID,
        direction: TransferDirection,
        totalBytes: UInt64
    ) {
        disconnect()
        self.transferID = transferID
        self.direction = direction
        expectedBytes = totalBytes
        receiver = BulkFrameReceiver(
            transferID: transferID,
            expectedBytes: totalBytes
        )
        state = .connecting
        verifier.verify(
            device,
            binding: .bulk(transferID: transferID, direction: direction)
        )
    }

    func sendChunk(_ payload: Data) async throws {
        try await send(kind: .chunk, payload: payload)
    }

    func send(
        _ batch: FileTransferBatch,
        onProgress: @MainActor (UInt64) -> Void = { _ in }
    ) async throws {
        let reader = FileTransferBatchReader(batch: batch)
        var sent: UInt64 = 0
        while let chunk = try reader.nextChunk() {
            try Task.checkCancellation()
            try await sendChunk(chunk)
            sent += UInt64(chunk.count)
            onProgress(sent)
        }
        try await complete()
    }

    func complete() async throws {
        guard transferredBytes == expectedBytes else {
            throw BulkConnectionError.sizeMismatch
        }
        try await send(kind: .complete, closeAfterSending: true)
    }

    func cancel() async {
        guard state == .ready else {
            disconnect()
            return
        }
        if direction == .upload {
            do {
                try await send(kind: .cancel, closeAfterSending: true)
            } catch {
                disconnect()
            }
        } else {
            disconnect()
        }
    }

    func disconnect() {
        let pendingSend = pendingSend
        self.pendingSend = nil
        verifier.cancel()
        connection?.cancel()
        cancelDeadlines()
        connection = nil
        transferID = nil
        direction = nil
        expectedBytes = 0
        transferredBytes = 0
        sequence = 0
        receiver = nil
        state = .idle
        pendingSend?.resume(throwing: BulkConnectionError.notReady)
    }

    private func adopt(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch connectionState {
                case let .waiting(error), let .failed(error):
                    self.fail(error.localizedDescription)
                case .cancelled:
                    self.disconnect()
                default:
                    break
                }
            }
        }
        state = .ready
        if direction == .download {
            receiveNext(on: connection)
        }
    }

    private func send(
        kind: BulkFrameKind,
        payload: Data = Data(),
        closeAfterSending: Bool = false
    ) async throws {
        guard
            state == .ready,
            direction == .upload,
            let connection,
            let transferID,
            pendingSend == nil
        else {
            throw BulkConnectionError.notReady
        }
        sequence &+= 1
        let frame = try BulkFrame(
            kind: kind,
            transferID: transferID,
            sequence: sequence,
            payload: payload
        )
        if kind == .chunk {
            let nextTotal = transferredBytes.addingReportingOverflow(UInt64(payload.count))
            guard !nextTotal.overflow, nextTotal.partialValue <= expectedBytes else {
                throw BulkConnectionError.sizeMismatch
            }
            transferredBytes = nextTotal.partialValue
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingSend = continuation
            sendDeadline = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.inactivityTimeout)
                } catch {
                    return
                }
                self?.finishSend(
                    on: connection,
                    error: BulkConnectionError.inactivityTimeout,
                    closeAfterSending: false
                )
            }
            connection.send(
                content: frame.encoded(),
                completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in
                        self?.finishSend(
                            on: connection,
                            error: error,
                            closeAfterSending: closeAfterSending
                        )
                    }
                }
            )
        }
    }

    private func receiveNext(on connection: NWConnection) {
        guard let receiver else {
            fail(BulkConnectionError.notReady.localizedDescription)
            return
        }
        receiveDeadline?.cancel()
        receiveDeadline = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.inactivityTimeout)
            } catch {
                return
            }
            guard let self, self.connection === connection else { return }
            self.fail("No bulk content received for 30 seconds")
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                do {
                    guard let self, self.connection === connection else { return }
                    self.receiveDeadline?.cancel()
                    self.receiveDeadline = nil
                    let result = try await receiver.append(data ?? Data())
                    if let error { throw error }
                    if isComplete && !result.isFinished {
                        throw BulkConnectionError.unexpectedEOF
                    }
                    let handler = self.onFrame
                    for frame in result.frames {
                        try await handler?(frame)
                    }
                    guard self.connection === connection else { return }
                    if result.isFinished {
                        self.disconnect()
                    } else {
                        self.receiveNext(on: connection)
                    }
                } catch {
                    guard let self, self.connection === connection else { return }
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func fail(_ message: String) {
        let pendingSend = pendingSend
        self.pendingSend = nil
        connection?.cancel()
        connection = nil
        cancelDeadlines()
        state = .failed(message)
        pendingSend?.resume(throwing: BulkConnectionError.transport(message))
    }

    private func finishSend(
        on connection: NWConnection,
        error: Error?,
        closeAfterSending: Bool
    ) {
        guard self.connection === connection, let pendingSend else { return }
        self.pendingSend = nil
        sendDeadline?.cancel()
        sendDeadline = nil
        if let error {
            fail(error.localizedDescription)
            pendingSend.resume(throwing: error)
        } else {
            if closeAfterSending { disconnect() }
            pendingSend.resume()
        }
    }

    private func cancelDeadlines() {
        receiveDeadline?.cancel()
        receiveDeadline = nil
        sendDeadline?.cancel()
        sendDeadline = nil
    }
}

actor BulkFrameReceiver {
    struct Result: Sendable {
        let frames: [BulkFrame]
        let isFinished: Bool
    }

    private var decoder = BulkFrameStreamDecoder()
    private var validator: BulkFrameSequenceValidator
    private let expectedBytes: UInt64
    private var transferredBytes: UInt64 = 0

    init(transferID: TransferID, expectedBytes: UInt64) {
        validator = BulkFrameSequenceValidator(expectedTransferID: transferID)
        self.expectedBytes = expectedBytes
    }

    func append(_ data: Data) throws -> Result {
        let frames = try decoder.append(data)
        for frame in frames {
            try validator.accept(frame)
            if frame.kind == .chunk {
                let nextTotal = transferredBytes.addingReportingOverflow(
                    UInt64(frame.payload.count)
                )
                guard
                    !nextTotal.overflow,
                    nextTotal.partialValue <= expectedBytes
                else {
                    throw BulkConnectionError.sizeMismatch
                }
                transferredBytes = nextTotal.partialValue
            } else if frame.kind == .complete && transferredBytes != expectedBytes {
                throw BulkConnectionError.sizeMismatch
            }
        }
        return Result(frames: frames, isFinished: validator.isFinished)
    }
}
