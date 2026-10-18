import Observation
import Foundation

@MainActor
@Observable
final class LanguageSettings {
    static let shared = LanguageSettings()
    static let englishKey = "languages.english"
    static let chineseKey = "languages.simplifiedChinese"

    var englishEnabled: Bool {
        didSet { defaults.set(englishEnabled, forKey: Self.englishKey) }
    }
    var chineseEnabled: Bool {
        didSet { defaults.set(chineseEnabled, forKey: Self.chineseKey) }
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
    }
}
