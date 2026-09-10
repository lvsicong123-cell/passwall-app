import CoreFoundation
@preconcurrency import CoreGraphics

private typealias CGSConnectionID = Int32

@_silgen_name("_CGSDefaultConnection")
private func defaultWindowServerConnection() -> CGSConnectionID

@_silgen_name("CGSSetConnectionProperty")
private func setWindowServerConnectionProperty(
    _ connection: CGSConnectionID,
    _ target: CGSConnectionID,
    _ key: CFString,
    _ value: CFBoolean
) -> CGError

@MainActor
private func configureBackgroundCursorControl() -> Bool {
    let connection = defaultWindowServerConnection()
    let result = setWindowServerConnectionProperty(
        connection,
        connection,
        "SetsCursorInBackground" as CFString,
        kCFBooleanTrue
    )
    return result == .success
}

struct CursorCaptureSystem {
    var associate: @MainActor (Bool) -> CGError
    var hide: @MainActor (CGDirectDisplayID) -> CGError
    var show: @MainActor (CGDirectDisplayID) -> CGError
    var warp: @MainActor (CGPoint) -> CGError
    var enableBackgroundCursorControl: @MainActor () -> Bool = { true }

    static let live = CursorCaptureSystem(
        associate: { connected in
            CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0)
        },
        hide: CGDisplayHideCursor,
        show: CGDisplayShowCursor,
        warp: CGWarpMouseCursorPosition,
        enableBackgroundCursorControl: configureBackgroundCursorControl
    )
}

@MainActor
final class CursorCaptureController {
    private let system: CursorCaptureSystem
    private var capturedDisplayID: CGDirectDisplayID?

    init(system: CursorCaptureSystem = .live) {
        self.system = system
    }

    var isCaptured: Bool { capturedDisplayID != nil }

    func capture(displayID: CGDirectDisplayID) -> Bool {
        guard capturedDisplayID == nil else { return true }
        guard system.enableBackgroundCursorControl() else { return false }
        guard system.associate(false) == .success else { return false }
        guard system.hide(displayID) == .success else {
            _ = system.associate(true)
            return false
        }

        capturedDisplayID = displayID
        return true
    }

    func release(to destination: CGPoint?) {
        guard let displayID = capturedDisplayID else { return }
        if let destination {
            _ = system.warp(destination)
        }
        _ = system.associate(true)
        _ = system.show(displayID)
        capturedDisplayID = nil
    }
}
