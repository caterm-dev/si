import AppKit

/// Physical key identity; modifiers ignore Caps Lock and keyboard bookkeeping flags.
struct DirectInputShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt
    let keyLabel: String

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    static let `default` = Self(keyCode: 34, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyLabel: "I")

    var isValid: Bool {
        keyCode < 128 && !keyLabel.isEmpty && keyLabel.utf8.count <= 32
            && modifiers & ~Self.relevantModifiers.rawValue == 0
            && !NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .control, .option]).isEmpty
    }

    var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + keyLabel
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers.intersection(Self.relevantModifiers).rawValue
    }

    static func recording(_ event: NSEvent) -> Self? {
        guard !event.isARepeat, let text = event.characters(byApplyingModifiers: []),
              text.count == 1, let scalar = text.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), !(0xF700...0xF8FF).contains(scalar.value),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let shortcut = Self(keyCode: event.keyCode,
                            modifiers: event.modifierFlags.intersection(relevantModifiers).rawValue,
                            keyLabel: text.uppercased())
        return shortcut.isValid ? shortcut : nil
    }
}
