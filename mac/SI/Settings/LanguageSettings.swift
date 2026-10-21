import Observation
import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

@MainActor
@Observable
final class LanguageSettings {
    static let shared = LanguageSettings(defaults: SettingsDefaults.shared)
    static let englishKey = "languages.english"
    static let chineseKey = "languages.simplifiedChinese"
    static let punctuationKey = "typing.punctuationBehavior"
    static let automaticConfirmationKey = "typing.automaticConfirmation"
    private(set) var configurationGeneration: UInt64 = 0

    var automaticConfirmationEnabled: Bool {
        didSet {
            defaults.set(automaticConfirmationEnabled, forKey: Self.automaticConfirmationKey)
            if oldValue != automaticConfirmationEnabled { configurationGeneration &+= 1 }
        }
    }

    var punctuationBehavior: PunctuationBehavior {
        didSet {
            defaults.set(punctuationBehavior.rawValue, forKey: Self.punctuationKey)
            if oldValue != punctuationBehavior { configurationGeneration &+= 1 }
        }
    }

    var englishEnabled: Bool {
        didSet {
            defaults.set(englishEnabled, forKey: Self.englishKey)
            if oldValue != englishEnabled { configurationGeneration &+= 1 }
        }
    }
    var chineseEnabled: Bool {
        didSet {
            defaults.set(chineseEnabled, forKey: Self.chineseKey)
            if oldValue != chineseEnabled { configurationGeneration &+= 1 }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    var enabledLanguages: Set<InputLanguage> {
        var languages = Set<InputLanguage>()
        if englishEnabled { languages.insert(.english) }
        if chineseEnabled { languages.insert(.simplifiedChinese) }
        return languages
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.englishKey: true, Self.chineseKey: true])
        englishEnabled = defaults.bool(forKey: Self.englishKey)
        chineseEnabled = defaults.bool(forKey: Self.chineseKey)
        automaticConfirmationEnabled = defaults.bool(forKey: Self.automaticConfirmationKey)
        if let saved = defaults.string(forKey: Self.punctuationKey) {
            punctuationBehavior = PunctuationBehavior(rawValue: saved) ?? .asTyped
        } else {
            punctuationBehavior = .asTyped
        }
    }
}
