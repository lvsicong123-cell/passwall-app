@preconcurrency import ApplicationServices
@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Foundation
import PasswallCore

enum InputCaptureError: LocalizedError {
    case accessibilityPermissionRequired
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "Accessibility permission is required"
        case .eventTapUnavailable:
            "Input capture is unavailable"
        }
    }
}

@MainActor
final class InputCaptureService {
    static let eventTapLocation: CGEventTapLocation = .cghidEventTap
    private static let gestureEventTypes = [
        NSEvent.EventType.gesture,
        .magnify,
        .swipe,
        .beginGesture,
        .endGesture
    ].compactMap { CGEventType(rawValue: UInt32($0.rawValue)) }

    var onPayload: ((InputPayload) -> Void)?
    var onRemoteStateChanged: ((Bool) -> Void)?
    var navigationGesturesEnabled = true
    var pinchZoomEnabled = true
    var fourFingerSwipeConfiguration = FourFingerSwipeConfiguration.windowsDefault
    var pointerGain = 1.0
    var scrollGain = 1.0
    var inertiaEnabled = true
    var smartShortcutMapping = true

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var routingSession: InputRoutingSession?
    private var activeDisplayBounds: CGRect?
    private var reentryPoint: CGPoint?
    private var lastPointerTimestamp: UInt64?
    private var ignoredWarpEvents = 0
    private var configuredActivationDistance = 28.0
    private var gestureMapper = GestureMapper()
    private var fourFingerRecognizer = FourFingerSwipeRecognizer()
    private var keyboardMapper = KeyboardEventMapper()
    private var lastCapsLockFlag: Bool?
    private let cursorCapture: CursorCaptureController

