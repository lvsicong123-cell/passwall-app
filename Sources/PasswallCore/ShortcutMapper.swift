public enum InputModifier: String, Sendable, Hashable, Codable {
    case command
    case option
    case control
    case shift
    case alt
    case windows
}

public enum LogicalKey: Sendable, Hashable, Codable {
    case letter(String)
    case tab
    case space
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case home
    case end
    case other(String)
}

public struct Shortcut: Sendable, Equatable, Codable {
    public var key: LogicalKey
    public var modifiers: Set<InputModifier>

    public init(key: LogicalKey, modifiers: Set<InputModifier>) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum WindowsShortcutMapper {
    public static func translate(_ shortcut: Shortcut) -> Shortcut {
        var modifiers = shortcut.modifiers
        var key = shortcut.key

        if modifiers.contains(.command), shortcut.key == .tab {
            modifiers.remove(.command)
            modifiers.insert(.alt)
            return Shortcut(key: key, modifiers: normalized(modifiers))
        }

        if modifiers.contains(.command) {
            switch shortcut.key {
            case .letter:
                modifiers.remove(.command)
                modifiers.insert(.control)
            case .leftArrow:
                modifiers.remove(.command)
                key = .home
            case .rightArrow:
                modifiers.remove(.command)
                key = .end
            case .upArrow:
                modifiers.remove(.command)
                modifiers.insert(.control)
                key = .home
            case .downArrow:
                modifiers.remove(.command)
                modifiers.insert(.control)
                key = .end
            default:
                modifiers.remove(.command)
                modifiers.insert(.windows)
            }
        }

        if modifiers.contains(.option) {
            modifiers.remove(.option)
            if key == .leftArrow || key == .rightArrow {
                modifiers.insert(.control)
            } else {
                modifiers.insert(.alt)
            }
        }

        return Shortcut(key: key, modifiers: normalized(modifiers))
    }

    private static func normalized(_ modifiers: Set<InputModifier>) -> Set<InputModifier> {
        var result = modifiers
        if result.remove(.control) != nil {
            result.insert(.control)
        }
        return result
    }
}
