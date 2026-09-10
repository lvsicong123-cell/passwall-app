import AppKit
import SwiftUI

struct PasswallMenuBarIcon: View {
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "PasswallMenuBarTemplate",
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
            } else {
                Image(systemName: "arrow.left.arrow.right.square")
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel("Passwall")
    }
}

struct PasswallSidebarIcon: View {
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "PasswallMenuBarTemplate",
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 25, height: 25)
        return image
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
            } else {
                Image(systemName: "arrow.left.arrow.right.square")
            }
        }
        .frame(width: 25, height: 25)
        .accessibilityHidden(true)
    }
}

struct PasswallMenuBarPresentation: Equatable {
    let title: String
    let systemImage: String

    init(
        status: ConnectionStatus,
        captureEnabled: Bool,
        remoteControlActive: Bool
    ) {
        if remoteControlActive {
            title = "Controlling Windows"
            systemImage = "cursorarrow.rays"
        } else if captureEnabled {
            title = "Ready at Screen Edge"
            systemImage = "arrow.left.arrow.right.circle.fill"
        } else {
            switch status {
            case .connected:
                title = "Connected"
                systemImage = "link.circle.fill"
            case .connecting:
                title = "Connecting"
                systemImage = "ellipsis.circle"
            case .disconnected:
                title = "Not Connected"
                systemImage = "circle.dashed"
            case .failed:
                title = "Connection Failed"
                systemImage = "exclamationmark.triangle.fill"
            }
        }
    }
}

struct PasswallMenuBarView: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow

    private var presentation: PasswallMenuBarPresentation {
        PasswallMenuBarPresentation(
            status: store.status,
            captureEnabled: store.captureEnabled,
            remoteControlActive: store.remoteControlActive
        )
    }

    private var selectedDeviceName: String? {
        store.nearbyWindowsPCs.first {
            $0.id == store.selectedNearbyDeviceID
        }?.name
    }

    var body: some View {
        Label(store.text(presentation.title), systemImage: presentation.systemImage)
            .disabled(true)

        if let selectedDeviceName {
            Text(selectedDeviceName)
                .disabled(true)
        }

        Divider()

        if store.remoteControlActive {
            Button(store.text("Return to Mac"), systemImage: "arrow.uturn.backward") {
                store.returnControlToMac()
            }
        }

        if store.captureEnabled {
            Button(store.text("Stop Input Sharing"), systemImage: "stop.fill") {
                store.stopCapture()
            }
        } else {
            Button(store.text("Start Input Sharing"), systemImage: "play.fill") {
                store.startCapture()
            }
            .disabled(!store.canSend || !store.accessibilityTrusted)
        }

        if store.canSend {
            Button(store.text("Disconnect"), systemImage: "xmark") {
                store.disconnect()
            }
        }

        Divider()

        Button(store.text("Open Passwall"), systemImage: "macwindow") {
            showMainWindow()
        }

        SettingsLink {
            Label(store.text("Settings..."), systemImage: "gearshape")
        }

        Toggle(store.text("Open at Login"), isOn: Binding(
            get: { store.launchAtLoginEnabled },
            set: { store.setLaunchAtLoginEnabled($0) }
        ))

        Divider()

        Button(store.text("Quit Passwall"), systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
