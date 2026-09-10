import Testing
@testable import PasswallCore

@Suite("Trackpad gesture mapping")
struct GestureMapperTests {
    @Test("Horizontal swipes map to one Back or Forward click")
    func navigationSwipes() {
        let mapper = GestureMapper()

        #expect(mapper.navigation(horizontalDelta: 0.49).isEmpty)
        #expect(mapper.navigation(horizontalDelta: 1) == [
            .button(.init(button: .back, isDown: true)),
            .button(.init(button: .back, isDown: false))
        ])
        #expect(mapper.navigation(horizontalDelta: -1) == [
            .button(.init(button: .forward, isDown: true)),
            .button(.init(button: .forward, isDown: false))
        ])
    }

    @Test("Configured system swipes map to Windows virtual desktops")
    func desktopSwitch() {
        let mapper = GestureMapper()

        #expect(mapper.desktopSwitch(horizontalDelta: 1) == [
            .key(.init(usbHIDUsage: 0xE0, isDown: true)),
            .key(.init(usbHIDUsage: 0xE3, isDown: true)),
            .key(.init(usbHIDUsage: 0x50, isDown: true)),
            .key(.init(usbHIDUsage: 0x50, isDown: false)),
            .key(.init(usbHIDUsage: 0xE3, isDown: false)),
            .key(.init(usbHIDUsage: 0xE0, isDown: false))
        ])
    }

    @Test("Four-finger movement is claimed only after four touches and triggers once")
    func rawFourFingerSwipe() {
        var recognizer = FourFingerSwipeRecognizer()
        for id in 0..<3 {
            #expect(!recognizer.update(
                id: id,
                phase: .began,
                position: .init(x: Double(id) * 0.1, y: 0.5)
            ).consumed)
        }
        #expect(recognizer.update(
            id: 3,
            phase: .began,
            position: .init(x: 0.3, y: 0.5)
        ).consumed)

        var action: FourFingerSwipeAction?
        for id in 0..<4 {
            action = recognizer.update(
                id: id,
                phase: .moved,
                position: .init(x: Double(id) * 0.1 + 0.1, y: 0.5)
            ).action ?? action
        }
        #expect(action == .right)
        #expect(recognizer.update(
            id: 0,
            phase: .moved,
            position: .init(x: 0.2, y: 0.5)
        ).action == nil)
    }

    @Test("Four-finger directions use configurable Windows actions")
    func configurableFourFingerActions() {
        let mapper = GestureMapper()

        #expect(mapper.fourFingerSwipe(
            .left,
            configuration: .windowsDefault
        ) == mapper.desktopSwitch(horizontalDelta: -1))

        let custom = FourFingerSwipeConfiguration(
            left: .back,
            right: .none,
            up: .showDesktop,
            down: .taskView
        )
        #expect(mapper.fourFingerSwipe(.left, configuration: custom) == [
            .button(.init(button: .back, isDown: true)),
            .button(.init(button: .back, isDown: false))
        ])
        #expect(mapper.fourFingerSwipe(.right, configuration: custom).isEmpty)
    }

    @Test("Pinch deltas accumulate into safe Control zoom chords")
    func pinchZoom() {
        var mapper = GestureMapper()

        #expect(mapper.zoom(magnificationDelta: 0.04).isEmpty)
        #expect(mapper.zoom(magnificationDelta: 0.04) == [
            .key(.init(usbHIDUsage: 0xE0, isDown: true)),
            .key(.init(usbHIDUsage: 0x2E, isDown: true)),
            .key(.init(usbHIDUsage: 0x2E, isDown: false)),
            .key(.init(usbHIDUsage: 0xE0, isDown: false))
        ])

        mapper.endMagnification()
        #expect(mapper.zoom(magnificationDelta: -0.08) == [
            .key(.init(usbHIDUsage: 0xE0, isDown: true)),
            .key(.init(usbHIDUsage: 0x2D, isDown: true)),
            .key(.init(usbHIDUsage: 0x2D, isDown: false)),
            .key(.init(usbHIDUsage: 0xE0, isDown: false))
        ])
    }
}
