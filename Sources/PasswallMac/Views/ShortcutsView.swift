import SwiftUI

struct ShortcutsView: View {
    @Bindable var store: AppStore

    var body: some View {
        ControlPage {
            ControlSection(title: store.text("Keyboard")) {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(
                        store.text("Smart Mac to Windows mapping"),
                        isOn: $store.smartShortcutMapping
                    )
                    Divider()
                    LabeledContent(
                        store.text("Copy and paste"),
                        value: store.text("Command to Control")
                    )
                    LabeledContent(
                        store.text("App switcher"),
                        value: store.text("Command-Tab to Alt-Tab")
                    )
                    LabeledContent(
                        store.text("Word navigation"),
                        value: store.text("Option-Arrows to Control-Arrows")
                    )
                }
            }
        }
        .tint(.passwallAccent)
    }
}
