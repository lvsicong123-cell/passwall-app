import AppKit
import Foundation
import PasswallCore
import SwiftUI
import Testing
@testable import PasswallMac

@MainActor
@Suite("Visual rendering")
struct VisualRenderingTests {
    @Test("Every control page renders in light Chinese and dark English")
    func rendersLocalizedThemes() throws {
        #expect(AppLanguage.chineseSimplified.localized("Devices") == "设备")
        #expect(AppLanguage.english.localized("Devices") == "Devices")
        #expect(AppLanguage.chineseSimplified.localized("Share clipboard") == "共享剪贴板")
        #expect(AppLanguage.english.localized("Share clipboard") == "Share clipboard")

        for section in AppSection.allCases {
            let light = try render(
                section: section,
                language: .chineseSimplified,
                appearance: .light
            )
            let dark = try render(
                section: section,
                language: .english,
                appearance: .dark
            )

            #expect(light.size.width == 1040)
            #expect(light.size.height == 680)
            #expect(dark.size == light.size)

            if let directory = ProcessInfo.processInfo.environment["PASSWALL_UI_SNAPSHOT"] {
                let page = section.rawValue.lowercased()
                try pngData(light).write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("passwall-\(page)-light-zh.png"))
                try pngData(dark).write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("passwall-\(page)-dark-en.png"))
            }
        }
    }

    @Test("Language and appearance survive store recreation")
    func persistsInterfacePreferences() throws {
        let suite = "com.passwall.preferences.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let initial = AppStore(preferences: preferences)
        initial.language = .english
        initial.appearance = .dark

        let restored = AppStore(preferences: preferences)
        #expect(restored.language == .english)
        #expect(restored.appearance == .dark)
    }

    @Test("Incoming file confirmation renders source, batch, and destination")
    func rendersIncomingFiles() throws {
        let suite = "com.passwall.render-incoming.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = AppStore(preferences: preferences)
        store.language = .chineseSimplified
        let manifest = try FileTransferManifest(entries: [
            .directory(path: "photos"),
            .file(path: "photos/image.jpg", byteCount: 4, sha256: String(repeating: "a", count: 64))
        ])
        let offer = try TransferOffer(
            transferID: TransferID(),
            kind: .files,
            direction: .download,
            totalBytes: 4,
            manifest: manifest
        )
        store.fileTransferHistory.record(.init(
            transferID: offer.transferID,
            name: "photos",
            direction: .download,
            totalBytes: offer.totalBytes,
            deviceName: "Test PC",
            startedAt: .now,
            status: .awaitingApproval
        ))
        #expect(store.text("From") == "来自")
        let renderer = ImageRenderer(content: IncomingFilesView(store: store, offer: offer)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 500)
        #expect(image.size.height > 300)
        if let directory = ProcessInfo.processInfo.environment["PASSWALL_UI_SNAPSHOT"] {
            try pngData(image).write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("passwall-incoming-files-dark-zh.png"))
        }
    }

    private func render(
        section: AppSection,
        language: AppLanguage,
        appearance: AppAppearance
    ) throws -> NSImage {
        let suite = "com.passwall.render.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let store = AppStore(preferences: preferences)
        store.selection = section
        store.language = language
        store.appearance = appearance
        let renderer = ImageRenderer(content: ContentView(store: store, enablesFileDrop: false)
            .preferredColorScheme(appearance.colorScheme)
            .environment(\.colorScheme, appearance.colorScheme ?? .light)
            .frame(width: 1040, height: 680))
        renderer.proposedSize = ProposedViewSize(width: 1040, height: 680)
        renderer.scale = 1
        return try #require(renderer.nsImage)
    }

    private func pngData(_ image: NSImage) throws -> Data {
        let tiff = try #require(image.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: tiff))
        return try #require(representation.representation(using: .png, properties: [:]))
    }
}
