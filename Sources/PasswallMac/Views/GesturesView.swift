import Foundation
import PasswallCore
import SwiftUI

struct GesturesView: View {
    @Bindable var store: AppStore

    var body: some View {
        ControlPage {
            ControlSection(title: store.text("Trackpad")) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(store.text("Inertial scrolling"), isOn: $store.enableInertia)
                    Toggle(store.text("Swipe for Back and Forward"), isOn: $store.enableNavigationGestures)
                    Toggle(store.text("Pinch to zoom"), isOn: $store.enablePinchZoom)
                }
            }

            ControlSection(title: store.text("Calibration")) {
                VStack(spacing: 18) {
                    gainSlider(store.text("Pointer speed"), value: $store.pointerGain)
                    gainSlider(store.text("Scroll speed"), value: $store.scrollGain)
                }
            }

            ControlSection(title: store.text("Four-finger swipe")) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    mappingRow(store.text("Swipe left"), selection: $store.fourFingerSwipeLeft)
                    mappingRow(store.text("Swipe right"), selection: $store.fourFingerSwipeRight)
                    mappingRow(store.text("Swipe up"), selection: $store.fourFingerSwipeUp)
                    mappingRow(store.text("Swipe down"), selection: $store.fourFingerSwipeDown)
                }
            }
        }
        .tint(.passwallAccent)
    }

    private func mappingRow(
        _ title: String,
        selection: Binding<FourFingerSwipeMapping>
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Picker(title, selection: selection) {
                ForEach(FourFingerSwipeMapping.allCases, id: \.rawValue) {
                    Text(store.text($0.title)).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 230)
        }
    }

    private func gainSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f×", value.wrappedValue))
                    .monospacedDigit()
            }
            Slider(value: value, in: 0.5...2, step: 0.05)
        }
    }
}

private extension FourFingerSwipeMapping {
    var title: String {
        switch self {
        case .none: "No action"
        case .previousDesktop: "Previous desktop"
        case .nextDesktop: "Next desktop"
        case .taskView: "Task View"
        case .showDesktop: "Show desktop"
        case .back: "Back"
        case .forward: "Forward"
        }
    }
}
