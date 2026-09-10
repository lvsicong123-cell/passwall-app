import AppKit
import PasswallCore
import SwiftUI

struct DevicesView: View {
    @Bindable var store: AppStore

    private var selectedDevice: DiscoveredWindowsDevice? {
        store.nearbyWindowsPCs.first { $0.id == store.selectedNearbyDeviceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DeviceCanvas(
                    edge: store.remotePosition,
                    macTitle: store.text("This Mac"),
                    windowsTitle: store.text("Windows PC"),
                    windowsName: selectedDevice?.name ?? store.text("Select a PC"),
                    windowsAvailable: selectedDevice != nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ConnectionInspector(store: store, selectedDevice: selectedDevice)
                    .frame(width: 286)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            Divider()
            controlBar
        }
        .sheet(isPresented: pairingPresented) {
            PairingView(store: store, attemptsRemaining: pairingAttemptsRemaining)
        }
        .onAppear {
            store.refreshAccessibilityStatus()
            store.startDiscovery()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            store.refreshAccessibilityStatus()
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                store.captureEnabled ? store.stopCapture() : store.startCapture()
            } label: {
                Label(
                    store.text(store.captureEnabled ? "Stop Input Sharing" : "Start Control"),
                    systemImage: store.captureEnabled ? "stop.fill" : "play.fill"
                )
                .frame(minWidth: 126)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.passwallAccent)
            .disabled(!store.captureEnabled && (!store.canSend || !store.accessibilityTrusted))

            Button {
                store.disconnect()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!store.canSend)
            .help(store.text("Disconnect"))

            Button {
                store.returnControlToMac()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!store.remoteControlActive)
            .help(store.text("Return to Mac"))

            Text(store.text("Option + Esc returns to Mac"))
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if let captureError = store.captureError {
                Label(captureError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
        .background(.bar)
    }

    private var pairingPresented: Binding<Bool> {
        Binding(
            get: { pairingAttemptsRemaining != nil },
            set: { if !$0 { store.cancelPairing() } }
        )
    }

    private var pairingAttemptsRemaining: Int? {
        if case let .awaitingCode(deviceID, attemptsRemaining) = store.tlsIdentityState,
           deviceID == store.selectedNearbyDeviceID {
            return attemptsRemaining
        }
        return nil
    }
}

private struct DeviceCanvas: View {
    let edge: ScreenEdge
    let macTitle: String
    let windowsTitle: String
    let windowsName: String
    let windowsAvailable: Bool

    var body: some View {
        Group {
            switch edge {
            case .left:
                HStack(spacing: 24) {
                    windowsNode
                    ScreenBoundary(symbol: "arrow.left", vertical: true)
                    macNode
                }
            case .right:
                HStack(spacing: 24) {
                    macNode
                    ScreenBoundary(symbol: "arrow.right", vertical: true)
                    windowsNode
                }
            case .top:
                VStack(spacing: 12) {
                    windowsNode
                    ScreenBoundary(symbol: "arrow.up", vertical: false)
                    macNode
                }
            case .bottom:
                VStack(spacing: 12) {
                    macNode
                    ScreenBoundary(symbol: "arrow.down", vertical: false)
                    windowsNode
                }
            }
        }
        .padding(36)
    }

    private var macNode: some View {
        DeviceNode(
            symbol: "laptopcomputer",
            title: macTitle,
            subtitle: Host.current().localizedName ?? "Mac",
            available: true
        )
    }

    private var windowsNode: some View {
        DeviceNode(
            symbol: "desktopcomputer",
            title: windowsTitle,
            subtitle: windowsName,
            available: windowsAvailable
        )
    }
}

private struct DeviceNode: View {
    let symbol: String
    let title: String
    let subtitle: String
    let available: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 92, weight: .ultraLight))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(available ? Color.primary : Color.secondary.opacity(0.55))
                .frame(width: 150, height: 112)

            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 160)
        }
        .opacity(available ? 1 : 0.7)
    }
}

private struct ScreenBoundary: View {
    let symbol: String
    let vertical: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.passwallAccent.opacity(0.7))
                .frame(
                    width: vertical ? 1 : 150,
                    height: vertical ? 180 : 1
                )
            Image(systemName: "\(symbol).circle")
                .font(.system(size: 31, weight: .regular))
                .foregroundStyle(Color.passwallAccent)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        }
        .frame(
            width: vertical ? 44 : 180,
            height: vertical ? 190 : 42
        )
    }
}

