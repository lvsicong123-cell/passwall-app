import CryptoKit
import Foundation

public enum PairingCode {
    public static let nonceByteCount = 16
    public static let trustedSecretByteCount = 32
    private static let context = Data("passwall-pairing-v1".utf8)

    public static func commitment(for serverNonce: Data) -> String? {
        guard serverNonce.count == nonceByteCount else { return nil }
        return SHA256.hash(data: serverNonce).hex
    }

    public static func verificationCode(
        certificateFingerprint: CertificateFingerprint,
        serverNonce: Data,
        clientNonce: Data
    ) -> String? {
        guard
            serverNonce.count == nonceByteCount,
            clientNonce.count == nonceByteCount,
            let fingerprint = Data(hex: certificateFingerprint.hex)
        else {
            return nil
        }

        let digest = SHA256.hash(
            data: context + fingerprint + serverNonce + clientNonce
        )
        let value = digest.prefix(4).reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        } % 1_000_000
        return String(format: "%06u", value)
    }

    public static func confirmationProof(
        code: String,
        certificateFingerprint: CertificateFingerprint,
        serverNonce: Data,
        clientNonce: Data,
        controllerID: String,
        secret: Data
    ) -> String? {
        guard
            code.count == 6,
            secret.count == trustedSecretByteCount,
            let transcript = transcript(
                certificateFingerprint: certificateFingerprint,
                serverNonce: serverNonce,
                clientNonce: clientNonce
            )
        else {
            return nil
        }
        let payload = Data("passwall-confirm-v1".utf8)
            + transcript
            + Data(controllerID.utf8)
            + secret
        return HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: Data(code.utf8))
        ).map { String(format: "%02x", $0) }.joined()
    }

    public static func resumeProof(
        certificateFingerprint: CertificateFingerprint,
        serverNonce: Data,
        clientNonce: Data,
        controllerID: String,
        secret: Data
    ) -> String? {
        guard
            secret.count == trustedSecretByteCount,
            let transcript = transcript(
                certificateFingerprint: certificateFingerprint,
                serverNonce: serverNonce,
                clientNonce: clientNonce
            )
        else {
            return nil
        }
        let payload = Data("passwall-resume-v1".utf8)
            + transcript
            + Data(controllerID.utf8)
        return HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: secret)
        ).map { String(format: "%02x", $0) }.joined()
    }

    private static func transcript(
        certificateFingerprint: CertificateFingerprint,
        serverNonce: Data,
        clientNonce: Data
    ) -> Data? {
        guard
            serverNonce.count == nonceByteCount,
            clientNonce.count == nonceByteCount,
            let fingerprint = Data(hex: certificateFingerprint.hex)
        else {
            return nil
        }
        return context + fingerprint + serverNonce + clientNonce
    }
}

private extension Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
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
}
