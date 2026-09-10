import AppKit
import SwiftUI

@main
struct PasswallMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("Passwall", id: "main") {
            ContentView(store: store)
                .environment(\.locale, store.language.locale)
                .preferredColorScheme(store.appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            PasswallMenuBarView(store: store)
                .environment(\.locale, store.language.locale)
                .preferredColorScheme(store.appearance.colorScheme)
        } label: {
            PasswallMenuBarIcon()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(store: store)
                .environment(\.locale, store.language.locale)
                .preferredColorScheme(store.appearance.colorScheme)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasActiveFileTransfer else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = store.text("Quit while files are transferring?")
        alert.informativeText = store.text("Active and queued transfers will be canceled.")
        alert.addButton(withTitle: store.text("Quit Passwall"))
        alert.addButton(withTitle: store.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        store.cancelAllFiles()
        return .terminateNow
    }
}
