import Foundation
import Testing
@testable import PasswallCore

@Suite("Six-digit pairing code")
struct PairingCodeTests {
    @Test("Commitment and code match the cross-platform vector")
    func matchesVector() throws {
        let serverNonce = Data(0x00...0x0f)
        let clientNonce = Data(0x10...0x1f)
        let fingerprint = try #require(CertificateFingerprint(
            hex: String(repeating: "a1", count: 32)
        ))

        #expect(PairingCode.commitment(for: serverNonce) ==
            "be45cb2605bf36bebde684841a28f0fd43c69850a3dce5fedba69928ee3a8991")
        #expect(PairingCode.verificationCode(
            certificateFingerprint: fingerprint,
            serverNonce: serverNonce,
            clientNonce: clientNonce
        ) == "697655")
        #expect(PairingCode.commitment(for: Data()) == nil)

        let secret = Data(0x20...0x3f)
        #expect(PairingCode.confirmationProof(
            code: "697655",
            certificateFingerprint: fingerprint,
            serverNonce: serverNonce,
            clientNonce: clientNonce,
            controllerID: "controller-test",
            secret: secret
        ) == "3cab00bcfdcabb6fdd0e6ba1ff8c9858ddeeb6979ba5e9f3412fc55ce7b8b66c")
        #expect(PairingCode.resumeProof(
            certificateFingerprint: fingerprint,
            serverNonce: serverNonce,
            clientNonce: clientNonce,
            controllerID: "controller-test",
            secret: secret
        ) == "d384427038c29bac5785dda022472d859c0d9e871e3621576f10089598538a2f")
    }
}
