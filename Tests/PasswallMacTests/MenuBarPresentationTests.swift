import Testing
@testable import PasswallMac

@Suite("Menu bar presentation")
struct MenuBarPresentationTests {
    @Test("Input sharing state takes priority over connection state")
    func sharingStatePriority() {
        #expect(PasswallMenuBarPresentation(
            status: .failed("offline"),
            captureEnabled: true,
            remoteControlActive: false
        ).title == "Ready at Screen Edge")

        #expect(PasswallMenuBarPresentation(
            status: .disconnected,
            captureEnabled: false,
            remoteControlActive: true
        ).title == "Controlling Windows")
    }

    @Test("Connection failures have a concise menu status")
    func failedConnection() {
        let presentation = PasswallMenuBarPresentation(
            status: .failed("Receiver heartbeat timed out"),
            captureEnabled: false,
            remoteControlActive: false
        )

        #expect(presentation.title == "Connection Failed")
        #expect(presentation.systemImage == "exclamationmark.triangle.fill")
    }
}
