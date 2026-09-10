import Testing
@testable import PasswallCore

@Suite("Certificate fingerprint")
struct CertificateFingerprintTests {
    @Test("A SHA-256 fingerprint is normalized and validated")
    func validatesSHA256Fingerprint() throws {
        let uppercase = String(repeating: "A1", count: 32)
        let fingerprint = try #require(CertificateFingerprint(hex: uppercase))

        #expect(fingerprint.hex == uppercase.lowercased())
        #expect(CertificateFingerprint(hex: String(repeating: "a", count: 63)) == nil)
        #expect(CertificateFingerprint(hex: String(repeating: "g", count: 64)) == nil)
    }
}
