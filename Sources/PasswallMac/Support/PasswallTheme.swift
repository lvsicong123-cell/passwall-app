import AppKit
import SwiftUI

extension Color {
    static let passwallAccent = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 79 / 255, green: 140 / 255, blue: 1, alpha: 1)
                : NSColor(red: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)
        }
    ))
}
