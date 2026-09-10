public struct DisplayMetrics: Sendable, Equatable, Codable {
    public var pixelSize: PWSize
    public var scaleFactor: Double
    public var safeInsets: PWInsets

    public init(pixelSize: PWSize, scaleFactor: Double, safeInsets: PWInsets) {
        self.pixelSize = pixelSize
        self.scaleFactor = scaleFactor
        self.safeInsets = safeInsets
    }
}

public enum RemoteEntryMapper {
    public static func entryPoint(
        enteringAt edge: ScreenEdge,
        fraction: Double,
        display: DisplayMetrics,
        insetPoints: Double
    ) -> PWPoint {
        let scale = max(display.scaleFactor, 0)
        let fraction = min(max(fraction, 0), 1)
        let top = display.safeInsets.top * scale
        let left = display.safeInsets.left * scale
        let bottom = display.safeInsets.bottom * scale
        let right = display.safeInsets.right * scale
        let inset = max(insetPoints, 0) * scale
        let maxX = max(display.pixelSize.width - right, left)
        let maxY = max(display.pixelSize.height - bottom, top)
        let x = left + ((maxX - left) * fraction)
        let y = top + ((maxY - top) * fraction)

        switch edge {
        case .top:
            return PWPoint(x: min(max(x, left), maxX - inset), y: top + inset)
        case .right:
            return PWPoint(x: max(maxX - inset, left), y: y)
        case .bottom:
            return PWPoint(x: x, y: max(maxY - inset, top))
        case .left:
            return PWPoint(x: left + inset, y: y)
        }
    }
}
