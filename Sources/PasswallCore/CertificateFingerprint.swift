public struct CertificateFingerprint: Equatable, Sendable {
    public let hex: String

    public init?(hex: String) {
        let normalized = hex.lowercased()
        guard normalized.count == 64,
              normalized.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              })
        else {
            return nil
        }
        self.hex = normalized
    }
}
