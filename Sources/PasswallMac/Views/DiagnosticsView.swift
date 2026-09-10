import SwiftUI

struct DiagnosticsView: View {
    @Bindable var store: AppStore

    var body: some View {
        ControlPage {
            ControlSection(title: store.text("Pointer bench")) {
                HStack(spacing: 8) {
                    actionButton("arrow.left", help: "Move left") { store.nudge(dx: -24, dy: 0) }
                    actionButton("arrow.up", help: "Move up") { store.nudge(dx: 0, dy: -24) }
                    actionButton("arrow.down", help: "Move down") { store.nudge(dx: 0, dy: 24) }
                    actionButton("arrow.right", help: "Move right") { store.nudge(dx: 24, dy: 0) }
                    actionButton("cursorarrow.click", help: "Left click") { store.click(.left) }
                }
            }

            ControlSection(title: store.text("Scroll bench")) {
                HStack(spacing: 8) {
                    actionButton("arrow.up", help: "Scroll up") { store.scroll(vertical: 12) }
                    actionButton("arrow.down", help: "Scroll down") { store.scroll(vertical: -12) }
                    actionButton("arrow.left", help: "Scroll left") { store.scroll(horizontal: -12) }
                    actionButton("arrow.right", help: "Scroll right") { store.scroll(horizontal: 12) }
                }
            }

            ControlSection(title: store.text("Transport")) {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent(
                        store.text("Events sent"),
                        value: store.eventCount.formatted()
                    )
                    LabeledContent(store.text("Send completion")) {
                        if let latency = store.lastRoundTripMilliseconds {
                            Text("\(latency, format: .number.precision(.fractionLength(2))) ms")
                                .monospacedDigit()
                        } else {
                            Text(store.text("Not measured"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(store.text("Measure"), systemImage: "stopwatch") {
                        store.measureRoundTrip()
                    }
                    .disabled(!store.canSend)
                }
            }
        }
        .tint(.passwallAccent)
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .disabled(!store.canSend)
        .help(store.text(help))
    }
}
