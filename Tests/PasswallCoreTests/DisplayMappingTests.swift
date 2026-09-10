import Testing
@testable import PasswallCore

@Suite("Display mapping")
struct DisplayMappingTests {
    @Test("Entry fraction maps into the remote usable pixel area")
    func mapsToScaledRemotePixels() {
        let remote = DisplayMetrics(
            pixelSize: .init(width: 3840, height: 2160),
            scaleFactor: 1.5,
            safeInsets: .init(top: 40, left: 0, bottom: 80, right: 0)
        )

        let point = RemoteEntryMapper.entryPoint(
            enteringAt: .left,
            fraction: 0.5,
            display: remote,
            insetPoints: 2
        )

        #expect(point.x == 3)
        #expect(point.y == 1050)
    }

    @Test("Fractions are clamped before mapping")
    func clampsFraction() {
        let remote = DisplayMetrics(
            pixelSize: .init(width: 1920, height: 1080),
            scaleFactor: 1,
            safeInsets: .zero
        )

        let point = RemoteEntryMapper.entryPoint(
            enteringAt: .top,
            fraction: 2,
            display: remote,
            insetPoints: 1
        )

        #expect(point == .init(x: 1919, y: 1))
    }
}
