public enum PasswallDiscoveryContract {
    public static let serviceType = "_passwall._tcp"
    public static let domain = "local."
    public static let protocolVersion = 3
}

public struct PasswallDiscoveryMetadata: Equatable, Sendable {
    public let protocolVersion: Int
    public let requiresPairing: Bool
    public let certificateFingerprint: CertificateFingerprint

    public init?(txtRecord: [String: String]) {
        guard
            let protocolVersion = Int(txtRecord["pv"] ?? ""),
            protocolVersion == PasswallDiscoveryContract.protocolVersion,
            txtRecord["role"] == "receiver",
            txtRecord["pairing"] == "required",
            txtRecord["tls"] == "1.3",
            let certificateFingerprint = CertificateFingerprint(
                hex: txtRecord["fp"] ?? ""
            )
        else {
            return nil
        }

        self.protocolVersion = protocolVersion
        requiresPairing = true
        self.certificateFingerprint = certificateFingerprint
    }
}
