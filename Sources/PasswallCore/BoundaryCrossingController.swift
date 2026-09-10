public struct BoundaryConfiguration: Sendable, Equatable {
    public var edge: ScreenEdge
    public var activationDistance: Double
    public var fastActivationDistance: Double
    public var fastVelocity: Double
    public var cornerGuard: Double
    public var edgeTolerance: Double

    public init(
        edge: ScreenEdge,
        activationDistance: Double = 28,
        fastActivationDistance: Double = 8,
        fastVelocity: Double = 1_800,
        cornerGuard: Double = 24,
        edgeTolerance: Double = 0.5
    ) {
        self.edge = edge
        self.activationDistance = activationDistance
        self.fastActivationDistance = fastActivationDistance
        self.fastVelocity = fastVelocity
        self.cornerGuard = cornerGuard
        self.edgeTolerance = edgeTolerance
    }
}

public enum BoundaryDecision: Sendable, Equatable {
    case local
    case holding(progress: Double)
    case crossed(entryFraction: Double)
}

public struct BoundaryCrossingController: Sendable {
    public let configuration: BoundaryConfiguration
    private var accumulatedOutwardDistance = 0.0

    public init(configuration: BoundaryConfiguration) {
        self.configuration = configuration
    }

    public mutating func update(
        pointer: PWPoint,
        delta: PWVector,
        elapsed: Double,
        screen: PWSize
    ) -> BoundaryDecision {
        guard screen.width > 0, screen.height > 0, elapsed > 0 else {
            reset()
            return .local
        }

        let outward = outwardComponent(of: delta)
        let fraction = entryFraction(for: pointer, screen: screen)
        let alongLength = alongEdgeLength(screen: screen)
        let alongPosition = fraction * alongLength

        guard isAtConfiguredEdge(pointer, screen: screen),
              alongPosition >= configuration.cornerGuard,
              alongPosition <= alongLength - configuration.cornerGuard,
              outward > 0 else {
            reset()
            return .local
        }

        accumulatedOutwardDistance += outward
        let velocity = outward / elapsed
        let requiredDistance = velocity >= configuration.fastVelocity
            ? configuration.fastActivationDistance
            : configuration.activationDistance

        if accumulatedOutwardDistance >= requiredDistance {
            reset()
            return .crossed(entryFraction: min(max(fraction, 0), 1))
        }

        return .holding(progress: min(accumulatedOutwardDistance / requiredDistance, 1))
    }

    public mutating func reset() {
        accumulatedOutwardDistance = 0
    }

    private func outwardComponent(of delta: PWVector) -> Double {
        switch configuration.edge {
        case .top: -delta.dy
        case .right: delta.dx
        case .bottom: delta.dy
        case .left: -delta.dx
        }
    }

    private func isAtConfiguredEdge(_ point: PWPoint, screen: PWSize) -> Bool {
        switch configuration.edge {
        case .top: point.y <= configuration.edgeTolerance
        case .right: point.x >= screen.width - configuration.edgeTolerance
        case .bottom: point.y >= screen.height - configuration.edgeTolerance
        case .left: point.x <= configuration.edgeTolerance
        }
    }

    private func entryFraction(for point: PWPoint, screen: PWSize) -> Double {
        switch configuration.edge {
        case .top, .bottom: point.x / screen.width
        case .right, .left: point.y / screen.height
        }
    }

    private func alongEdgeLength(screen: PWSize) -> Double {
        switch configuration.edge {
        case .top, .bottom: screen.width
        case .right, .left: screen.height
        }
    }
}
