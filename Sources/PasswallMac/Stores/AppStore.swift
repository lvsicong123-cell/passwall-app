import AppKit
import Foundation
import Network
import Observation
import PasswallCore
import ServiceManagement
import UserNotifications

private struct PendingImageUpload {
    let image: ClipboardImageMetadata
    let data: Data
    var started = false
    var sending = false
    var finished = false
}

private struct PendingImageDownload {
    let offer: TransferOffer
    let state: ClipboardState
    var data: Data
}

private struct PendingFileUpload {
    let transferID: TransferID
    let batch: FileTransferBatch
    var started = false
    var sending = false
}

private struct PendingFileDownload {
    let offer: TransferOffer
    let staging: FileTransferStaging
}

private struct QueuedFileSelection {
    let transferID: TransferID
    let urls: [URL]
    let name: String
    let startedAt: Date
}

private enum FileTransferError: LocalizedError {
    case selectedDeviceUnavailable
    case bulkBusy

    var errorDescription: String? {
        switch self {
        case .selectedDeviceUnavailable: "Selected Windows device is unavailable"
        case .bulkBusy: "Another content transfer is active"
        }
    }
}

private enum ImageTransferError: LocalizedError {
    case selectedDeviceUnavailable
    case imageMetadataMismatch
    case acknowledgementTimeout

    var errorDescription: String? {
        switch self {
        case .selectedDeviceUnavailable:
            "Selected Windows device is unavailable"
        case .imageMetadataMismatch:
            "Clipboard image metadata did not match its bulk transfer"
        case .acknowledgementTimeout:
            "Windows did not confirm the clipboard image"
        }
    }
}

@MainActor
@Observable
final class AppStore {
    var selection: AppSection? = .devices
    var language: AppLanguage {
        didSet { preferences.set(language.rawValue, forKey: "interface.language") }
    }
    var appearance: AppAppearance {
        didSet { preferences.set(appearance.rawValue, forKey: "interface.appearance") }
    }
    var launchAtLoginEnabled: Bool
    var launchAtLoginError: String?
    var status: ConnectionStatus = .disconnected
    var remotePosition: ScreenEdge = .right
    var activationDistance = 28.0
    var pointerGain: Double {
        didSet { saveCalibration(pointerGain, key: .pointerGain) }
    }
    var scrollGain: Double {
        didSet { saveCalibration(scrollGain, key: .scrollGain) }
    }
    var enableInertia: Bool {
        didSet {
            preferences.set(enableInertia, forKey: "scroll.inertia")
            inputCapture?.inertiaEnabled = enableInertia
        }
    }
    var enableNavigationGestures = true {
        didSet { inputCapture?.navigationGesturesEnabled = enableNavigationGestures }
    }
    var fourFingerSwipeLeft: FourFingerSwipeMapping {
        didSet { saveFourFingerMapping(fourFingerSwipeLeft, key: .left) }
    }
    var fourFingerSwipeRight: FourFingerSwipeMapping {
        didSet { saveFourFingerMapping(fourFingerSwipeRight, key: .right) }
    }
    var fourFingerSwipeUp: FourFingerSwipeMapping {
        didSet { saveFourFingerMapping(fourFingerSwipeUp, key: .up) }
    }
    var fourFingerSwipeDown: FourFingerSwipeMapping {
        didSet { saveFourFingerMapping(fourFingerSwipeDown, key: .down) }
    }
    var enablePinchZoom = true {
        didSet { inputCapture?.pinchZoomEnabled = enablePinchZoom }
    }
    var smartShortcutMapping: Bool {
        didSet {
            preferences.set(smartShortcutMapping, forKey: "keyboard.smart-mapping")
            inputCapture?.smartShortcutMapping = smartShortcutMapping
        }
    }
    var shareClipboard: Bool {
        didSet { updateClipboardSharing() }
    }
    var clipboardError: String?
    var fileTransferProgress: UInt64 = 0
    var fileTransferTotalBytes: UInt64 = 0
    var fileTransferError: String?
    var incomingFileOffer: TransferOffer?
    var lastReceivedFileDirectory: URL?
    var activeFileTransferID: TransferID?
    var fileTransferDestination: URL {
        didSet { preferences.set(fileTransferDestination.path, forKey: "transfer.destination") }
    }
    var fileTransferHistory: FileTransferHistoryStore {
        didSet {
            if let data = try? JSONEncoder().encode(fileTransferHistory) {
                preferences.set(data, forKey: "transfer.history")
            }
        }
    }
    var lastRoundTripMilliseconds: Double?
    var eventCount: UInt64 = 0
    var accessibilityTrusted = InputCaptureService.isAccessibilityTrusted
    var captureEnabled = false
    var remoteControlActive = false
    var captureError: String?
    var nearbyWindowsPCs: [DiscoveredWindowsDevice] = []
    var selectedNearbyDeviceID: String? {
        didSet {
            if let selectedNearbyDeviceID {
                preferences.set(selectedNearbyDeviceID, forKey: "device.selected-id")
            } else {
                preferences.removeObject(forKey: "device.selected-id")
            }
        }
    }
    var discoveryState: BonjourDiscoveryState = .stopped
    var tlsIdentityState: TLSIdentityVerificationState = .idle
    var pairingCode = ""
    var pairingCodeError: String?

