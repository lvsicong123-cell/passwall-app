import Foundation
import PasswallCore
import Security

struct TrustedPeerCredential: Codable, Equatable, Sendable {
    let controllerID: String
    let secret: Data

    static func create() -> Self {
        var generator = SystemRandomNumberGenerator()
        return Self(
            controllerID: UUID().uuidString.lowercased(),
            secret: Data((0..<PairingCode.trustedSecretByteCount).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            })
        )
    }
}

enum TrustedPeerStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .keychain(errSecAuthFailed),
             .keychain(errSecInteractionNotAllowed):
            return "Lock and unlock the login keychain, then try again"
        case let .keychain(status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        case .invalidCredential:
            return "Trusted peer credential is invalid"
        }
    }
}

final class TrustedPeerStore {
    private let service: String

    init(service: String = "com.passwall.trusted-windows") {
        self.service = service
    }

    func credential(
        for fingerprint: CertificateFingerprint
    ) throws -> TrustedPeerCredential? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: fingerprint.hex,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TrustedPeerStoreError.keychain(status)
        }
        return try? JSONDecoder().decode(TrustedPeerCredential.self, from: data)
    }

    func save(
        _ credential: TrustedPeerCredential,
        for fingerprint: CertificateFingerprint
    ) throws {
        guard credential.secret.count == PairingCode.trustedSecretByteCount else {
            throw TrustedPeerStoreError.invalidCredential
        }
        let data = try JSONEncoder().encode(credential)
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: fingerprint.hex
        ] as CFDictionary
        let attributes = [kSecValueData: data] as CFDictionary
        let updateStatus = SecItemUpdate(query, attributes)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TrustedPeerStoreError.keychain(updateStatus)
        }

        let addStatus = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: fingerprint.hex,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TrustedPeerStoreError.keychain(addStatus)
        }
    }

    func remove(for fingerprint: CertificateFingerprint) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: fingerprint.hex
        ] as CFDictionary)
    }
}
