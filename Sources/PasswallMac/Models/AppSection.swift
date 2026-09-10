import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case devices = "Devices"
    case transfer = "Transfer"
    case layout = "Layout"
    case gestures = "Gestures"
    case shortcuts = "Shortcuts"
    case diagnostics = "Diagnostics"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .devices: "display.2"
        case .transfer: "arrow.left.arrow.right"
        case .layout: "rectangle.split.2x1"
        case .gestures: "hand.draw"
        case .shortcuts: "command"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case let .failed(message): message
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting: .orange
        case .disconnected, .failed: .secondary
        }
    }
}
