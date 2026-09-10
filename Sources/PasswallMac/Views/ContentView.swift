import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    let enablesFileDrop: Bool

    init(store: AppStore, enablesFileDrop: Bool = true) {
        self.store = store
        self.enablesFileDrop = enablesFileDrop
    }

    private var currentSection: AppSection {
        store.selection ?? .devices
    }

    private var selectedDeviceName: String? {
        store.nearbyWindowsPCs.first {
            $0.id == store.selectedNearbyDeviceID
        }?.name
    }

    var body: some View {
        HStack(spacing: 0) {
            ControlSidebar(store: store)
            Divider()
            VStack(spacing: 0) {
                controlHeader
                Divider()
                detail
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.passwallAccent)
        .sheet(isPresented: incomingFilesPresented) {
            if let offer = store.incomingFileOffer {
                IncomingFilesView(store: store, offer: offer)
                    .id(offer.transferID)
            }
        }
    }

    private var controlHeader: some View {
        HStack(spacing: 14) {
            Text(store.text(currentSection == .devices ? "Control" : currentSection.rawValue))
                .font(.headline)

            Spacer(minLength: 24)

            HStack(spacing: 7) {
                Circle()
                    .fill(store.status.color)
                    .frame(width: 8, height: 8)
                if let selectedDeviceName {
                    Text(selectedDeviceName)
                        .fontWeight(.medium)
                    Text("·")
                        .foregroundStyle(.tertiary)
                }
                Text(store.text(store.status.label))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Divider()
                .frame(height: 20)

            languageMenu
                .frame(minWidth: 58, minHeight: 30)
            appearanceMenu
                .frame(width: 32, height: 30)
            Button {
                NSApp.keyWindow?.orderOut(nil)
            } label: {
                Image(systemName: "menubar.rectangle")
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.text("Hide in Menu Bar"))
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(.bar)
    }

    @ViewBuilder
    private var detail: some View {
        switch currentSection {
        case .devices:
            DevicesView(store: store)
        case .transfer:
            TransferView(store: store, enablesFileDrop: enablesFileDrop)
        case .layout:
            LayoutView(store: store)
        case .gestures:
            GesturesView(store: store)
        case .shortcuts:
            ShortcutsView(store: store)
        case .diagnostics:
            DiagnosticsView(store: store)
        }
    }

    private var incomingFilesPresented: Binding<Bool> {
        Binding(
            get: { store.incomingFileOffer != nil },
            set: { _ in }
        )
    }

    private var languageMenu: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    store.language = language
                } label: {
                    if store.language == language {
                        Label(language.shortLabel, systemImage: "checkmark")
                    } else {
                        Text(language.shortLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                Text(store.language.shortLabel)
            }
        }
        .help(store.text("Language"))
    }

    private var appearanceMenu: some View {
        Menu {
            ForEach(AppAppearance.allCases) { appearance in
                Button {
                    store.appearance = appearance
                } label: {
                    Label(
                        store.text(appearance.titleKey),
                        systemImage: store.appearance == appearance
                            ? "checkmark"
                            : appearance.symbol
                    )
                }
            }
        } label: {
            Image(systemName: store.appearance.symbol)
        }
        .help(store.text("Appearance"))
    }
}

private struct ControlSidebar: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(spacing: 8) {
            PasswallSidebarIcon()
                .foregroundStyle(Color.passwallAccent)
                .frame(width: 40, height: 44)
                .padding(.bottom, 4)

            ForEach(AppSection.allCases) { section in
                sidebarButton(section)
            }

            Spacer(minLength: 12)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.text("Settings"))
        }
        .padding(.vertical, 10)
        .frame(width: 64)
        .background(.bar)
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        Button {
            store.selection = section
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(store.selection == section ? Color.primary.opacity(0.08) : .clear)
                    .frame(width: 48, height: 42)

                if store.selection == section {
                    Capsule()
                        .fill(Color.passwallAccent)
                        .frame(width: 3, height: 27)
                        .offset(x: -4)
                }

                Image(systemName: section.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(store.selection == section ? Color.passwallAccent : .primary)
                    .frame(width: 48, height: 42)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.text(section.rawValue))
        .accessibilityLabel(store.text(section.rawValue))
    }
}
