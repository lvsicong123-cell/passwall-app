import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore

    var body: some View {
        Form {
            Section(store.text("Appearance")) {
                Picker(store.text("Language"), selection: $store.language) {
                    Text("中文").tag(AppLanguage.chineseSimplified)
                    Text("English").tag(AppLanguage.english)
                }
                .pickerStyle(.segmented)

                Picker(store.text("Appearance"), selection: $store.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(
                            store.text(appearance.titleKey),
                            systemImage: appearance.symbol
                        )
                        .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section(store.text("Startup")) {
                Toggle(store.text("Open Passwall at login"), isOn: Binding(
                    get: { store.launchAtLoginEnabled },
                    set: { store.setLaunchAtLoginEnabled($0) }
                ))
                if let error = store.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section(store.text("Input")) {
                Toggle(store.text("Share clipboard"), isOn: $store.shareClipboard)
                if let error = store.clipboardError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle(store.text("Smart shortcut mapping"), isOn: $store.smartShortcutMapping)
                Toggle(store.text("Inertial scrolling"), isOn: $store.enableInertia)
            }
        }
        .formStyle(.grouped)
        .tint(.passwallAccent)
        .frame(width: 480)
        .padding()
    }
}
