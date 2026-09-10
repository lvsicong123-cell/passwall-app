import PasswallCore
import SwiftUI

struct LayoutView: View {
    @Bindable var store: AppStore

    var body: some View {
        ControlPage {
            ControlSection(title: store.text("Screen arrangement")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.text("Windows position"))
                        .foregroundStyle(.secondary)
                    Picker(store.text("Windows position"), selection: $store.remotePosition) {
                        Label(store.text("Left"), systemImage: "arrow.left").tag(ScreenEdge.left)
                        Label(store.text("Right"), systemImage: "arrow.right").tag(ScreenEdge.right)
                        Label(store.text("Above"), systemImage: "arrow.up").tag(ScreenEdge.top)
                        Label(store.text("Below"), systemImage: "arrow.down").tag(ScreenEdge.bottom)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            ControlSection(title: store.text("Edge pressure")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(store.text("Activation distance"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(store.activationDistance)) pt")
                            .monospacedDigit()
                    }
                    Slider(value: $store.activationDistance, in: 8...60, step: 1)
                }
            }
        }
        .tint(.passwallAccent)
    }
}
