import PasswallCore

struct KeyboardEventMapper {
    private static let modifierOrder: [InputModifier] = [
        .control, .shift, .alt, .windows
    ]

    private var heldKeys: [UInt16: UInt16] = [:]
    private var sentModifiers: Set<InputModifier> = []

    mutating func payloads(
        keyCode: UInt16,
        isDown: Bool,
        modifiers: Set<InputModifier>,
        smartMapping: Bool
    ) -> [InputPayload] {
        if !isDown {
            guard let usage = heldKeys.removeValue(forKey: keyCode) else { return [] }
            var payloads = [keyPayload(usage, isDown: false)]
            if heldKeys.isEmpty {
                payloads += releaseSentModifiers()
            }
            return payloads
        }

        if let usage = heldKeys[keyCode] {
            return [keyPayload(usage, isDown: true)]
        }
        guard let key = Self.keys[keyCode] else { return [] }

        let shortcut = Shortcut(key: key.logical, modifiers: modifiers)
        let translated = smartMapping
            ? WindowsShortcutMapper.translate(shortcut)
            : Shortcut(key: shortcut.key, modifiers: directModifiers(modifiers))
        let usage = translatedUsage(for: translated.key, fallback: key.usage)

        var payloads = syncModifiers(translated.modifiers)
        payloads.append(keyPayload(usage, isDown: true))
        heldKeys[keyCode] = usage
        return payloads
    }

    mutating func reset() {
        heldKeys.removeAll(keepingCapacity: true)
        sentModifiers.removeAll(keepingCapacity: true)
    }

    private mutating func syncModifiers(
        _ desired: Set<InputModifier>
    ) -> [InputPayload] {
        var payloads: [InputPayload] = []
        for modifier in Self.modifierOrder.reversed()
        where sentModifiers.contains(modifier) && !desired.contains(modifier) {
            payloads.append(keyPayload(Self.modifierUsage(modifier), isDown: false))
        }
        for modifier in Self.modifierOrder
        where desired.contains(modifier) && !sentModifiers.contains(modifier) {
            payloads.append(keyPayload(Self.modifierUsage(modifier), isDown: true))
        }
        sentModifiers = desired
        return payloads
    }

    private mutating func releaseSentModifiers() -> [InputPayload] {
        let payloads = Self.modifierOrder.reversed().compactMap { modifier in
            sentModifiers.contains(modifier)
                ? keyPayload(Self.modifierUsage(modifier), isDown: false)
                : nil
        }
        sentModifiers.removeAll(keepingCapacity: true)
        return payloads
    }

    private func directModifiers(
        _ modifiers: Set<InputModifier>
    ) -> Set<InputModifier> {
        Set(modifiers.map {
            switch $0 {
            case .command: .windows
            case .option: .alt
            default: $0
            }
        })
    }

    private func translatedUsage(for key: LogicalKey, fallback: UInt16) -> UInt16 {
        switch key {
        case .home: 0x4A
        case .end: 0x4D
        default: fallback
        }
    }

    private static func modifierUsage(_ modifier: InputModifier) -> UInt16 {
        switch modifier {
        case .control: 0xE0
        case .shift: 0xE1
        case .alt, .option: 0xE2
        case .windows, .command: 0xE3
        }
    }

    private func keyPayload(_ usage: UInt16, isDown: Bool) -> InputPayload {
        .key(.init(usbHIDUsage: usage, isDown: isDown))
    }

    private static let keys: [UInt16: (logical: LogicalKey, usage: UInt16)] = [
        0: (.letter("a"), 0x04), 1: (.letter("s"), 0x16),
        2: (.letter("d"), 0x07), 3: (.letter("f"), 0x09),
        4: (.letter("h"), 0x0B), 5: (.letter("g"), 0x0A),
        6: (.letter("z"), 0x1D), 7: (.letter("x"), 0x1B),
        8: (.letter("c"), 0x06), 9: (.letter("v"), 0x19),
        11: (.letter("b"), 0x05), 12: (.letter("q"), 0x14),
        13: (.letter("w"), 0x1A), 14: (.letter("e"), 0x08),
        15: (.letter("r"), 0x15), 16: (.letter("y"), 0x1C),
        17: (.letter("t"), 0x17), 18: (.other("1"), 0x1E),
        19: (.other("2"), 0x1F), 20: (.other("3"), 0x20),
        21: (.other("4"), 0x21), 22: (.other("6"), 0x23),
        23: (.other("5"), 0x22), 24: (.other("="), 0x2E),
        25: (.other("9"), 0x26), 26: (.other("7"), 0x24),
        27: (.other("-"), 0x2D), 28: (.other("8"), 0x25),
        29: (.other("0"), 0x27), 30: (.other("]"), 0x30),
        31: (.letter("o"), 0x12), 32: (.letter("u"), 0x18),
        33: (.other("["), 0x2F), 34: (.letter("i"), 0x0C),
        35: (.letter("p"), 0x13), 36: (.other("return"), 0x28),
        37: (.letter("l"), 0x0F), 38: (.letter("j"), 0x0D),
        39: (.other("'"), 0x34), 40: (.letter("k"), 0x0E),
        41: (.other(";"), 0x33), 42: (.other("\\"), 0x31),
        43: (.other(","), 0x36), 44: (.other("/"), 0x38),
        45: (.letter("n"), 0x11), 46: (.letter("m"), 0x10),
        47: (.other("."), 0x37), 48: (.tab, 0x2B),
        49: (.space, 0x2C), 50: (.other("`"), 0x35),
        51: (.other("backspace"), 0x2A), 53: (.other("escape"), 0x29),
        65: (.other("keypad-decimal"), 0x63),
        67: (.other("keypad-multiply"), 0x55), 69: (.other("keypad-plus"), 0x57),
        71: (.other("keypad-clear"), 0x53), 75: (.other("keypad-divide"), 0x54),
        76: (.other("keypad-enter"), 0x58), 78: (.other("keypad-minus"), 0x56),
        82: (.other("keypad-0"), 0x62), 83: (.other("keypad-1"), 0x59),
        84: (.other("keypad-2"), 0x5A), 85: (.other("keypad-3"), 0x5B),
        86: (.other("keypad-4"), 0x5C), 87: (.other("keypad-5"), 0x5D),
        88: (.other("keypad-6"), 0x5E), 89: (.other("keypad-7"), 0x5F),
        91: (.other("keypad-8"), 0x60), 92: (.other("keypad-9"), 0x61),
        96: (.other("f5"), 0x3E), 97: (.other("f6"), 0x3F),
        98: (.other("f7"), 0x40), 99: (.other("f3"), 0x3C),
        100: (.other("f8"), 0x41), 101: (.other("f9"), 0x42),
        103: (.other("f11"), 0x44), 109: (.other("f10"), 0x43),
        111: (.other("f12"), 0x45), 114: (.other("insert"), 0x49),
        115: (.home, 0x4A), 116: (.other("page-up"), 0x4B),
        117: (.other("delete"), 0x4C), 118: (.other("f4"), 0x3D),
        119: (.end, 0x4D), 120: (.other("f2"), 0x3B),
        121: (.other("page-down"), 0x4E), 122: (.other("f1"), 0x3A),
        123: (.leftArrow, 0x50), 124: (.rightArrow, 0x4F),
        125: (.downArrow, 0x51), 126: (.upArrow, 0x52)
    ]
}
