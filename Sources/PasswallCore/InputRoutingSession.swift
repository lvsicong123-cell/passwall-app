public enum InputRoutingMode: Sendable, Equatable {
    case local
    case remote
}

public enum InputRoutingDecision: Sendable, Equatable {
    case passThrough
    case holding(progress: Double)
    case activateRemote(entryFraction: Double)
    case forward(InputPayload)
}

public struct InputRoutingSession: Sendable {
    public private(set) var mode: InputRoutingMode = .local
    private var boundaryController: BoundaryCrossingController

    public init(boundaryConfiguration: BoundaryConfiguration) {
        boundaryController = BoundaryCrossingController(configuration: boundaryConfiguration)
    }

    public mutating func routePointer(
        pointer: PWPoint,
        delta: PWVector,
        elapsed: Double,
        screen: PWSize
    ) -> InputRoutingDecision {
        if mode == .remote {
            return .forward(.pointerMove(.init(dx: delta.dx, dy: delta.dy)))
        }

        switch boundaryController.update(
            pointer: pointer,
            delta: delta,
            elapsed: elapsed,
            screen: screen
        ) {
        case .local:
            return .passThrough
        case let .holding(progress):
            return .holding(progress: progress)
        case let .crossed(entryFraction):
            mode = .remote
            return .activateRemote(entryFraction: entryFraction)
        }
    }

    public func routeRemote(_ payload: InputPayload) -> InputRoutingDecision {
        guard mode == .remote else { return .passThrough }
        return .forward(payload)
    }

    @discardableResult
    public mutating func releaseRemote() -> Bool {
        guard mode == .remote else { return false }
        mode = .local
        boundaryController.reset()
        return true
    }
}
