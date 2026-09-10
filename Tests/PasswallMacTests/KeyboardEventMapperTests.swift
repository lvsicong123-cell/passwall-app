import Testing
@testable import PasswallCore
@testable import PasswallMac

@Suite("Remote keyboard event mapping")
struct KeyboardEventMapperTests {
    @Test("Command-C becomes a balanced Control-C chord")
    func commandCopy() {
        var mapper = KeyboardEventMapper()

        #expect(mapper.payloads(
            keyCode: 8,
            isDown: true,
            modifiers: [.command],
            smartMapping: true
        ) == [
            .key(.init(usbHIDUsage: 0xE0, isDown: true)),
            .key(.init(usbHIDUsage: 0x06, isDown: true))
        ])
        #expect(mapper.payloads(
            keyCode: 8,
            isDown: false,
            modifiers: [],
            smartMapping: true
        ) == [
            .key(.init(usbHIDUsage: 0x06, isDown: false)),
            .key(.init(usbHIDUsage: 0xE0, isDown: false))
        ])
    }

    @Test("Smart mapping can be disabled without losing physical keys")
    func directCommandTab() {
        var mapper = KeyboardEventMapper()

        #expect(mapper.payloads(
            keyCode: 48,
            isDown: true,
            modifiers: [.command],
            smartMapping: false
        ) == [
            .key(.init(usbHIDUsage: 0xE3, isDown: true)),
            .key(.init(usbHIDUsage: 0x2B, isDown: true))
        ])
    }

    @Test("Command-Right uses the Windows End key")
    func commandRight() {
        var mapper = KeyboardEventMapper()

        #expect(mapper.payloads(
            keyCode: 124,
            isDown: true,
            modifiers: [.command, .shift],
            smartMapping: true
        ) == [
            .key(.init(usbHIDUsage: 0xE1, isDown: true)),
            .key(.init(usbHIDUsage: 0x4D, isDown: true))
        ])
    }

    @Test("Escape is forwarded unless Option is held for Return to Mac")
    @MainActor
    func escapeAndReturnShortcut() {
        var mapper = KeyboardEventMapper()

        #expect(mapper.payloads(
            keyCode: 53,
            isDown: true,
            modifiers: [],
            smartMapping: true
        ) == [.key(.init(usbHIDUsage: 0x29, isDown: true))])
        #expect(InputCaptureService.isReturnToMacShortcut(
            keyCode: 53,
            isKeyDown: true,
            modifiers: [.option]
        ))
        #expect(!InputCaptureService.isReturnToMacShortcut(
            keyCode: 53,
            isKeyDown: true,
            modifiers: []
        ))
    }
}
