public struct ScrollAccumulator: Sendable {
    public let unitsPerPoint: Double
    public private(set) var residual = 0.0

    public init(unitsPerPoint: Double) {
        self.unitsPerPoint = unitsPerPoint
    }

    public mutating func consume(points: Double) -> Int32 {
        let scaled = points * unitsPerPoint
        if scaled != 0, residual != 0, scaled.sign != residual.sign {
            residual = 0
        }

        residual += scaled
        let whole = residual.rounded(.towardZero)
        residual -= whole
        return Int32(clamping: Int(whole))
    }

    public mutating func reset() {
        residual = 0
    }
}
