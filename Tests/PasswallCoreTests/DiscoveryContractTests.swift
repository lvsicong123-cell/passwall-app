import Testing
@testable import PasswallCore

@Suite("Bonjour discovery contract")
struct DiscoveryContractTests {
    @Test("Valid receiver metadata is accepted")
    func acceptsReceiverMetadata() throws {
        let metadata = try #require(PasswallDiscoveryMetadata(txtRecord: [
            "pv": "3",
            "role": "receiver",
            "pairing": "required",
            "tls": "1.3",
            "fp": String(repeating: "a1", count: 32)
        ]))

        #expect(PasswallDiscoveryContract.serviceType == "_passwall._tcp")
        #expect(metadata.protocolVersion == 3)
        #expect(metadata.requiresPairing)
        #expect(metadata.certificateFingerprint.hex == String(repeating: "a1", count: 32))
    }

    @Test("Unknown versions and roles are rejected")
    func rejectsUnsupportedAdvertisements() {
        #expect(PasswallDiscoveryMetadata(txtRecord: [
            "pv": "2",
            "role": "receiver",
            "pairing": "required",
            "tls": "1.3",
            "fp": String(repeating: "a1", count: 32)
        ]) == nil)
        #expect(PasswallDiscoveryMetadata(txtRecord: [
            "pv": "3",
            "role": "controller",
            "pairing": "required",
            "tls": "1.3",
            "fp": String(repeating: "a1", count: 32)
        ]) == nil)
        #expect(PasswallDiscoveryMetadata(txtRecord: [
            "pv": "3",
            "role": "receiver",
            "pairing": "optional",
            "tls": "1.3",
            "fp": String(repeating: "a1", count: 32)
        ]) == nil)
        #expect(PasswallDiscoveryMetadata(txtRecord: [
            "pv": "3",
            "role": "receiver",
            "pairing": "required",
            "tls": "1.2",
            "fp": String(repeating: "a1", count: 32)
        ]) == nil)
        #expect(PasswallDiscoveryMetadata(txtRecord: [
            "pv": "3",
            "role": "receiver",
            "pairing": "required",
            "tls": "1.3",
            "fp": "not-a-sha256-fingerprint"
        ]) == nil)
    }
}
