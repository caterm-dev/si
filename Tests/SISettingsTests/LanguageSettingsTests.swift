import Foundation
import Testing
import SICore
@testable import SISettings

@MainActor
struct LanguageSettingsTests {
    @Test func directInputIsOptInPerApplicationAndSurvivesRestart() throws {
        let name = "SI.DirectInputSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults)
        let terminal = "com.example.Terminal"
        let browser = "com.example.Browser"
        #expect(settings.passthroughApplications.isEmpty)
        #expect(!settings.usesPassthrough(in: nil))
        #expect(!settings.usesPassthrough(in: terminal))
        settings.setPassthrough(true, for: terminal)
        #expect(settings.usesPassthrough(in: terminal))
        #expect(!settings.usesPassthrough(in: browser))
        #expect(settings.englishEnabled && settings.chineseEnabled)
        let restarted = LanguageSettings(defaults: defaults)
        #expect(restarted.usesPassthrough(in: terminal))
        #expect(!restarted.usesPassthrough(in: browser))
        settings.setPassthrough(false, for: terminal)
        #expect(!LanguageSettings(defaults: defaults).usesPassthrough(in: terminal))
        let appMemory = ApplicationMemorySettings(defaults: defaults, isPreview: true)
        #expect(!appMemory.vocabularyEnabled && !appMemory.historyEnabled)
    }

    @Test func directInputChangesInvalidateConfigurationWithoutChangingLanguagePreferences() throws {
        let name = "SI.DirectInputGenerationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults)
        settings.chineseEnabled = false
        let generation = settings.configurationGeneration
        settings.setPassthrough(true, for: "com.example.Terminal")
        settings.setPassthrough(true, for: "com.example.Terminal")
        settings.setPassthrough(true, for: "")
        #expect(settings.configurationGeneration == generation + 1)
        settings.setPassthrough(false, for: "com.example.Terminal")
        #expect(settings.configurationGeneration == generation + 2)
        #expect(settings.englishEnabled && !settings.chineseEnabled)
        #expect(settings.passthroughApplications.isEmpty)
    }

    @Test func punctuationCandidatesDefaultOffAndPersistIndependently() throws {
        let name = "SI.PunctuationCandidateSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults)
        #expect(!settings.punctuationCandidatesEnabled)
        settings.punctuationBehavior = .smart
        settings.englishEnabled = false
        #expect(!settings.punctuationCandidatesEnabled)
        settings.punctuationCandidatesEnabled = true
        let generation = settings.configurationGeneration
        let restarted = LanguageSettings(defaults: defaults)
        #expect(restarted.punctuationCandidatesEnabled)
        #expect(restarted.punctuationBehavior == .smart && !restarted.englishEnabled)
        settings.punctuationCandidatesEnabled = false
        settings.punctuationCandidatesEnabled = true
        #expect(settings.configurationGeneration == generation + 2)
        settings.punctuationCandidatesEnabled = false
        #expect(!LanguageSettings(defaults: defaults).punctuationCandidatesEnabled)
        let appMemory = ApplicationMemorySettings(defaults: defaults, isPreview: true)
        #expect(!appMemory.vocabularyEnabled && !appMemory.historyEnabled)
    }

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
        let appMemory = ApplicationMemorySettings(defaults: defaults, isPreview: true)
        #expect(!appMemory.vocabularyEnabled && !appMemory.historyEnabled)
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