private struct ConnectionInspector: View {
    @Bindable var store: AppStore
    let selectedDevice: DiscoveredWindowsDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.text("Connection"))
                .font(.headline)

            VStack(spacing: 13) {
                InspectorRow(
                    symbol: "checkmark.circle",
                    title: store.text("Status"),
                    value: store.text(store.status.label),
                    valueColor: store.status == .connected ? .green : .secondary
                )
                InspectorRow(
                    symbol: "clock",
                    title: store.text("Latency"),
                    value: latency
                )
                InspectorRow(
                    symbol: "checkmark.shield",
                    title: store.text("Security"),
                    value: store.canSend ? "TLS 1.3" : "—"
                )
                InspectorRow(
                    symbol: "keyboard",
                    title: store.text("Input"),
                    value: store.text(sharingStateKey)
                )
            }

            Divider()

            gainSlider(store.text("Pointer speed"), value: $store.pointerGain)
            gainSlider(store.text("Scroll speed"), value: $store.scrollGain)

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Text(store.text("Windows position"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker(store.text("Windows position"), selection: $store.remotePosition) {
                    Text(store.text("Left")).tag(ScreenEdge.left)
                    Text(store.text("Right")).tag(ScreenEdge.right)
                    Text(store.text("Above")).tag(ScreenEdge.top)
                    Text(store.text("Below")).tag(ScreenEdge.bottom)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Divider()

            accessibility
            nearbyDevices
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    private var latency: String {
        guard let value = store.lastRoundTripMilliseconds else { return "—" }
        return String(format: "%.1f ms", value)
    }

    private var sharingStateKey: String {
        if store.remoteControlActive { return "Controlling Windows" }
        if store.captureEnabled { return "Ready at screen edge" }
        if store.canSend { return "Ready" }
        return "Stopped"
    }

    private func gainSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f×", value.wrappedValue))
                    .font(.callout)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0.5...2, step: 0.05)
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorRow(
                symbol: "hand.raised",
                title: store.text("Accessibility"),
                value: store.text(store.accessibilityTrusted ? "Granted" : "Required"),
                valueColor: store.accessibilityTrusted ? .green : .secondary
            )
            if !store.accessibilityTrusted {
                Button(store.text("Grant Access")) {
                    store.requestAccessibilityPermission()
                }
            }
        }
    }

    private var nearbyDevices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.text("Nearby Windows PCs"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.refreshDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(store.text("Refresh nearby devices"))
            }

            if store.nearbyWindowsPCs.isEmpty {
                discoveryPlaceholder
            } else {
                ForEach(store.nearbyWindowsPCs) { device in
                    Button {
                        store.selectNearbyDevice(device)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(store.text(identityStatusKey(for: device)))
                                    .font(.caption)
                                    .foregroundStyle(identityStatusColor(for: device))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            if selectedDevice?.id == device.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var discoveryPlaceholder: some View {
        switch store.discoveryState {
        case .stopped, .searching:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(store.text("Searching"))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Text(store.text("No receivers found"))
                .foregroundStyle(.secondary)
        case let .waiting(message), let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func identityStatusKey(for device: DiscoveredWindowsDevice) -> String {
        switch store.tlsIdentityState {
        case .verifying(device.id): "Starting secure pairing"
        case .awaitingCode(device.id, _): "Enter the code shown on Windows"
        case .confirming(device.id): "Confirming pairing"
        case .paired(device.id): "Connected securely"
        case let .failed(device.id, message): message
        default: store.isTrusted(device) ? "Trusted device" : "Pairing required"
        }
    }

    private func identityStatusColor(for device: DiscoveredWindowsDevice) -> Color {
        switch store.tlsIdentityState {
        case .paired(device.id): .green
        case .idle where store.isTrusted(device): .green
        case .failed(device.id, _): .red
        default: .secondary
        }
    }
}

private struct InspectorRow: View {
    let symbol: String
    let title: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.callout)
    }
}

private struct PairingView: View {
    @Bindable var store: AppStore
    let attemptsRemaining: Int?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34))
                .foregroundStyle(Color.passwallAccent)
            Text(store.text("Pair with Windows"))
                .font(.title2.weight(.semibold))
            Text(store.text("Enter the code shown on Windows"))
                .foregroundStyle(.secondary)

            TextField(store.text("Six-digit code"), text: $store.pairingCode)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 210)
                .onChange(of: store.pairingCode) {
                    store.pairingCode = String(
                        store.pairingCode
                            .filter { $0.isASCII && $0.isNumber }
                            .prefix(6)
                    )
                }
                .onSubmit { store.submitPairingCode() }

            if let attemptsRemaining {
                Text("\(store.text("Attempts remaining")): \(attemptsRemaining)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let pairingCodeError = store.pairingCodeError {
                Text(pairingCodeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(store.text("Cancel")) { store.cancelPairing() }
                Button(store.text("Confirm")) { store.submitPairingCode() }
                    .buttonStyle(.borderedProminent)
                    .tint(.passwallAccent)
                    .disabled(store.pairingCode.count != 6)
            }
        }
        .padding(30)
        .frame(width: 360)
    }
}
