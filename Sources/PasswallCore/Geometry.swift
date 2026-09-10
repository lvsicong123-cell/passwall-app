public struct PWPoint: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PWVector: Sendable, Equatable, Codable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

public struct PWSize: Sendable, Equatable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct PWInsets: Sendable, Equatable, Codable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public static let zero = PWInsets(top: 0, left: 0, bottom: 0, right: 0)

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public enum ScreenEdge: String, Sendable, Equatable, Codable {
    case top
    case right
    case bottom
    case left
}