    init(cursorCapture: CursorCaptureController = CursorCaptureController()) {
        self.cursorCapture = cursorCapture
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func isReturnToMacShortcut(
        keyCode: UInt16,
        isKeyDown: Bool,
        modifiers: Set<InputModifier>
    ) -> Bool {
        isKeyDown && keyCode == 53 && modifiers.contains(.option)
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    var isRunning: Bool { eventTap != nil }
    var isRemoteActive: Bool { routingSession?.mode == .remote }

    func start(edge: ScreenEdge, activationDistance: Double) throws {
        guard Self.isAccessibilityTrusted else {
            throw InputCaptureError.accessibilityPermissionRequired
        }
        stop()
        configuredEdge = edge
        configuredActivationDistance = activationDistance

        routingSession = InputRoutingSession(
            boundaryConfiguration: .init(
                edge: edge,
                activationDistance: activationDistance
            )
        )

        let eventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
            .keyDown, .keyUp, .flagsChanged
        ] + Self.gestureEventTypes
        let mask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }

        guard let tap = CGEvent.tapCreate(
            tap: Self.eventTapLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: passwallEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            routingSession = nil
            throw InputCaptureError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        releaseRemote()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        routingSession = nil
        lastPointerTimestamp = nil
        gestureMapper.reset()
        fourFingerRecognizer.reset()
        keyboardMapper.reset()
        lastCapsLockFlag = nil
    }

    @discardableResult
    func releaseRemote(entryFraction: Double? = nil) -> Bool {
        guard var session = routingSession, session.releaseRemote() else { return false }
        routingSession = session
        onPayload?(.releaseAll)

        let destination = entryFraction.flatMap { fraction in
            activeDisplayBounds.map {
                localReentryPoint(edge: configuredEdge, fraction: fraction, displayBounds: $0)
            }
        } ?? reentryPoint
        if destination != nil {
            ignoredWarpEvents = 2
        }
        cursorCapture.release(to: destination)

        activeDisplayBounds = nil
        reentryPoint = nil
        lastPointerTimestamp = nil
        gestureMapper.reset()
        fourFingerRecognizer.reset()
        keyboardMapper.reset()
        lastCapsLockFlag = nil
        onRemoteStateChanged?(false)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if Self.gestureEventTypes.contains(type) {
            return handleGestureEventTap(type: type, event: event)
        }

        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            return handleKeyboardEvent(type: type, event: event)
        }

        guard var session = routingSession else {
            return Unmanaged.passUnretained(event)
        }

        if isPointerMovement(type) {
            if ignoredWarpEvents > 0 {
                ignoredWarpEvents -= 1
                return Unmanaged.passUnretained(event)
            }

            let delta = PWVector(
                dx: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                dy: Double(event.getIntegerValueField(.mouseEventDeltaY))
            )

            if session.mode == .remote {
                routingSession = session
                onPayload?(.pointerMove(.init(
                    dx: delta.dx,
                    dy: delta.dy,
                    gain: pointerGain
                )))
                return nil
            }

            let timestamp = event.timestamp
            let elapsed: Double
            if let previous = lastPointerTimestamp, timestamp > previous {
                elapsed = Double(timestamp - previous) / 1_000_000_000
            } else {
                elapsed = 1.0 / 120.0
            }
            lastPointerTimestamp = timestamp

            let display = displayContaining(event.location)
            let bounds = CGDisplayBounds(display)
            let localPoint = PWPoint(
                x: event.location.x - bounds.minX,
                y: event.location.y - bounds.minY
            )
            let decision = session.routePointer(
                pointer: localPoint,
                delta: delta,
                elapsed: elapsed,
                screen: .init(width: bounds.width, height: bounds.height)
            )
            routingSession = session

            if case let .activateRemote(entryFraction) = decision {
                guard cursorCapture.capture(displayID: display) else {
                    _ = session.releaseRemote()
                    routingSession = session
                    return Unmanaged.passUnretained(event)
                }
                activeDisplayBounds = bounds
                reentryPoint = localReentryPoint(
                    edge: configuredEdge,
                    eventLocation: event.location,
                    displayBounds: bounds
                )
                keyboardMapper.reset()
                lastCapsLockFlag = nil
                onRemoteStateChanged?(true)
                onPayload?(.remoteEnter(.init(
                    remotePosition: configuredEdge,
                    entryFraction: entryFraction,
                    activationDistance: configuredActivationDistance
                )))
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard session.mode == .remote else {
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel {
            let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            guard Self.shouldForwardScroll(
                momentumPhase: momentumPhase,
                inertiaEnabled: inertiaEnabled
            ) else { return nil }
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let verticalField: CGEventField = isContinuous
                ? .scrollWheelEventPointDeltaAxis1
                : .scrollWheelEventDeltaAxis1
            let horizontalField: CGEventField = isContinuous
                ? .scrollWheelEventPointDeltaAxis2
                : .scrollWheelEventDeltaAxis2
            let horizontal = event.getDoubleValueField(horizontalField)
            let vertical = event.getDoubleValueField(verticalField)
            let phase = scrollPhaseName(event)
            let payload = InputPayload.scroll(.init(
                horizontal: horizontal,
                vertical: vertical,
                phase: phase,
                navigationEnabled: navigationGesturesEnabled,
                gain: scrollGain
            ))
            onPayload?(payload)
            return nil
        }

        if let button = buttonPayload(for: type, event: event) {
            onPayload?(.button(button))
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    static func shouldForwardScroll(momentumPhase: Int64, inertiaEnabled: Bool) -> Bool {
        inertiaEnabled || momentumPhase == 0
    }

    private func handleGesture(_ event: NSEvent) {
        guard isRemoteActive else { return }
        if event.type == .swipe {
            guard event.deltaX != 0 else { return }
            let action: FourFingerSwipeAction = event.deltaX > 0 ? .right : .left
            gestureMapper.fourFingerSwipe(
                action,
                configuration: fourFingerSwipeConfiguration
            ).forEach {
                onPayload?($0)
            }
            return
        }

        if pinchZoomEnabled {
            gestureMapper.zoom(magnificationDelta: event.magnification).forEach {
                onPayload?($0)
            }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            gestureMapper.endMagnification()
        }
    }

    private func handleKeyboardEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        guard isRemoteActive else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = keyboardModifiers(event.flags)

        if Self.isReturnToMacShortcut(
            keyCode: keyCode,
            isKeyDown: type == .keyDown,
            modifiers: modifiers
        ) {
            releaseRemote()
            return nil
        }
        if type == .flagsChanged {
            if keyCode == 57 {
                let isEnabled = event.flags.contains(.maskAlphaShift)
                if lastCapsLockFlag != isEnabled {
                    onPayload?(.key(.init(usbHIDUsage: 0x39, isDown: true)))
                    onPayload?(.key(.init(usbHIDUsage: 0x39, isDown: false)))
                    lastCapsLockFlag = isEnabled
                }
            }
            return nil
        }

        keyboardMapper.payloads(
            keyCode: keyCode,
            isDown: type == .keyDown,
            modifiers: modifiers,
            smartMapping: smartShortcutMapping
        ).forEach {
            onPayload?($0)
        }
        return nil
    }

    private func keyboardModifiers(_ flags: CGEventFlags) -> Set<InputModifier> {
        var modifiers: Set<InputModifier> = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func handleGestureEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        guard let appKitEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        guard isRemoteActive else {
            fourFingerRecognizer.reset()
            return Unmanaged.passUnretained(event)
        }

        if appKitEvent.type == .gesture {
            var consumed = fourFingerRecognizer.isTracking
            for touch in appKitEvent.allTouches() {
                let update = fourFingerRecognizer.update(
                    id: ObjectIdentifier(touch.identity as AnyObject).hashValue,
                    phase: touchUpdatePhase(touch.phase),
                    position: .init(
                        x: touch.normalizedPosition.x,
                        y: touch.normalizedPosition.y
                    )
                )
                consumed = consumed || update.consumed
                if let action = update.action {
                    gestureMapper.fourFingerSwipe(
                        action,
                        configuration: fourFingerSwipeConfiguration
                    ).forEach {
                        onPayload?($0)
                    }
                }
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        if appKitEvent.type == .endGesture, fourFingerRecognizer.isTracking {
            fourFingerRecognizer.reset()
            return nil
        }

        if appKitEvent.type == .magnify || appKitEvent.type == .swipe {
            handleGesture(appKitEvent)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func touchUpdatePhase(_ phase: NSTouch.Phase) -> TouchUpdatePhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .moved
    }

    private func isPointerMovement(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            true
        default:
            false
        }
    }

    private func displayContaining(_ point: CGPoint) -> CGDirectDisplayID {
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &display, &count)
        return display
    }

    private var configuredEdge: ScreenEdge = .right

    private func localReentryPoint(
        edge: ScreenEdge,
        eventLocation: CGPoint,
        displayBounds: CGRect
    ) -> CGPoint {
        switch edge {
        case .top:
            CGPoint(x: eventLocation.x, y: displayBounds.minY + 2)
        case .right:
            CGPoint(x: displayBounds.maxX - 2, y: eventLocation.y)
        case .bottom:
            CGPoint(x: eventLocation.x, y: displayBounds.maxY - 2)
        case .left:
            CGPoint(x: displayBounds.minX + 2, y: eventLocation.y)
        }
    }

    private func localReentryPoint(
        edge: ScreenEdge,
        fraction: Double,
        displayBounds: CGRect
    ) -> CGPoint {
        let localPoint = RemoteEntryMapper.entryPoint(
            enteringAt: edge,
            fraction: fraction,
            display: .init(
                pixelSize: .init(width: displayBounds.width, height: displayBounds.height),
                scaleFactor: 1,
                safeInsets: .zero
            ),
            insetPoints: 2
        )
        return CGPoint(
            x: displayBounds.minX + localPoint.x,
            y: displayBounds.minY + localPoint.y
        )
    }

    private func buttonPayload(for type: CGEventType, event: CGEvent) -> ButtonInput? {
        let isDown: Bool
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            isDown = true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            isDown = false
        default:
            return nil
        }

        let button: PointerButton
        switch type {
        case .leftMouseDown, .leftMouseUp:
            button = .left
        case .rightMouseDown, .rightMouseUp:
            button = .right
        default:
            switch event.getIntegerValueField(.mouseEventButtonNumber) {
            case 2: button = .middle
            case 3: button = .back
            case 4: button = .forward
            default: return nil
            }
        }
        return ButtonInput(button: button, isDown: isDown)
    }

    private func scrollPhaseName(_ event: CGEvent) -> String {
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if momentum != 0 {
            return "momentum_\(phaseName(momentum))"
        }
        return phaseName(event.getIntegerValueField(.scrollWheelEventScrollPhase))
    }

    private func phaseName(_ rawValue: Int64) -> String {
        switch rawValue {
        case 1: "began"
        case 2: "changed"
        case 4: "ended"
        case 8: "cancelled"
        case 128: "may_begin"
        default: "changed"
        }
    }
}

private let passwallEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<InputCaptureService>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        service.handle(type: type, event: event)
    }
}
