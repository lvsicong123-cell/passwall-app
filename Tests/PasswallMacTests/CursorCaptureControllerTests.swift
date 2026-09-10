import CoreGraphics
import Testing
@testable import PasswallMac

@MainActor
@Suite("Cursor capture lifecycle")
struct CursorCaptureControllerTests {
    @Test("Capture intercepts HID events before session cursor updates")
    func usesHIDEventTap() {
        #expect(InputCaptureService.eventTapLocation == .cghidEventTap)
    }

    @Test("Capture enables background control before disconnecting and hiding")
    func captureOrder() {
        var calls: [String] = []
        let controller = CursorCaptureController(system: .init(
            associate: { connected in
                calls.append("associate:\(connected)")
                return .success
            },
            hide: { displayID in
                calls.append("hide:\(displayID)")
                return .success
            },
            show: { _ in .success },
            warp: { _ in .success },
            enableBackgroundCursorControl: {
                calls.append("enable-background")
                return true
            }
        ))

        #expect(controller.capture(displayID: 7))
        #expect(calls == ["enable-background", "associate:false", "hide:7"])
    }

    @Test("A background-control failure prevents partial capture")
    func backgroundControlFailureStopsCapture() {
        var calls: [String] = []
        let controller = CursorCaptureController(system: .init(
            associate: { _ in
                calls.append("associate")
                return .success
            },
            hide: { _ in
                calls.append("hide")
                return .success
            },
            show: { _ in .success },
            warp: { _ in .success },
            enableBackgroundCursorControl: {
                calls.append("enable-background")
                return false
            }
        ))

        #expect(!controller.capture(displayID: 7))
        #expect(calls == ["enable-background"])
        #expect(!controller.isCaptured)
    }

    @Test("Release restores position before reconnecting and showing the cursor")
    func releaseOrder() {
        var calls: [String] = []
        let controller = CursorCaptureController(system: .init(
            associate: { connected in
                calls.append("associate:\(connected)")
                return .success
            },
            hide: { displayID in
                calls.append("hide:\(displayID)")
                return .success
            },
            show: { displayID in
                calls.append("show:\(displayID)")
                return .success
            },
            warp: { point in
                calls.append("warp:\(Int(point.x)),\(Int(point.y))")
                return .success
            }
        ))
        #expect(controller.capture(displayID: 9))

        controller.release(to: CGPoint(x: 120, y: 240))

        #expect(calls == [
            "associate:false",
            "hide:9",
            "warp:120,240",
            "associate:true",
            "show:9"
        ])
    }

    @Test("A hide failure reconnects pointer position and leaves capture inactive")
    func hideFailureRollsBackAssociation() {
        var calls: [String] = []
        let controller = CursorCaptureController(system: .init(
            associate: { connected in
                calls.append("associate:\(connected)")
                return .success
            },
            hide: { _ in
                calls.append("hide")
                return .failure
            },
            show: { _ in .success },
            warp: { _ in .success }
        ))

        #expect(!controller.capture(displayID: 3))
        #expect(calls == ["associate:false", "hide", "associate:true"])
        #expect(!controller.isCaptured)
    }
}