    private var connection: NWConnection?
    private var sequence: UInt64 = 0
    private var sessionID = UUID().uuidString
    private var inboundMessageValidator: WireMessageSequenceValidator?
    private var heartbeatDeadline: HeartbeatDeadline?
    @ObservationIgnored private var inputCapture: InputCaptureService!
    @ObservationIgnored private var discoveryService: BonjourDiscoveryService!
    @ObservationIgnored private var identityVerifier: TLSIdentityVerifier!
    @ObservationIgnored private var clipboardMonitor: ClipboardMonitor!
    @ObservationIgnored private var bulkConnection: BulkConnection!
    @ObservationIgnored private var inboundDecoder = LengthPrefixedStreamDecoder()
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var imageTransferTask: Task<Void, Never>?
    @ObservationIgnored private var fileTransferTask: Task<Void, Never>?
    @ObservationIgnored private var pendingImageUpload: PendingImageUpload?
    @ObservationIgnored private var pendingImageUploadState: ClipboardState?
    @ObservationIgnored private var pendingImageDownload: PendingImageDownload?
    @ObservationIgnored private var pendingDownloadOffer: TransferOffer?
    @ObservationIgnored private var pendingDownloadState: ClipboardState?
    @ObservationIgnored private var pendingFileUpload: PendingFileUpload?
    @ObservationIgnored private var pendingFileDownload: PendingFileDownload?
    @ObservationIgnored private var queuedFileSelections: [QueuedFileSelection] = []
    @ObservationIgnored private var retryFileSources: [TransferID: [URL]] = [:]
    @ObservationIgnored private var fileTransferLocations: [TransferID: URL] = [:]
    @ObservationIgnored private let preferences: UserDefaults

    var canSend: Bool { status == .connected }
    var hasActiveFileTransfer: Bool {
        activeFileTransferID != nil || incomingFileOffer != nil || !queuedFileSelections.isEmpty
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        fileTransferDestination = preferences.string(forKey: "transfer.destination")
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? Self.defaultFileTransferDestination
        fileTransferHistory = Self.restoredFileTransferHistory(from: preferences)
        selectedNearbyDeviceID = preferences.string(forKey: "device.selected-id")
        language = preferences.string(forKey: "interface.language")
            .flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
        appearance = preferences.string(forKey: "interface.appearance")
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        pointerGain = Self.loadCalibration(from: preferences, key: .pointerGain)
        scrollGain = Self.loadCalibration(from: preferences, key: .scrollGain)
        enableInertia = preferences.object(forKey: "scroll.inertia") as? Bool ?? true
        smartShortcutMapping =
            preferences.object(forKey: "keyboard.smart-mapping") as? Bool ?? true
        shareClipboard = preferences.object(forKey: "clipboard.share") as? Bool ?? false
        fourFingerSwipeLeft = Self.loadFourFingerMapping(
            from: preferences,
            key: .left,
            fallback: .nextDesktop
        )
        fourFingerSwipeRight = Self.loadFourFingerMapping(
            from: preferences,
            key: .right,
            fallback: .previousDesktop
        )
        fourFingerSwipeUp = Self.loadFourFingerMapping(
            from: preferences,
            key: .up,
            fallback: .taskView
        )
        fourFingerSwipeDown = Self.loadFourFingerMapping(
            from: preferences,
            key: .down,
            fallback: .showDesktop
        )

        if let data = try? JSONEncoder().encode(fileTransferHistory) {
            preferences.set(data, forKey: "transfer.history")
        }

        if FileManager.default.fileExists(atPath: fileTransferDestination.path) {
            try? FileTransferStaging.removeAbandonedPartials(in: fileTransferDestination)
        }

        let capture = InputCaptureService()
        capture.onPayload = { [weak self] payload in
            guard let self else { return }
            if case .remoteEnter = payload, shareClipboard, canSend {
                clipboardMonitor.poll()
            }
            send(payload)
        }
        capture.onRemoteStateChanged = { [weak self] active in
            self?.remoteControlActive = active
        }
        inputCapture = capture
        updateCalibration()
        inputCapture.inertiaEnabled = enableInertia
        updateFourFingerConfiguration()
        inputCapture.smartShortcutMapping = smartShortcutMapping

        let clipboard = ClipboardMonitor()
        clipboard.onLocalChange = { [weak self] content in
            guard let self, shareClipboard, canSend else { return }
            cancelImageTransfer()
            clipboardError = nil
            send(.clipboardSet(.init(content: content)))
        }
        clipboard.onLocalImage = { [weak self] content, data in
            guard let self, shareClipboard, canSend else { return }
            startImageUpload(content: content, data: data)
        }
        clipboard.onError = { [weak self] error in
            self?.clipboardError = self?.text(error.localizedDescription)
        }
        clipboardMonitor = clipboard

        let bulk = BulkConnection()
        bulk.onStateChanged = { [weak self] state in
            self?.handleBulkState(state)
        }
        bulk.onFrame = { [weak self] frame in
            try await MainActor.run {
                guard let self else { return }
                try self.handleBulkFrame(frame)
            }
        }
        bulkConnection = bulk

        let discovery = BonjourDiscoveryService()
        discovery.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            let previousSelection = nearbyWindowsPCs.first {
                $0.id == selectedNearbyDeviceID
            }
            nearbyWindowsPCs = devices
            guard let selectedNearbyDeviceID else { return }
            guard let updatedSelection = devices.first(where: {
                $0.id == selectedNearbyDeviceID
            }) else {
                disconnect()
                return
            }

            let metadataChanged = previousSelection?.metadata != nil &&
                updatedSelection.metadata != previousSelection?.metadata
            guard metadataChanged || (connection == nil && status == .disconnected),
                  identityVerifier.isTrusted(updatedSelection) else { return }

            if metadataChanged { disconnect() }
            pairingCode = ""
            pairingCodeError = nil
            status = .connecting
            identityVerifier.verify(updatedSelection)
        }
        discovery.onStateChanged = { [weak self] state in
            self?.discoveryState = state
        }
        discoveryService = discovery

