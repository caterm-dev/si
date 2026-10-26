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
    static let punctuationCandidatesKey = "typing.punctuationCandidates"
    static let automaticConfirmationKey = "typing.automaticConfirmation"
    static let passthroughApplicationsKey = "typing.passthroughApplications"
    private(set) var configurationGeneration: UInt64 = 0
    private(set) var passthroughApplications: Set<String>

    func usesPassthrough(in applicationID: String?) -> Bool {
        applicationID.map { passthroughApplications.contains($0) } ?? false
    }

    func setPassthrough(_ enabled: Bool, for applicationID: String) {
        guard !applicationID.isEmpty, usesPassthrough(in: applicationID) != enabled else { return }
        if enabled { passthroughApplications.insert(applicationID) }
        else { passthroughApplications.remove(applicationID) }
        defaults.set(passthroughApplications.sorted(), forKey: Self.passthroughApplicationsKey)
        configurationGeneration &+= 1
    }

    var punctuationCandidatesEnabled: Bool {
        didSet {
            defaults.set(punctuationCandidatesEnabled, forKey: Self.punctuationCandidatesKey)
            if oldValue != punctuationCandidatesEnabled { configurationGeneration &+= 1 }
        }
    }

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
        passthroughApplications = Set((defaults.stringArray(forKey: Self.passthroughApplicationsKey) ?? [])
            .filter { !$0.isEmpty })
        defaults.register(defaults: [Self.englishKey: true, Self.chineseKey: true])
        englishEnabled = defaults.bool(forKey: Self.englishKey)
        chineseEnabled = defaults.bool(forKey: Self.chineseKey)
        automaticConfirmationEnabled = defaults.bool(forKey: Self.automaticConfirmationKey)
        punctuationCandidatesEnabled = defaults.bool(forKey: Self.punctuationCandidatesKey)
        if let saved = defaults.string(forKey: Self.punctuationKey) {
            punctuationBehavior = PunctuationBehavior(rawValue: saved) ?? .asTyped
        } else {
            punctuationBehavior = .asTyped
        }
    }
}
