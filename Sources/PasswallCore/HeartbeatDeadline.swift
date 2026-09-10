public struct HeartbeatDeadline: Sendable, Equatable {
    public static let sendIntervalNanoseconds: UInt64 = 500_000_000
    public static let inactivityTimeoutNanoseconds: UInt64 = 2_000_000_000

    public private(set) var lastActivityNanoseconds: UInt64

    public init(startedAtNanoseconds: UInt64) {
        lastActivityNanoseconds = startedAtNanoseconds
    }

    public mutating func noteActivity(atNanoseconds timestamp: UInt64) {
        lastActivityNanoseconds = timestamp
    }

    public func hasExpired(atNanoseconds timestamp: UInt64) -> Bool {
        guard timestamp >= lastActivityNanoseconds else { return false }
        return timestamp - lastActivityNanoseconds >= Self.inactivityTimeoutNanoseconds
    }
}