        let verifier = TLSIdentityVerifier()
        verifier.onStateChanged = { [weak self] state in
            guard let self else { return }
            tlsIdentityState = state
            switch state {
            case .verifying, .awaitingCode, .confirming:
                status = .connecting
            case let .failed(_, message):
                status = .failed(message)
            case .idle where connection == nil:
                status = .disconnected
            case .idle, .paired:
                break
            }
        }
        verifier.onAuthenticatedConnection = { [weak self] deviceID, connection in
            self?.adoptAuthenticatedConnection(
                connection,
                for: deviceID
            )
        }
        identityVerifier = verifier
    }

    func text(_ key: String) -> String {
        language.localized(key)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private static func loadFourFingerMapping(
        from preferences: UserDefaults,
        key: FourFingerPreferenceKey,
        fallback: FourFingerSwipeMapping
    ) -> FourFingerSwipeMapping {
        preferences.string(forKey: key.rawValue)
            .flatMap(FourFingerSwipeMapping.init(rawValue:)) ?? fallback
    }

    private static func loadCalibration(
        from preferences: UserDefaults,
        key: CalibrationPreferenceKey
    ) -> Double {
        guard let value = preferences.object(forKey: key.rawValue) as? Double,
              value.isFinite else {
            return 1
        }
        return min(max(value, 0.5), 2)
    }

    private func saveCalibration(_ value: Double, key: CalibrationPreferenceKey) {
        preferences.set(value, forKey: key.rawValue)
        updateCalibration()
    }

    private func updateCalibration() {
        inputCapture?.pointerGain = pointerGain
        inputCapture?.scrollGain = scrollGain
    }

    private func saveFourFingerMapping(
        _ mapping: FourFingerSwipeMapping,
        key: FourFingerPreferenceKey
    ) {
        preferences.set(mapping.rawValue, forKey: key.rawValue)
        updateFourFingerConfiguration()
    }

    private func updateFourFingerConfiguration() {
        inputCapture?.fourFingerSwipeConfiguration = .init(
            left: fourFingerSwipeLeft,
            right: fourFingerSwipeRight,
            up: fourFingerSwipeUp,
            down: fourFingerSwipeDown
        )
    }

    private func updateClipboardSharing() {
        preferences.set(shareClipboard, forKey: "clipboard.share")
        guard shareClipboard, canSend else {
            if canSend {
                send(.clipboardControl(.init(enabled: false)))
            }
            clipboardMonitor?.stop()
            cancelImageTransfer()
            clipboardError = nil
            return
        }

        clipboardMonitor.start()
        send(.clipboardControl(.init(enabled: true)))
    }

    func startDiscovery() {
        discoveryService.start()
    }

    func refreshDiscovery() {
        discoveryService.restart()
    }

    func selectNearbyDevice(_ device: DiscoveredWindowsDevice) {
        disconnect()
        selectedNearbyDeviceID = device.id
        pairingCode = ""
        pairingCodeError = nil
        status = .connecting
        identityVerifier.verify(device)
    }

    func isTrusted(_ device: DiscoveredWindowsDevice) -> Bool {
        identityVerifier.isTrusted(device)
    }

    func submitPairingCode() {
        switch identityVerifier.submit(code: pairingCode) {
        case .confirming:
            pairingCodeError = nil
        case .invalidFormat:
            pairingCodeError = text("Enter the six-digit code shown on Windows")
        case let .incorrect(attemptsRemaining):
            pairingCode = ""
            pairingCodeError = attemptsRemaining > 0
                ? "\(text("Codes do not match")) · \(attemptsRemaining) \(text("attempts remaining"))"
                : text("Pairing retry limit reached")
        case .unavailable:
            pairingCodeError = text("Pairing is not ready")
        }
    }

    func cancelPairing() {
        pairingCode = ""
        pairingCodeError = nil
        identityVerifier.cancel()
        status = .disconnected
    }

    func disconnect() {
        stopCapture()
        clipboardMonitor?.stop()
        cancelImageTransfer()
        cancelFileTransfer()
        if canSend {
            send(.releaseAll)
        }
        identityVerifier?.cancel()
        connection?.cancel()
        connection = nil
        stopHeartbeat()
        inboundDecoder.reset()
        inboundMessageValidator = nil
        status = .disconnected
    }

    private func adoptAuthenticatedConnection(
        _ connection: NWConnection,
        for deviceID: String
    ) {
        guard selectedNearbyDeviceID == deviceID else {
            connection.cancel()
            return
        }

        sessionID = UUID().uuidString
        sequence = 0
        inboundMessageValidator = WireMessageSequenceValidator(
            expectedSessionID: sessionID
        )
        inboundDecoder.reset()
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case let .waiting(error), let .failed(error):
                    self.failConnection(error)
                case .cancelled:
                    self.stopCapture()
                    self.clipboardMonitor.stop()
                    self.cancelImageTransfer()
                    self.cancelFileTransfer(notifyPeer: false, status: .failed)
                    self.stopHeartbeat()
                    self.identityVerifier.cancel()
                    self.connection = nil
                    self.inboundMessageValidator = nil
                    self.status = .disconnected
                default:
                    break
                }
            }
        }
        status = .connected
        startHeartbeat(on: connection)
        receiveNext(on: connection)
        updateClipboardSharing()
        send(.heartbeat)
    }

    func nudge(dx: Double, dy: Double) {
        send(.pointerMove(.init(dx: dx, dy: dy, gain: pointerGain)))
    }

    func scroll(horizontal: Double = 0, vertical: Double = 0) {
        send(.scroll(.init(
            horizontal: horizontal,
            vertical: vertical,
            phase: "changed",
            gain: scrollGain
        )))
    }

    func click(_ button: PointerButton) {
        send(.button(.init(button: button, isDown: true)))
        send(.button(.init(button: button, isDown: false)))
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = InputCaptureService.isAccessibilityTrusted
    }

    func requestAccessibilityPermission() {
        _ = InputCaptureService.requestAccessibilityPermission()
        refreshAccessibilityStatus()
    }

    func startCapture() {
        captureError = nil
        refreshAccessibilityStatus()
        guard canSend else {
            captureError = text("Connect to Windows first")
            return
        }
        do {
            try inputCapture.start(
                edge: remotePosition,
                activationDistance: activationDistance
            )
            captureEnabled = true
        } catch {
            captureEnabled = false
            captureError = text(error.localizedDescription)
            refreshAccessibilityStatus()
        }
    }

    func stopCapture() {
        inputCapture?.stop()
        captureEnabled = false
        remoteControlActive = false
    }

    func returnControlToMac() {
        _ = inputCapture?.releaseRemote()
    }

    func measureRoundTrip() {
        let start = ContinuousClock.now
        send(.heartbeat) { [weak self] in
            Task { @MainActor in
                self?.lastRoundTripMilliseconds = Double(start.duration(to: .now).components.attoseconds) / 1e15
            }
        }
    }

    private func send(_ payload: InputPayload, completion: (@Sendable () -> Void)? = nil) {
        guard let connection, canSend else { return }
        sequence &+= 1
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let message = WireMessage(
            sessionID: sessionID,
            sequence: sequence,
            sentAtMicros: now,
            payload: payload
        )

        do {
            let data = try JSONEncoder().encode(message)
            let frame = LengthPrefixedFramer.frame(data)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    if let error {
                        self.failConnection(error)
                    } else {
                        self.eventCount &+= 1
                        completion?()
                    }
                }
            })
        } catch {
            failConnection(error)
        }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }

                if let data, !data.isEmpty {
                    do {
                        for frame in try self.inboundDecoder.append(data) {
                            try self.handleInboundFrame(frame)
                        }
                    } catch {
                        self.failConnection(error)
                        return
                    }
                }

                if let error {
                    self.failConnection(error)
                    return
                }
                if isComplete {
                    self.stopCapture()
                    self.clipboardMonitor.stop()
                    self.cancelImageTransfer()
                    self.cancelFileTransfer(notifyPeer: false, status: .failed)
                    self.stopHeartbeat()
                    self.identityVerifier.cancel()
                    self.connection = nil
                    self.inboundMessageValidator = nil
                    connection.cancel()
                    self.status = .disconnected
                    return
                }

                self.receiveNext(on: connection)
            }
        }
    }

    private func handleInboundFrame(_ frame: Data) throws {
        let message = try JSONDecoder().decode(WireMessage.self, from: frame)
        guard var validator = inboundMessageValidator else {
            throw InboundProtocolError.missingSession
        }
        try validator.accept(message)
        inboundMessageValidator = validator
        heartbeatDeadline?.noteActivity(atNanoseconds: DispatchTime.now().uptimeNanoseconds)

        switch message.payload {
        case let .remoteExit(exit):
            _ = inputCapture.releaseRemote(entryFraction: exit.entryFraction)
        case let .clipboardState(state):
            if shareClipboard {
                try handleClipboardState(state)
            }
        case let .transferOffer(offer):
            try handleTransferOffer(offer)
        case let .transferAccept(reference):
            try handleTransferAccept(reference)
        case let .transferReject(failure):
            handleTransferFailure(failure, status: .rejected)
        case let .transferError(failure):
            handleTransferFailure(failure, status: .failed)
        case let .transferCancel(reference):
            handleTransferCancellation(reference)
        case let .transferProgress(progress):
            if activeFileTransferID == progress.transferID {
                fileTransferProgress = min(progress.transferredBytes, fileTransferTotalBytes)
            }
        case let .transferComplete(reference):
            if pendingFileUpload?.transferID == reference.transferID {
                fileTransferTask?.cancel()
                fileTransferTask = nil
                pendingFileUpload = nil
                completeFileTransfer(reference.transferID, status: .completed)
                resumePendingImageDownload()
                startNextQueuedFilesIfPossible()
            }
        case .heartbeat:
            break
        case .clipboardControl, .clipboardSet:
            throw InboundProtocolError.unexpectedPayload
        default:
            throw InboundProtocolError.unexpectedPayload
        }
    }

    private func startImageUpload(content: ClipboardContent, data: Data) {
        guard let image = content.image else { return }
        guard fileTransferTask == nil,
              pendingFileUpload == nil, pendingFileDownload == nil else { return }
        cancelImageTransfer()
        clipboardError = nil
        pendingImageUpload = PendingImageUpload(
            image: image,
            data: data
        )
        do {
            send(.transferOffer(try TransferOffer(
                transferID: image.transferID,
                kind: .image,
                direction: .upload,
                totalBytes: image.byteCount
            )))
            send(.clipboardSet(.init(content: content)))
        } catch {
            cancelImageTransfer()
            clipboardError = text(error.localizedDescription)
        }
    }

    private func handleTransferAccept(_ reference: TransferReference) throws {
        if var upload = pendingFileUpload, upload.transferID == reference.transferID {
            guard !upload.started else { return }
            guard let device = selectedDevice else {
                throw ImageTransferError.selectedDeviceUnavailable
            }
            upload.started = true
            pendingFileUpload = upload
            activeFileTransferID = upload.transferID
            fileTransferTotalBytes = upload.batch.manifest.totalBytes
            fileTransferHistory.update(upload.transferID, status: .transferring)
            bulkConnection.connect(
                to: device,
                transferID: upload.transferID,
                direction: .upload,
                totalBytes: upload.batch.manifest.totalBytes
            )
            return
        }
        guard var upload = pendingImageUpload,
              upload.image.transferID == reference.transferID else {
            return
        }
        guard !upload.started else { return }
        guard let device = selectedDevice else {
            throw ImageTransferError.selectedDeviceUnavailable
        }
        upload.started = true
        pendingImageUpload = upload
        bulkConnection.connect(
            to: device,
            transferID: upload.image.transferID,
            direction: .upload,
            totalBytes: upload.image.byteCount
        )
    }

    private func handleTransferOffer(_ offer: TransferOffer) throws {
        if offer.kind == .files, offer.direction == .download {
            if pendingFileUpload != nil || pendingFileDownload != nil || fileTransferTask != nil {
                send(.transferReject(.init(transferID: offer.transferID, code: "bulk_busy")))
                fileTransferHistory.record(.init(
                    transferID: offer.transferID,
                    name: Self.transferName(for: offer.manifest),
                    direction: .download,
                    totalBytes: offer.totalBytes,
                    deviceName: selectedDevice?.name ?? text("Windows PC"),
                    startedAt: Date(),
                    status: .rejected
                ))
                return
            }
            if let previous = incomingFileOffer,
               previous.transferID != offer.transferID {
                send(.transferReject(.init(
                    transferID: previous.transferID,
                    code: "superseded"
                )))
                fileTransferHistory.update(previous.transferID, status: .rejected)
            }
            incomingFileOffer = offer
            fileTransferHistory.record(.init(
                transferID: offer.transferID,
                name: Self.transferName(for: offer.manifest),
                direction: .download,
                totalBytes: offer.totalBytes,
                deviceName: selectedDevice?.name ?? text("Windows PC"),
                startedAt: Date(),
                status: .awaitingApproval
            ))
            notifyIncomingFiles(offer)
            return
        }
        guard offer.kind == .image, offer.direction == .download else {
            throw InboundProtocolError.unexpectedPayload
        }
        guard shareClipboard else {
            send(.transferReject(.init(transferID: offer.transferID, code: "disabled")))
            return
        }
        if let previous = pendingDownloadOffer,
           previous.transferID != offer.transferID {
            send(.transferCancel(.init(transferID: previous.transferID)))
        }
        pendingDownloadOffer = offer
        if pendingDownloadState?.content.image?.transferID != offer.transferID {
            pendingDownloadState = nil
        }
        try tryStartImageDownload()
    }

    private func handleClipboardState(_ state: ClipboardState) throws {
        guard let image = state.content.image else {
            if pendingImageUpload != nil || pendingImageDownload != nil ||
                pendingDownloadOffer != nil {
                cancelImageTransfer()
            }
            clipboardMonitor.apply(state)
            return
        }
        if let upload = pendingImageUpload, upload.image.transferID == image.transferID {
            guard upload.finished else {
                pendingImageUploadState = state
                return
            }
            finishImageUpload(with: state)
            return
        }
        if pendingImageDownload?.offer.transferID == image.transferID {
            return
        }
        guard pendingDownloadOffer?.transferID == image.transferID else {
            clipboardMonitor.acknowledge(state)
            return
        }
        pendingDownloadState = state
        try tryStartImageDownload()
    }

    private func tryStartImageDownload() throws {
        guard fileTransferTask == nil,
              pendingFileUpload == nil, pendingFileDownload == nil,
              pendingImageUpload == nil,
              pendingImageDownload == nil else { return }
        guard let offer = pendingDownloadOffer,
              let state = pendingDownloadState,
              let image = state.content.image else { return }
        guard offer.transferID == image.transferID,
              offer.totalBytes == image.byteCount,
              offer.kind == .image,
              offer.direction == .download else {
            throw ImageTransferError.imageMetadataMismatch
        }
        guard let device = selectedDevice else {
            throw ImageTransferError.selectedDeviceUnavailable
        }
        var data = Data()
        data.reserveCapacity(Int(offer.totalBytes))
        pendingImageDownload = PendingImageDownload(
            offer: offer,
            state: state,
            data: data
        )
        pendingDownloadOffer = nil
        pendingDownloadState = nil
        send(.transferAccept(.init(transferID: offer.transferID)))
        bulkConnection.connect(
            to: device,
            transferID: offer.transferID,
            direction: .download,
            totalBytes: offer.totalBytes
        )
    }

    private func handleBulkState(_ state: BulkConnectionState) {
        switch state {
        case .ready:
            if var file = pendingFileUpload, file.started, !file.sending {
                file.sending = true
                pendingFileUpload = file
                fileTransferTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await bulkConnection.send(file.batch) { [weak self] bytes in
                            self?.fileTransferProgress = bytes
                        }
                        if activeFileTransferID == file.transferID {
                            fileTransferHistory.update(file.transferID, status: .verifying)
                        }
                    } catch is CancellationError {
                    } catch {
                        fileTransferError = fileTransferMessage(error)
                        send(.transferError(.init(
                            transferID: file.transferID,
                            code: "file_transfer_failed"
                        )))
                        cancelFileTransfer(
                            notifyPeer: false,
                            status: .failed,
                            cancelQueue: false
                        )
                    }
                }
                return
            }
            guard var upload = pendingImageUpload, upload.started, !upload.sending else {
                return
            }
            upload.sending = true
            pendingImageUpload = upload
            imageTransferTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    var offset = 0
                    while offset < upload.data.count {
                        try Task.checkCancellation()
                        let end = min(offset + BulkFrame.maximumChunkSize, upload.data.count)
                        try await bulkConnection.sendChunk(upload.data[offset..<end])
                        offset = end
                    }
                    try await bulkConnection.complete()
                    if pendingImageUpload?.image.transferID == upload.image.transferID {
                        pendingImageUpload?.finished = true
                        if let state = pendingImageUploadState,
                           state.content.image?.transferID == upload.image.transferID {
                            finishImageUpload(with: state)
                        } else {
                            startImageAcknowledgementDeadline(for: upload.image.transferID)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    handleImageTransferError(error, transferID: upload.image.transferID)
                }
            }
        case let .failed(message):
            if let transferID = pendingFileUpload?.transferID {
                fileTransferError = message
                send(.transferError(.init(
                    transferID: transferID,
                    code: "file_transfer_failed"
                )))
                cancelFileTransfer(notifyPeer: false, status: .failed, cancelQueue: false)
                return
            }
            if pendingFileDownload != nil {
                fileTransferError = message
                cancelFileTransfer(notifyPeer: false, status: .failed, cancelQueue: false)
                return
            }
            let transferID = pendingImageUpload?.image.transferID
                ?? pendingImageDownload?.offer.transferID
            if let transferID {
                handleImageTransferError(
                    BulkConnectionError.transport(message),
                    transferID: transferID
                )
            }
        case .idle, .connecting:
            break
        }
    }

    private func handleBulkFrame(_ frame: BulkFrame) throws {
        if let download = pendingFileDownload,
           download.offer.transferID == frame.transferID {
            switch frame.kind {
            case .chunk:
                try download.staging.append(frame.payload)
                fileTransferProgress += UInt64(frame.payload.count)
            case .cancel:
                download.staging.cancel()
                pendingFileDownload = nil
                completeFileTransfer(frame.transferID, status: .canceled)
                resumePendingImageDownload()
                startNextQueuedFilesIfPossible()
            case .complete:
                fileTransferHistory.update(frame.transferID, status: .verifying)
                let destination = try download.staging.finish()
                lastReceivedFileDirectory = destination
                fileTransferLocations[frame.transferID] = destination
                send(.transferComplete(.init(transferID: frame.transferID)))
                pendingFileDownload = nil
                completeFileTransfer(frame.transferID, status: .completed)
                resumePendingImageDownload()
                startNextQueuedFilesIfPossible()
            }
            return
        }
        guard var download = pendingImageDownload,
              download.offer.transferID == frame.transferID else {
            throw ImageTransferError.imageMetadataMismatch
        }
        switch frame.kind {
        case .chunk:
            let nextCount = download.data.count.addingReportingOverflow(frame.payload.count)
            guard !nextCount.overflow,
                  UInt64(nextCount.partialValue) <= download.offer.totalBytes else {
                throw ClipboardContentError.imageTooLarge(nextCount.partialValue)
            }
            download.data.append(frame.payload)
            pendingImageDownload = download
        case .cancel:
            cancelActiveImageTransfer(notifyPeer: false)
            resumePendingImageDownload()
        case .complete:
            guard let image = download.state.content.image else {
                throw ImageTransferError.imageMetadataMismatch
            }
            try image.validate(download.data)
            try clipboardMonitor.apply(download.state, imageData: download.data)
            send(.transferComplete(.init(transferID: frame.transferID)))
            pendingImageDownload = nil
            imageTransferTask = nil
            resumePendingImageDownload()
        }
    }

    private func finishImageUpload(with state: ClipboardState) {
        clipboardMonitor.acknowledge(state)
        imageTransferTask?.cancel()
        imageTransferTask = nil
        pendingImageUpload = nil
        pendingImageUploadState = nil
        resumePendingImageDownload()
    }

    private func startImageAcknowledgementDeadline(for transferID: TransferID) {
        imageTransferTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self,
                  self.pendingImageUpload?.image.transferID == transferID else { return }
            self.handleImageTransferError(
                ImageTransferError.acknowledgementTimeout,
                transferID: transferID
            )
        }
    }

    private func handleTransferFailure(
        _ failure: TransferFailure,
        status: FileTransferStatus
    ) {
        if pendingFileDownload?.offer.transferID == failure.transferID ||
            incomingFileOffer?.transferID == failure.transferID {
            fileTransferError = "\(text("File transfer failed")): \(failure.code)"
            cancelFileTransfer(notifyPeer: false, status: status, cancelQueue: false)
            return
        }
        if pendingFileUpload?.transferID == failure.transferID {
            fileTransferError = "\(text("File transfer failed")): \(failure.code)"
            cancelFileTransfer(notifyPeer: false, status: status, cancelQueue: false)
            return
        }
        let isActive = pendingImageUpload?.image.transferID == failure.transferID ||
            pendingImageDownload?.offer.transferID == failure.transferID
        guard isActive || pendingDownloadOffer?.transferID == failure.transferID else { return }
        clipboardError = "Clipboard image transfer failed: \(failure.code)"
        if isActive {
            cancelActiveImageTransfer(notifyPeer: false)
            resumePendingImageDownload()
        } else {
            cancelPendingImageDownload(notifyPeer: false)
        }
    }

    private func handleImageTransferError(_ error: Error, transferID: TransferID) {
        let isActive = pendingImageUpload?.image.transferID == transferID ||
            pendingImageDownload?.offer.transferID == transferID
        guard isActive || pendingDownloadOffer?.transferID == transferID else { return }
        clipboardError = text(error.localizedDescription)
        send(.transferError(.init(transferID: transferID, code: "image_transfer_failed")))
        if isActive {
            cancelActiveImageTransfer(notifyPeer: false)
            resumePendingImageDownload()
        } else {
            cancelPendingImageDownload(notifyPeer: false)
        }
    }

    private func handleTransferCancellation(_ reference: TransferReference) {
        if pendingFileDownload?.offer.transferID == reference.transferID ||
            incomingFileOffer?.transferID == reference.transferID {
            cancelFileTransfer(notifyPeer: false, status: .canceled, cancelQueue: false)
            return
        }
        if pendingFileUpload?.transferID == reference.transferID {
            cancelFileTransfer(notifyPeer: false, status: .canceled, cancelQueue: false)
            return
        }
        if pendingImageUpload?.image.transferID == reference.transferID ||
            pendingImageDownload?.offer.transferID == reference.transferID {
            cancelActiveImageTransfer(notifyPeer: false)
            resumePendingImageDownload()
        } else if pendingDownloadOffer?.transferID == reference.transferID {
            cancelPendingImageDownload(notifyPeer: false)
        }
    }

    private func resumePendingImageDownload() {
        do {
            try tryStartImageDownload()
        } catch {
            guard let transferID = pendingDownloadOffer?.transferID else { return }
            handleImageTransferError(error, transferID: transferID)
        }
    }

    private func cancelActiveImageTransfer(notifyPeer: Bool) {
        let transferIDs = [
            pendingImageUpload?.image.transferID,
            pendingImageDownload?.offer.transferID
        ].compactMap { $0 }
        if notifyPeer {
            for transferID in Set(transferIDs) {
                send(.transferCancel(.init(transferID: transferID)))
            }
        }
        imageTransferTask?.cancel()
        imageTransferTask = nil
        bulkConnection?.disconnect()
        pendingImageUpload = nil
        pendingImageUploadState = nil
        pendingImageDownload = nil
    }

    private func cancelPendingImageDownload(notifyPeer: Bool) {
        if notifyPeer, let transferID = pendingDownloadOffer?.transferID {
            send(.transferCancel(.init(transferID: transferID)))
        }
        pendingDownloadOffer = nil
        pendingDownloadState = nil
    }

    private func cancelImageTransfer(notifyPeer: Bool = true) {
        cancelActiveImageTransfer(notifyPeer: notifyPeer)
        cancelPendingImageDownload(notifyPeer: notifyPeer)
    }

    func sendFiles(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard canSend, !fileURLs.isEmpty else { return }
        let selection = QueuedFileSelection(
            transferID: TransferID(),
            urls: fileURLs,
            name: Self.transferName(for: fileURLs),
            startedAt: Date()
        )
        retryFileSources[selection.transferID] = fileURLs
        queuedFileSelections.append(selection)
        fileTransferHistory.record(.init(
            transferID: selection.transferID,
            name: selection.name,
            direction: .upload,
            totalBytes: 0,
            deviceName: selectedDevice?.name ?? text("Windows PC"),
            startedAt: selection.startedAt,
            status: .queued
        ))
        startNextQueuedFilesIfPossible()
    }

    private func startNextQueuedFilesIfPossible() {
        guard canSend, fileTransferTask == nil,
              pendingFileUpload == nil, pendingFileDownload == nil,
              incomingFileOffer == nil,
              pendingImageUpload == nil, pendingImageDownload == nil,
              !queuedFileSelections.isEmpty else { return }
        let selection = queuedFileSelections.removeFirst()
        activeFileTransferID = selection.transferID
        fileTransferError = nil
        fileTransferProgress = 0
        fileTransferTotalBytes = 0
        fileTransferTask = Task { @MainActor [weak self] in
            do {
                let buildTask = Task.detached {
                    try FileTransferBatch.build(from: selection.urls)
                }
                let batch = try await withTaskCancellationHandler {
                    try await buildTask.value
                } onCancel: {
                    buildTask.cancel()
                }
                try Task.checkCancellation()
                guard let self, canSend,
                      activeFileTransferID == selection.transferID else { return }
                pendingFileUpload = PendingFileUpload(
                    transferID: selection.transferID,
                    batch: batch
                )
                fileTransferTotalBytes = batch.manifest.totalBytes
                fileTransferHistory.record(.init(
                    transferID: selection.transferID,
                    name: selection.name,
                    direction: .upload,
                    totalBytes: batch.manifest.totalBytes,
                    deviceName: selectedDevice?.name ?? text("Windows PC"),
                    startedAt: selection.startedAt,
                    status: .awaitingApproval
                ))
                send(.transferOffer(try TransferOffer(
                    transferID: selection.transferID,
                    kind: .files,
                    direction: .upload,
                    totalBytes: batch.manifest.totalBytes,
                    manifest: batch.manifest
                )))
                fileTransferTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, activeFileTransferID == selection.transferID else { return }
                fileTransferTask = nil
                fileTransferError = fileTransferMessage(error)
                completeFileTransfer(selection.transferID, status: .failed)
                startNextQueuedFilesIfPossible()
            }
        }
    }

    func acceptIncomingFiles(_ transferID: TransferID, to destination: URL) throws {
        guard let offer = incomingFileOffer, offer.transferID == transferID else { return }
        guard pendingImageUpload == nil, pendingImageDownload == nil,
              pendingFileUpload == nil, pendingFileDownload == nil else {
            throw FileTransferError.bulkBusy
        }
        guard let manifest = offer.manifest else { return }
        guard let device = selectedDevice else {
            throw FileTransferError.selectedDeviceUnavailable
        }
        let staging = try FileTransferStaging(
            destinationRoot: destination,
            transferID: offer.transferID,
            manifest: manifest
        )
        pendingFileDownload = PendingFileDownload(offer: offer, staging: staging)
        incomingFileOffer = nil
        activeFileTransferID = offer.transferID
        fileTransferError = nil
        fileTransferProgress = 0
        fileTransferTotalBytes = offer.totalBytes
        fileTransferHistory.update(offer.transferID, status: .transferring)
        send(.transferAccept(.init(transferID: offer.transferID)))
        bulkConnection.connect(
            to: device,
            transferID: offer.transferID,
            direction: .download,
            totalBytes: offer.totalBytes
        )
    }

    func rejectIncomingFiles(_ transferID: TransferID) {
        guard let offer = incomingFileOffer, offer.transferID == transferID else { return }
        send(.transferReject(.init(transferID: offer.transferID, code: "user_rejected")))
        incomingFileOffer = nil
        fileTransferHistory.update(offer.transferID, status: .rejected)
        resumePendingImageDownload()
        startNextQueuedFilesIfPossible()
    }

    func cancelFiles() {
        cancelFileTransfer(cancelQueue: false)
    }

    func cancelAllFiles() {
        cancelFileTransfer()
    }

    func cancelFiles(_ transferID: TransferID) {
        if let index = queuedFileSelections.firstIndex(where: { $0.transferID == transferID }) {
            queuedFileSelections.remove(at: index)
            fileTransferHistory.update(transferID, status: .canceled)
            return
        }
        guard activeFileTransferID == transferID ||
                incomingFileOffer?.transferID == transferID else { return }
        cancelFileTransfer(cancelQueue: false)
    }

    func retryFiles(_ transferID: TransferID) {
        guard let urls = retryFileSources[transferID] else { return }
        sendFiles(urls)
    }

    func canRetryFiles(_ transferID: TransferID) -> Bool {
        canSend && retryFileSources[transferID] != nil
    }

    func canRevealFiles(_ transferID: TransferID) -> Bool {
        fileTransferLocations[transferID] != nil || retryFileSources[transferID] != nil
    }

    func revealFiles(_ transferID: TransferID) {
        if let destination = fileTransferLocations[transferID] {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } else if let urls = retryFileSources[transferID] {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func clearFileTransferHistory() {
        retryFileSources.removeAll()
        fileTransferLocations.removeAll()
        fileTransferError = nil
        fileTransferHistory.clear()
    }

    func fileTransferMessage(_ error: Error) -> String {
        switch error {
        case let error as FileTransferBatchError:
            switch error {
            case let .unsupportedItem(path):
                return "\(text("Unsupported file or folder")): \(path)"
            case let .sourceChanged(path):
                return "\(text("File changed during transfer")): \(path)"
            }
        case let error as FileTransferStagingError:
            switch error {
            case .sizeMismatch:
                return text("Received file size does not match the offer")
            case let .digestMismatch(path):
                return "\(text("File verification failed")): \(path)"
            case .alreadyFinished:
                return text("The transfer has already finished")
            case .insufficientSpace:
                return text("Not enough disk space")
            case .stagingCollision:
                return text("A temporary transfer already exists")
            }
        default:
            return text(error.localizedDescription)
        }
    }

    private func cancelFileTransfer(
        notifyPeer: Bool = true,
        status: FileTransferStatus = .canceled,
        cancelQueue: Bool = true
    ) {
        let hasActiveBulk = pendingFileUpload?.started == true || pendingFileDownload != nil
        var transferIDs = [
            pendingFileUpload?.transferID,
            pendingFileDownload?.offer.transferID,
            incomingFileOffer?.transferID,
            activeFileTransferID
        ].compactMap { $0 }
        if cancelQueue {
            transferIDs.append(contentsOf: queuedFileSelections.map(\.transferID))
            queuedFileSelections.removeAll()
        }
        if notifyPeer {
            for transferID in Set(transferIDs) {
                send(.transferCancel(.init(transferID: transferID)))
            }
        }
        for transferID in Set(transferIDs) {
            fileTransferHistory.update(transferID, status: status)
        }
        fileTransferTask?.cancel()
        fileTransferTask = nil
        pendingFileDownload?.staging.cancel()
        pendingFileUpload = nil
        pendingFileDownload = nil
        incomingFileOffer = nil
        activeFileTransferID = nil
        fileTransferProgress = 0
        fileTransferTotalBytes = 0
        if hasActiveBulk { bulkConnection?.disconnect() }
        resumePendingImageDownload()
        if !cancelQueue { startNextQueuedFilesIfPossible() }
    }

    private func completeFileTransfer(
        _ transferID: TransferID,
        status: FileTransferStatus
    ) {
        fileTransferHistory.update(transferID, status: status)
        guard activeFileTransferID == transferID else { return }
        activeFileTransferID = nil
        fileTransferProgress = 0
        fileTransferTotalBytes = 0
    }

    private static var defaultFileTransferDestination: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Passwall", isDirectory: true)
    }

    private static func restoredFileTransferHistory(
        from preferences: UserDefaults
    ) -> FileTransferHistoryStore {
        var history = preferences.data(forKey: "transfer.history")
            .flatMap { try? JSONDecoder().decode(FileTransferHistoryStore.self, from: $0) }
            ?? FileTransferHistoryStore()
        for entry in history.entries {
            switch entry.status {
            case .queued, .awaitingApproval, .transferring, .verifying:
                history.update(entry.transferID, status: .failed)
            case .completed, .rejected, .canceled, .failed:
                break
            }
        }
        return history
    }

    private static func transferName(for urls: [URL]) -> String {
        guard let first = urls.first else { return "Files" }
        return urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) +\(urls.count - 1)"
    }

    private static func transferName(for manifest: FileTransferManifest?) -> String {
        guard let entries = manifest?.entries, let first = entries.first else { return "Files" }
        let roots = entries.filter { !$0.path.contains("/") }
        return roots.count <= 1 ? first.path : "\(roots[0].path) +\(roots.count - 1)"
    }

    private func notifyIncomingFiles(_ offer: TransferOffer) {
        let content = UNMutableNotificationContent()
        content.title = text("Incoming files")
        content.body = "\(Self.transferName(for: offer.manifest)) · \(ByteCountFormatter.string(fromByteCount: Int64(offer.totalBytes), countStyle: .file))"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: offer.transferID.description,
            content: content,
            trigger: nil
        )
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                return
            }
            try? await center.add(request)
        }
    }

    private var selectedDevice: DiscoveredWindowsDevice? {
        guard let selectedNearbyDeviceID else { return nil }
        return nearbyWindowsPCs.first { $0.id == selectedNearbyDeviceID }
    }

    private func failConnection(_ error: Error) {
        stopCapture()
        clipboardMonitor.stop()
        cancelImageTransfer()
        cancelFileTransfer(notifyPeer: false, status: .failed)
        stopHeartbeat()
        identityVerifier.cancel()
        let failedConnection = connection
        connection = nil
        inboundDecoder.reset()
        inboundMessageValidator = nil
        failedConnection?.cancel()
        status = .failed(error.localizedDescription)
    }

    private func startHeartbeat(on connection: NWConnection) {
        stopHeartbeat()
        heartbeatDeadline = HeartbeatDeadline(
            startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(
                    Int64(HeartbeatDeadline.sendIntervalNanoseconds)
                ))
                guard !Task.isCancelled, let self else { return }
                guard self.connection === connection, self.status == .connected else { return }

                let now = DispatchTime.now().uptimeNanoseconds
                if self.heartbeatDeadline?.hasExpired(atNanoseconds: now) == true {
                    self.failConnection(ConnectionLifecycleError.heartbeatTimedOut)
                    return
                }
                self.send(.heartbeat)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatDeadline = nil
    }
}

private enum InboundProtocolError: LocalizedError {
    case missingSession
    case unexpectedPayload

    var errorDescription: String? {
        switch self {
        case .missingSession:
            "Receiver response arrived outside an active session"
        case .unexpectedPayload:
            "Receiver sent an unexpected payload"
        }
    }
}

private enum ConnectionLifecycleError: LocalizedError {
    case heartbeatTimedOut

    var errorDescription: String? {
        switch self {
        case .heartbeatTimedOut:
            "Receiver heartbeat timed out"
        }
    }
}

private enum FourFingerPreferenceKey: String {
    case left = "gesture.four-finger.left"
    case right = "gesture.four-finger.right"
    case up = "gesture.four-finger.up"
    case down = "gesture.four-finger.down"
}

private enum CalibrationPreferenceKey: String {
    case pointerGain = "calibration.pointer-gain"
    case scrollGain = "calibration.scroll-gain"
}
