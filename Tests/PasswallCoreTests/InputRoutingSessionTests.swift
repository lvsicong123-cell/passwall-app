import Testing
@testable import PasswallCore

@Suite("Input routing session")
struct InputRoutingSessionTests {
    private let screen = PWSize(width: 1512, height: 982)

    @Test("Crossing activates remote routing and consumes the edge event")
    func crossingActivatesRemote() {
        var session = InputRoutingSession(
            boundaryConfiguration: .init(edge: .right, activationDistance: 20)
        )

        let decision = session.routePointer(
            pointer: .init(x: 1512, y: 491),
            delta: .init(dx: 20, dy: 0),
            elapsed: 0.02,
            screen: screen
        )

        #expect(decision == .activateRemote(entryFraction: 0.5))
        #expect(session.mode == .remote)
    }

    @Test("Remote pointer, scroll, and button inputs are forwarded")
    func forwardsRemoteInput() {
        var session = InputRoutingSession(
            boundaryConfiguration: .init(edge: .right, activationDistance: 1)
        )
        _ = session.routePointer(
            pointer: .init(x: 1512, y: 491),
            delta: .init(dx: 2, dy: 0),
            elapsed: 0.02,
            screen: screen
        )

        #expect(session.routeRemote(.pointerMove(.init(dx: 4, dy: -2))) == .forward(.pointerMove(.init(dx: 4, dy: -2))))
        #expect(session.routeRemote(.scroll(.init(horizontal: 0.5, vertical: 3, phase: "changed"))) == .forward(.scroll(.init(horizontal: 0.5, vertical: 3, phase: "changed"))))
        #expect(session.routeRemote(.button(.init(button: .left, isDown: true))) == .forward(.button(.init(button: .left, isDown: true))))
    }

    @Test("Emergency release restores local pass-through")
    func emergencyRelease() {
        var session = InputRoutingSession(
            boundaryConfiguration: .init(edge: .right, activationDistance: 1)
        )
        _ = session.routePointer(
            pointer: .init(x: 1512, y: 491),
            delta: .init(dx: 2, dy: 0),
            elapsed: 0.02,
            screen: screen
        )

        let didRelease = session.releaseRemote()
        #expect(didRelease)
        #expect(session.mode == .local)
        #expect(session.routeRemote(.pointerMove(.init(dx: 4, dy: 0))) == .passThrough)
        let releasedAgain = session.releaseRemote()
        #expect(!releasedAgain)
    }
}
