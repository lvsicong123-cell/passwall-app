import Testing
@testable import PasswallCore

@Suite("Mac to Windows shortcut translation")
struct ShortcutMapperTests {
    @Test("Common Command shortcuts become Control shortcuts")
    func commonEditingShortcut() {
        let translated = WindowsShortcutMapper.translate(
            .init(key: .letter("c"), modifiers: [.command])
        )

        #expect(translated == .init(key: .letter("c"), modifiers: [.control]))
    }

    @Test("Command letters never become Windows shortcuts")
    func commandLetters() {
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            let translated = WindowsShortcutMapper.translate(
                .init(key: .letter(String(letter)), modifiers: [.command])
            )

            #expect(translated == .init(
                key: .letter(String(letter)),
                modifiers: [.control]
            ))
        }
    }

    @Test("Command Tab uses the Windows app switcher")
    func appSwitcher() {
        let translated = WindowsShortcutMapper.translate(
            .init(key: .tab, modifiers: [.command, .shift])
        )

        #expect(translated == .init(key: .tab, modifiers: [.alt, .shift]))
    }

    @Test("Option arrow moves by word")
    func wordNavigation() {
        let translated = WindowsShortcutMapper.translate(
            .init(key: .leftArrow, modifiers: [.option])
        )

        #expect(translated == .init(key: .leftArrow, modifiers: [.control]))
    }

    @Test("Command arrow maps to document edge")
    func documentEdge() {
        let translated = WindowsShortcutMapper.translate(
            .init(key: .rightArrow, modifiers: [.command, .shift])
        )

        #expect(translated == .init(key: .end, modifiers: [.shift]))
    }

    @Test("Command vertical arrows map to document boundaries")
    func documentBoundary() {
        #expect(WindowsShortcutMapper.translate(
            .init(key: .upArrow, modifiers: [.command, .shift])
        ) == .init(key: .home, modifiers: [.control, .shift]))
        #expect(WindowsShortcutMapper.translate(
            .init(key: .downArrow, modifiers: [.command])
        ) == .init(key: .end, modifiers: [.control]))
    }
}
