import CryptoKit
import Foundation
import Network
import PasswallCore
import Security

enum TLSIdentityVerificationState: Equatable {
    case idle
    case verifying(String)
    case awaitingCode(String, attemptsRemaining: Int)
    case confirming(String)
    case paired(String)
    case failed(String, String)
}

enum PairingCodeSubmission: Equatable {
    case invalidFormat
    case incorrect(attemptsRemaining: Int)
    case confirming
    case unavailable
}

struct PairingCodeEntryValidator {
    private let expectedCode: String
    private(set) var attemptsRemaining = 3

    init(expectedCode: String) {
        self.expectedCode = expectedCode
    }

    mutating func submit(_ code: String) -> PairingCodeSubmission {
        guard attemptsRemaining > 0 else { return .unavailable }
        guard
            code.count == 6,
            code.allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            return .invalidFormat
        }
        guard code != expectedCode else { return .confirming }
        attemptsRemaining -= 1
        return .incorrect(attemptsRemaining: attemptsRemaining)
    }
}

enum CertificatePinning {
    static func matches(
        _ certificateDER: Data,
        expected: CertificateFingerprint
    ) -> Bool {
        SHA256.hash(data: certificateDER)
            .map { String(format: "%02x", $0) }
            .joined() == expected.hex
    }

    static func parameters(for expected: CertificateFingerprint) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard
                let certificates = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                let leaf = certificates.first
            else {
                complete(false)
                return
            }
            let certificateDER = SecCertificateCopyData(leaf) as Data
            complete(matches(certificateDER, expected: expected))
        }, DispatchQueue.global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        return parameters
    }
}

@MainActor
final class TLSIdentityVerifier {
    var onStateChanged: ((TLSIdentityVerificationState) -> Void)?
    var onAuthenticatedConnection: ((String, NWConnection) -> Void)?

    private var connection: NWConnection?
    private var timeoutTask: Task<Void, Never>?
    private var lineBuffer = Data()
    private var deviceID: String?
    private var commitment: String?
    private var codeValidator: PairingCodeEntryValidator?
    private var device: DiscoveredWindowsDevice?
    private var clientNonce: Data?
    private var serverNonce: Data?
    private var sessionBinding = TrustedSessionBinding.input
    private let trustedPeerStore: TrustedPeerStore
    private let queue = DispatchQueue(
        label: "com.passwall.tls-identity",
        qos: .userInitiated
    )

    init(trustedPeerStore: TrustedPeerStore = TrustedPeerStore()) {
        self.trustedPeerStore = trustedPeerStore
    }

    func isTrusted(_ device: DiscoveredWindowsDevice) -> Bool {
        (try? trustedPeerStore.credential(
            for: device.metadata.certificateFingerprint
        )) != nil
    }

