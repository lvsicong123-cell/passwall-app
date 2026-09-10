import Foundation
import Network
import Testing
@testable import PasswallCore
@testable import PasswallMac

@Suite("TLS certificate pinning")
struct CertificatePinningTests {
    @Test("Only the expected DER certificate fingerprint is accepted")
    func matchesExpectedCertificate() throws {
        let certificateDER = Data("passwall-test-certificate".utf8)
        let expected = try #require(
            CertificateFingerprint(
                hex: "ce7d24403ace5a108d571c929718c830876ce6c607ee8818a5dd2a21e5d05a3c"
            )
        )
        let wrong = try #require(
            CertificateFingerprint(hex: String(repeating: "00", count: 32))
        )

        #expect(CertificatePinning.matches(certificateDER, expected: expected))
        #expect(!CertificatePinning.matches(certificateDER, expected: wrong))
        let parameters = CertificatePinning.parameters(for: expected)
        #expect(parameters.preferNoProxies)
        let tcp = parameters.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options
        #expect(tcp?.noDelay == true)
    }

    @Test("Pairing code entry is bounded to three attempts")
    func limitsCodeAttempts() {
        var validator = PairingCodeEntryValidator(expectedCode: "123456")

        #expect(validator.submit("12345") == .invalidFormat)
        #expect(validator.submit("000000") == .incorrect(attemptsRemaining: 2))
        #expect(validator.submit("111111") == .incorrect(attemptsRemaining: 1))
        #expect(validator.submit("222222") == .incorrect(attemptsRemaining: 0))
        #expect(validator.submit("123456") == .unavailable)
    }

    @Test("Trusted peer credentials round trip through Keychain")
    func keychainRoundTrip() throws {
        let store = TrustedPeerStore(
            service: "com.passwall.tests.\(UUID().uuidString)"
        )
        let fingerprint = try #require(CertificateFingerprint(
            hex: String(repeating: "a1", count: 32)
        ))
        let credential = TrustedPeerCredential.create()
        defer { store.remove(for: fingerprint) }

        try store.save(credential, for: fingerprint)
        #expect(try store.credential(for: fingerprint) == credential)
    }

    @Test("Locked Keychain errors tell the user how to recover")
    func lockedKeychainRecoveryMessage() {
        let error = TrustedPeerStoreError.keychain(errSecAuthFailed)
        #expect(
            error.errorDescription ==
                "Lock and unlock the login keychain, then try again"
        )
    }
}
