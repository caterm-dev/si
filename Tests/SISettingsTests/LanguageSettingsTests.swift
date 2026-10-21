import Foundation
import Testing
import SICore
@testable import SISettings

@MainActor
struct LanguageSettingsTests {
    @Test func automaticConfirmationIsOptInAndPersistsWithoutEnablingLearning() throws {
        let name = "SI.AutomaticConfirmationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults)
        #expect(!settings.automaticConfirmationEnabled)
        settings.automaticConfirmationEnabled = true
        let generation = settings.configurationGeneration
        settings.automaticConfirmationEnabled = false
        settings.automaticConfirmationEnabled = true
        #expect(settings.configurationGeneration == generation + 2)
        let restarted = LanguageSettings(defaults: defaults)
        #expect(restarted.automaticConfirmationEnabled)
        #expect(!PersonalizationSettings(defaults: defaults, isPreview: true).isEnabled)
    }

    @Test func punctuationChoicePersistsIndependentlyOfEnabledLanguages() throws {
        let name = "SI.LanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults)
        #expect(settings.punctuationBehavior == .asTyped)
        settings.chineseEnabled = false
        settings.punctuationBehavior = .smart
        let restarted = LanguageSettings(defaults: defaults)
        #expect(restarted.punctuationBehavior == .smart)
        #expect(!restarted.chineseEnabled && restarted.englishEnabled)
        defaults.set("unknown-future-value", forKey: LanguageSettings.punctuationKey)
        #expect(LanguageSettings(defaults: defaults).punctuationBehavior == .asTyped)
    }
}
