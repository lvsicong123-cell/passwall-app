public enum FourFingerSwipeAction: Sendable, Equatable {
    case left
    case right
    case up
    case down
}

public enum FourFingerSwipeMapping: String, Sendable, Equatable, CaseIterable {
    case none
    case previousDesktop
    case nextDesktop
    case taskView
    case showDesktop
    case back
    case forward
}

public struct FourFingerSwipeConfiguration: Sendable, Equatable {
    public var left: FourFingerSwipeMapping
    public var right: FourFingerSwipeMapping
    public var up: FourFingerSwipeMapping
    public var down: FourFingerSwipeMapping

    public static let windowsDefault = FourFingerSwipeConfiguration(
        left: .nextDesktop,
        right: .previousDesktop,
        up: .taskView,
        down: .showDesktop
    )

    public init(
        left: FourFingerSwipeMapping,
        right: FourFingerSwipeMapping,
        up: FourFingerSwipeMapping,
        down: FourFingerSwipeMapping
    ) {
        self.left = left
        self.right = right
        self.up = up
        self.down = down
    }

    public func mapping(for action: FourFingerSwipeAction) -> FourFingerSwipeMapping {
        switch action {
        case .left: left
        case .right: right
        case .up: up
        case .down: down
        }
    }
}

public enum TouchUpdatePhase: Sendable {
    case began
    case moved
    case ended
    case cancelled
}

public struct FourFingerSwipeUpdate: Sendable, Equatable {
    public var consumed: Bool
    public var action: FourFingerSwipeAction?

    public init(consumed: Bool, action: FourFingerSwipeAction? = nil) {
        self.consumed = consumed
        self.action = action
    }
}

public struct FourFingerSwipeRecognizer: Sendable {
    public private(set) var isTracking = false

    private var touches: [Int: PWPoint] = [:]
    private var origin = PWPoint(x: 0, y: 0)
    private var triggered = false

    public init() {}

    public mutating func update(
        id: Int,
        phase: TouchUpdatePhase,
        position: PWPoint
    ) -> FourFingerSwipeUpdate {
        switch phase {
        case .began, .moved:
            touches[id] = position
        case .ended, .cancelled:
            touches.removeValue(forKey: id)
        }

        if !isTracking, touches.count >= 4 {
            isTracking = true
            origin = centroid
            return .init(consumed: true)
        }
        guard isTracking else { return .init(consumed: false) }

        let shouldFinish = touches.isEmpty
        defer {
            if shouldFinish {
                reset()
            }
        }
        guard !triggered, touches.count >= 4 else {
            return .init(consumed: true)
        }

        let delta = PWVector(dx: centroid.x - origin.x, dy: centroid.y - origin.y)
        guard max(abs(delta.dx), abs(delta.dy)) >= 0.08 else {
            return .init(consumed: true)
        }
        triggered = true
        let action: FourFingerSwipeAction
        if abs(delta.dx) > abs(delta.dy) {
            action = delta.dx > 0 ? .right : .left
        } else {
            action = delta.dy > 0 ? .up : .down
        }
        return .init(consumed: true, action: action)
    }

    public mutating func reset() {
        touches.removeAll(keepingCapacity: true)
        isTracking = false
        triggered = false
    }

    private var centroid: PWPoint {
        guard !touches.isEmpty else { return .init(x: 0, y: 0) }
        let sum = touches.values.reduce(PWPoint(x: 0, y: 0)) {
            .init(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        return .init(
            x: sum.x / Double(touches.count),
            y: sum.y / Double(touches.count)
        )
    }
}

public struct GestureMapper: Sendable {
    private static let swipeThreshold = 0.5
    private static let controlUsage: UInt16 = 0xE0
    private static let leftGUIUsage: UInt16 = 0xE3
    private static let minusUsage: UInt16 = 0x2D
    private static let equalsUsage: UInt16 = 0x2E
    private static let rightArrowUsage: UInt16 = 0x4F
    private static let leftArrowUsage: UInt16 = 0x50

    private var magnification = ScrollAccumulator(unitsPerPoint: 12.5)

    public init() {}

    public func navigation(horizontalDelta: Double) -> [InputPayload] {
        guard abs(horizontalDelta) >= Self.swipeThreshold else { return [] }
        return navigationClick(horizontalDelta: horizontalDelta)
    }

    public func desktopSwitch(horizontalDelta: Double) -> [InputPayload] {
        guard abs(horizontalDelta) >= Self.swipeThreshold else { return [] }
        let arrowUsage = horizontalDelta > 0
            ? Self.leftArrowUsage
            : Self.rightArrowUsage
        return [
            .key(.init(usbHIDUsage: Self.controlUsage, isDown: true)),
            .key(.init(usbHIDUsage: Self.leftGUIUsage, isDown: true)),
            .key(.init(usbHIDUsage: arrowUsage, isDown: true)),
            .key(.init(usbHIDUsage: arrowUsage, isDown: false)),
            .key(.init(usbHIDUsage: Self.leftGUIUsage, isDown: false)),
            .key(.init(usbHIDUsage: Self.controlUsage, isDown: false))
        ]
    }

    public func fourFingerSwipe(
        _ action: FourFingerSwipeAction,
        configuration: FourFingerSwipeConfiguration
    ) -> [InputPayload] {
        switch configuration.mapping(for: action) {
        case .none:
            []
        case .previousDesktop:
            desktopSwitch(horizontalDelta: 1)
        case .nextDesktop:
            desktopSwitch(horizontalDelta: -1)
        case .taskView:
            keyChord([Self.leftGUIUsage, 0x2B])
        case .showDesktop:
            keyChord([Self.leftGUIUsage, 0x07])
        case .back:
            navigationClick(horizontalDelta: 1)
        case .forward:
            navigationClick(horizontalDelta: -1)
        }
    }

    public mutating func zoom(magnificationDelta: Double) -> [InputPayload] {
        let steps = magnification.consume(points: magnificationDelta)
        guard steps != 0 else { return [] }

        let keyUsage = steps > 0 ? Self.equalsUsage : Self.minusUsage
        var payloads = [InputPayload.key(.init(usbHIDUsage: Self.controlUsage, isDown: true))]
        for _ in 0..<abs(Int(steps)) {
            payloads.append(.key(.init(usbHIDUsage: keyUsage, isDown: true)))
            payloads.append(.key(.init(usbHIDUsage: keyUsage, isDown: false)))
        }
        payloads.append(.key(.init(usbHIDUsage: Self.controlUsage, isDown: false)))
        return payloads
    }

    public mutating func endMagnification() {
        magnification.reset()
    }

    public mutating func reset() {
        endMagnification()
    }

    private func navigationClick(horizontalDelta: Double) -> [InputPayload] {
        let button: PointerButton = horizontalDelta > 0 ? .back : .forward
        return [
            .button(.init(button: button, isDown: true)),
            .button(.init(button: button, isDown: false))
        ]
    }

    private func keyChord(_ usages: [UInt16]) -> [InputPayload] {
        usages.map { .key(.init(usbHIDUsage: $0, isDown: true)) }
            + usages.reversed().map { .key(.init(usbHIDUsage: $0, isDown: false)) }
    }

}
