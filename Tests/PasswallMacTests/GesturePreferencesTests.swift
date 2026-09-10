import Foundation
import Testing
@testable import PasswallCore
@testable import PasswallMac

@MainActor
@Suite("Gesture preferences")
struct GesturePreferencesTests {
    @Test("Four-finger mappings survive store recreation")
    func persistsFourFingerMappings() throws {
        let suite = "com.passwall.tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let store = AppStore(preferences: preferences)
        #expect(!store.shareClipboard)
        store.fourFingerSwipeLeft = .back
        store.fourFingerSwipeDown = .none
        store.pointerGain = 1.25
        store.scrollGain = 0.75
        store.enableInertia = false
        store.smartShortcutMapping = false
        store.language = .english
        store.appearance = .dark
        store.selectedNearbyDeviceID = "moss|_passwall._tcp|local."
        store.shareClipboard = true

        let restored = AppStore(preferences: preferences)
        #expect(restored.fourFingerSwipeLeft == .back)
        #expect(restored.fourFingerSwipeDown == .none)
        #expect(restored.fourFingerSwipeRight == .previousDesktop)
        #expect(restored.fourFingerSwipeUp == .taskView)
        #expect(restored.pointerGain == 1.25)
        #expect(restored.scrollGain == 0.75)
        #expect(!restored.enableInertia)
        #expect(!restored.smartShortcutMapping)
        #expect(restored.language == .english)
        #expect(restored.appearance == .dark)
        #expect(restored.selectedNearbyDeviceID == "moss|_passwall._tcp|local.")
        #expect(restored.shareClipboard)
    }

    @Test("Disabled inertia drops only momentum scroll events")
    func filtersMomentumScrollEvents() {
        #expect(InputCaptureService.shouldForwardScroll(momentumPhase: 0, inertiaEnabled: false))
        #expect(!InputCaptureService.shouldForwardScroll(momentumPhase: 1, inertiaEnabled: false))
        #expect(InputCaptureService.shouldForwardScroll(momentumPhase: 1, inertiaEnabled: true))
    }
}
