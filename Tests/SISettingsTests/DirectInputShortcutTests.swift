import AppKit
import Foundation
import Testing
@testable import SISettings

@MainActor
struct DirectInputShortcutTests {
    @Test func defaultRequiresExactModifiersAndIgnoresCapsLock() {
        let shortcut = DirectInputShortcut.default
        #expect(shortcut.matches(keyCode: 34, modifiers: [.control, .shift]))
        #expect(shortcut.matches(keyCode: 34, modifiers: [.control, .shift, .capsLock]))
        #expect(!shortcut.matches(keyCode: 34, modifiers: [.control]))
        #expect(!shortcut.matches(keyCode: 34, modifiers: [.shift]))
        #expect(!shortcut.matches(keyCode: 34, modifiers: [.control, .shift, .option]))
        #expect(!shortcut.matches(keyCode: 34, modifiers: [.control, .shift, .command]))
        #expect(!shortcut.matches(keyCode: 40, modifiers: [.control, .shift]))
        #expect(!shortcut.matches(keyCode: 30, modifiers: [.control, .option]))
        #expect(shortcut.displayName == "⌃⇧I")
    }

    @Test func customShortcutAndAppTogglePersistWithoutChangingConsentOrLanguages() throws {
        let suite = "SI.ShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageSettings(defaults: defaults)
        #expect(settings.directInputShortcut == .default)
        settings.directInputShortcut = DirectInputShortcut(keyCode: 40,
            modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyLabel: "K")
        #expect(!settings.togglePassthrough(for: nil))
        #expect(!settings.togglePassthrough(for: ""))
        let generation = settings.configurationGeneration
        #expect(settings.togglePassthrough(for: "org.example.editor"))
        let restored = LanguageSettings(defaults: defaults)
        #expect(restored.directInputShortcut == settings.directInputShortcut)
        #expect(restored.usesPassthrough(in: "org.example.editor"))
        #expect(!restored.usesPassthrough(in: "org.example.browser"))
        #expect(settings.configurationGeneration == generation + 1)
        #expect(settings.togglePassthrough(for: "org.example.editor"))
        #expect(!LanguageSettings(defaults: defaults).usesPassthrough(in: "org.example.editor"))
        #expect(settings.englishEnabled && settings.chineseEnabled)
        #expect(!defaults.bool(forKey: "applicationMemory.vocabularyEnabled"))
        #expect(!defaults.bool(forKey: "inputHistory.enabled"))
        settings.directInputShortcut = .default
        #expect(LanguageSettings(defaults: defaults).directInputShortcut == .default)
    }

    @Test func recordingRequiresModifiedPrintableKeyAndRejectsRepeats() throws {
        func event(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags, repeat repeated: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: repeated, keyCode: code))
        }
        #expect(DirectInputShortcut.recording(try event(40, "k", [])) == nil)
        #expect(DirectInputShortcut.recording(try event(40, "K", [.shift])) == nil)
        #expect(DirectInputShortcut.recording(try event(40, "k", [.control], repeat: true)) == nil)
        let shortcut = try #require(DirectInputShortcut.recording(try event(40, "k", [.control, .shift])))
        #expect(shortcut.matches(keyCode: 40, modifiers: [.control, .shift]))
    }

    @Test func malformedStoredShortcutFallsBackToDefault() throws {
        let suite = "SI.InvalidShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: LanguageSettings.directInputShortcutKey)
        #expect(LanguageSettings(defaults: defaults).directInputShortcut == .default)
        let invalid = DirectInputShortcut(keyCode: 30, modifiers: 0, keyLabel: "]")
        defaults.set(try JSONEncoder().encode(invalid), forKey: LanguageSettings.directInputShortcutKey)
        #expect(LanguageSettings(defaults: defaults).directInputShortcut == .default)
    }
}