    func verify(
        _ device: DiscoveredWindowsDevice,
        binding: TrustedSessionBinding = .input
    ) {
        reset()
        deviceID = device.id
        self.device = device
        sessionBinding = binding
        onStateChanged?(.verifying(device.id))

        let endpoint = NWEndpoint.service(
            name: device.name,
            type: device.type,
            domain: device.domain,
            interface: nil
        )
        let connection = NWConnection(
            to: endpoint,
            using: CertificatePinning.parameters(
                for: device.metadata.certificateFingerprint
            )
        )
        self.connection = connection
        armTimeout(
            for: .seconds(5),
            message: "TLS identity verification timed out",
            connection: connection
        )
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.timeoutTask?.cancel()
                    self.receiveCommit(
                        from: connection,
                        device: device
                    )
                case let .waiting(error), let .failed(error):
                    self.fail(error.localizedDescription, on: connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    func submit(code: String) -> PairingCodeSubmission {
        guard
            let connection,
            let deviceID,
            let commitment,
            var codeValidator
        else {
            return .unavailable
        }

        let result = codeValidator.submit(code)
        self.codeValidator = codeValidator
        switch result {
        case .confirming:
            guard
                let device,
                let clientNonce,
                let serverNonce
            else {
                return .unavailable
            }
            let credential = TrustedPeerCredential.create()
            guard let proof = PairingCode.confirmationProof(
                code: code,
                certificateFingerprint:
                    device.metadata.certificateFingerprint,
                serverNonce: serverNonce,
                clientNonce: clientNonce,
                controllerID: credential.controllerID,
                secret: credential.secret
            ) else {
                return .unavailable
            }
            do {
                try trustedPeerStore.save(
                    credential,
                    for: device.metadata.certificateFingerprint
                )
            } catch {
                fail(error.localizedDescription, on: connection)
                return .unavailable
            }
            onStateChanged?(.confirming(deviceID))
            sendLine(
                "CONFIRM \(commitment) \(credential.controllerID) " +
                "\(credential.secret.hex) \(proof)",
                on: connection
            ) { [weak self] in
                self?.receivePaired(from: connection)
            }
        case let .incorrect(attemptsRemaining) where attemptsRemaining == 0:
            fail("Pairing retry limit reached", on: connection)
        case let .incorrect(attemptsRemaining):
            onStateChanged?(.awaitingCode(
                deviceID,
                attemptsRemaining: attemptsRemaining
            ))
        case .invalidFormat, .unavailable:
            break
        }
        return result
    }

    func cancel() {
        let connection = connection
        reset(cancelConnection: false)
        onStateChanged?(.idle)
        guard let connection else { return }
        connection.send(
            content: Data("CANCEL\n".utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func receiveCommit(
        from connection: NWConnection,
        device: DiscoveredWindowsDevice
    ) {
        receiveLine(from: connection) { [weak self] line in
            guard let self else { return }
            let prefix = "PASSWALL_PAIRING_V1 COMMIT "
            guard
                line.hasPrefix(prefix),
                let commitmentData = Data(hex: String(line.dropFirst(prefix.count))),
                commitmentData.count == 32
            else {
                self.fail("Invalid pairing commitment", on: connection)
                return
            }
            self.commitment = String(line.dropFirst(prefix.count)).lowercased()

            let clientNonce = Self.randomNonce()
            self.clientNonce = clientNonce
            let trustedCredential: TrustedPeerCredential?
            do {
                trustedCredential = try self.trustedPeerStore.credential(
                    for: device.metadata.certificateFingerprint
                )
            } catch {
                self.fail(error.localizedDescription, on: connection)
                return
            }
            let mode = trustedCredential.map {
                "RESUME \($0.controllerID)"
            } ?? "PAIR"
            guard trustedCredential != nil || self.sessionBinding == .input else {
                self.fail("Bulk session requires a trusted peer", on: connection)
                return
            }
            self.sendLine(
                "NONCE \(clientNonce.hex) \(mode)",
                on: connection
            ) { [weak self] in
                self?.receiveReveal(
                    from: connection,
                    device: device,
                    clientNonce: clientNonce,
                    trustedCredential: trustedCredential
                )
            }
        }
    }

    private func receiveReveal(
        from connection: NWConnection,
        device: DiscoveredWindowsDevice,
        clientNonce: Data,
        trustedCredential: TrustedPeerCredential?
    ) {
        receiveLine(from: connection) { [weak self] line in
            guard let self, let commitment = self.commitment else { return }
            let prefix = "REVEAL "
            guard
                line.hasPrefix(prefix),
                let serverNonce = Data(hex: String(line.dropFirst(prefix.count))),
                PairingCode.commitment(for: serverNonce) == commitment,
                let code = PairingCode.verificationCode(
                    certificateFingerprint:
                        device.metadata.certificateFingerprint,
                    serverNonce: serverNonce,
                    clientNonce: clientNonce
                )
            else {
                self.fail(
                    "Pairing nonce did not match its commitment",
                    on: connection
                )
                return
            }

            self.serverNonce = serverNonce
            if let trustedCredential {
                guard let proof = PairingCode.resumeProof(
                    certificateFingerprint:
                        device.metadata.certificateFingerprint,
                    serverNonce: serverNonce,
                    clientNonce: clientNonce,
                    controllerID: trustedCredential.controllerID,
                    secret: trustedCredential.secret
                ) else {
                    self.fail("Trusted peer credential is invalid", on: connection)
                    return
                }
                self.sendLine(
                    "RESUME \(trustedCredential.controllerID) \(proof)",
                    on: connection
                ) { [weak self] in
                    self?.receivePaired(from: connection)
                }
                return
            }

            self.codeValidator = PairingCodeEntryValidator(expectedCode: code)
            self.onStateChanged?(.awaitingCode(
                device.id,
                attemptsRemaining: 3
            ))
            self.armTimeout(
                for: .seconds(120),
                message: "Pairing code timed out",
                connection: connection
            )
        }
    }

    private func receivePaired(from connection: NWConnection) {
        receiveLine(from: connection) { [weak self] line in
            guard let self, let deviceID = self.deviceID else { return }
            guard line == "PAIRED" else {
                if let device {
                    trustedPeerStore.remove(
                        for: device.metadata.certificateFingerprint
                    )
                }
                self.fail(
                    "Receiver rejected pairing confirmation",
                    on: connection
                )
                return
            }
            self.timeoutTask?.cancel()
            let binding = self.sessionBinding
            self.armTimeout(
                for: .seconds(5),
                message: "Session role negotiation timed out",
                connection: connection
            )
            self.sendLine(binding.wireLine, on: connection) { [weak self] in
                self?.receiveSessionAcknowledgement(
                    from: connection,
                    deviceID: deviceID
                )
            }
        }
    }

    private func receiveSessionAcknowledgement(
        from connection: NWConnection,
        deviceID: String
    ) {
        receiveLine(from: connection) { [weak self] line in
            guard let self else { return }
            guard line == "SESSION_OK" else {
                self.fail("Receiver rejected the session role", on: connection)
                return
            }
            self.reset(cancelConnection: false)
            self.onStateChanged?(.paired(deviceID))
            self.onAuthenticatedConnection?(deviceID, connection)
        }
    }

    private func receiveLine(
        from connection: NWConnection,
        then handle: @escaping @MainActor @Sendable (String) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 512
        ) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let error {
                    self.fail(error.localizedDescription, on: connection)
                    return
                }
                if let data {
                    self.lineBuffer.append(data)
                }
                guard self.lineBuffer.count <= 512 else {
                    self.fail("Pairing protocol line is too long", on: connection)
                    return
                }
                if let newline = self.lineBuffer.firstIndex(of: 0x0a) {
                    let lineData = self.lineBuffer[..<newline]
                    self.lineBuffer.removeSubrange(...newline)
                    guard
                        !lineData.contains(0x0d),
                        let line = String(data: lineData, encoding: .ascii)
                    else {
                        self.fail("Invalid pairing protocol line", on: connection)
                        return
                    }
                    handle(line)
                } else if isComplete {
                    self.fail(
                        "Pairing connection ended unexpectedly",
                        on: connection
                    )
                } else {
                    self.receiveLine(from: connection, then: handle)
                }
            }
        }
    }

    private func sendLine(
        _ line: String,
        on connection: NWConnection,
        then handle: @escaping @MainActor @Sendable () -> Void
    ) {
        connection.send(
            content: Data("\(line)\n".utf8),
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    if let error {
                        self.fail(error.localizedDescription, on: connection)
                    } else {
                        handle()
                    }
                }
            }
        )
    }

    private func armTimeout(
        for duration: Duration,
        message: String,
        connection: NWConnection
    ) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            guard self.connection === connection else { return }
            self.fail(message, on: connection)
        }
    }

    private func fail(_ message: String, on connection: NWConnection) {
        guard self.connection === connection else { return }
        let failedDeviceID = deviceID ?? ""
        reset()
        onStateChanged?(.failed(failedDeviceID, message))
        connection.cancel()
    }

    private func reset(cancelConnection: Bool = true) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if cancelConnection {
            connection?.cancel()
        }
        connection = nil
        lineBuffer.removeAll(keepingCapacity: true)
        deviceID = nil
        commitment = nil
        codeValidator = nil
        device = nil
        clientNonce = nil
        serverNonce = nil
        sessionBinding = .input
    }

    private static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<PairingCode.nonceByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
