import Testing
@testable import PasswallCore

@Suite("Boundary crossing")
struct BoundaryCrossingTests {
    private let screen = PWSize(width: 1512, height: 982)

    @Test("Slow intentional pressure crosses after the configured distance")
    func slowPressureCrosses() {
        var controller = BoundaryCrossingController(
            configuration: .init(
                edge: .right,
                activationDistance: 28,
                fastActivationDistance: 8,
                fastVelocity: 1_800,
                cornerGuard: 24
            )
        )

        let first = controller.update(
            pointer: .init(x: 1512, y: 491),
            delta: .init(dx: 12, dy: 0),
            elapsed: 0.02,
            screen: screen
        )
        #expect(first == .holding(progress: 12.0 / 28.0))

        let second = controller.update(
            pointer: .init(x: 1512, y: 491),
            delta: .init(dx: 16, dy: 0),
            elapsed: 0.02,
            screen: screen
        )
        #expect(second == .crossed(entryFraction: 0.5))
    }

    @Test("A fast edge push crosses with a shorter travel distance")
    func fastPushCrosses() {
        var controller = BoundaryCrossingController(configuration: .init(edge: .right))

        let decision = controller.update(
            pointer: .init(x: 1512, y: 245.5),
            delta: .init(dx: 9, dy: 0),
            elapsed: 0.004,
            screen: screen
        )

        #expect(decision == .crossed(entryFraction: 0.25))
    }

    @Test("Corners remain sticky to preserve local controls")
    func cornerGuardBlocksCrossing() {
        var controller = BoundaryCrossingController(configuration: .init(edge: .right))

        let decision = controller.update(
            pointer: .init(x: 1512, y: 10),
            delta: .init(dx: 40, dy: 0),
            elapsed: 0.01,
            screen: screen
        )

        #expect(decision == .local)
    }

    @Test("Moving inward cancels accumulated pressure")
    func inwardMotionResetsPressure() {
        var controller = BoundaryCrossingController(configuration: .init(edge: .right))
        _ = controller.update(
            pointer: .init(x: 1512, y: 491),
            delta: .init(dx: 20, dy: 0),
            elapsed: 0.02,
            screen: screen
        )

        let reset = controller.update(
            pointer: .init(x: 1511, y: 491),
            delta: .init(dx: -2, dy: 0),
            elapsed: 0.02,
            screen: screen
        )
        #expect(reset == .local)

        let next = controller.update(
            pointer: .init(x: 1512, y: 491),
            delta: .init(dx: 10, dy: 0),
            elapsed: 0.02,
            screen: screen
        )
        #expect(next == .holding(progress: 10.0 / 28.0))
    }
}
