import Foundation
import Testing
import SICore
@testable import SISettings

@MainActor
struct LanguageSettingsTests {
    @Test func productionRankingLoadsBundledModelWithoutAppSupportInstallation() async throws {
        guard let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_BUNDLE"] else { return }
        let name = "SI.BundledRankingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await settings.startRankingModel(at: missing, bundledAt: URL(fileURLWithPath: path))
        let model = try #require(settings.productionRanking.model)
        #expect(settings.configurationGeneration == 1)
        let index = try #require(model.wordIndex("你好")?.index)
        let score = try #require(model.advance(model.beginSentence(), wordIndex: index))
        #expect(score.log10.isFinite)
    }

    @Test func productionRankingReplacesDevelopmentPreferencesAndLoadsVerifiedModelOnce() async throws {
        let name = "SI.ProductionRankingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "development.kenLMRanking")
        defaults.set(false, forKey: "development.fullCoverageFirst")
        let settings = LanguageSettings(defaults: defaults)
        let fallback = settings.productionRanking
        #expect(fallback.fullCoverageFirst && fallback.englishWordInsertionBits == 28)
        #expect(fallback.languageModelWeight == 0.25 && fallback.wordInsertionBits == 28.85)
        #expect(fallback.englishLanguageModelWeight == 0 && fallback.frequencyWeight == 1)
        #expect(fallback.model == nil)
        #expect(defaults.object(forKey: "development.kenLMRanking") == nil)
        #expect(defaults.object(forKey: "development.fullCoverageFirst") == nil)
        let generation = settings.configurationGeneration
        if let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_INSTALLATION"] {
            let root = URL(fileURLWithPath: path)
            await settings.startRankingModel(at: root)
            let model = try #require(settings.productionRanking.model)
            #expect(settings.configurationGeneration == generation + 1)
            await settings.startRankingModel(at: root)
            #expect(settings.productionRanking.model === model)
            #expect(settings.configurationGeneration == generation + 1)
        } else {
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            await settings.startRankingModel(at: missing)
            #expect(settings.productionRanking == fallback)
            #expect(settings.configurationGeneration == generation)
        }
    }

    @Test func languageSwitchesPersistIndependentlyWithoutChangingDirectInputOrConsent() throws {
        let name = "SI.LanguageSwitchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults)
        settings.setPassthrough(true, for: "com.example.Terminal")
        for (english, chinese) in [(false, true), (false, false), (true, false), (true, true)] {
            let generation = settings.configurationGeneration
            settings.englishEnabled = english
            settings.chineseEnabled = chinese
            #expect(settings.configurationGeneration == generation + 1)
            let restored = LanguageSettings(defaults: defaults)
            #expect(restored.englishEnabled == english && restored.chineseEnabled == chinese)
            #expect(restored.enabledLanguages.contains(.english) == english)
            #expect(restored.enabledLanguages.contains(.simplifiedChinese) == chinese)
            #expect(restored.usesPassthrough(in: "com.example.Terminal"))
            #expect(!defaults.bool(forKey: "applicationMemory.vocabularyEnabled"))
            #expect(!defaults.bool(forKey: "inputHistory.enabled"))
        }
    }

    @Test func retiredAIPreferencesAreRemovedWithoutChangingLanguagesDirectInputOrConsent() throws {
        for enabled in [false, true] {
            let name = "SI.RetiredAISettingsTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(enabled, forKey: "typing.aiComparison")
            defaults.set(enabled, forKey: "typing.aiContext")
            defaults.set(0.4, forKey: "typing.aiWeight")
            defaults.set(false, forKey: LanguageSettings.englishKey)
            defaults.set(true, forKey: LanguageSettings.chineseKey)
            defaults.set(["com.example.Terminal"], forKey: LanguageSettings.passthroughApplicationsKey)
            defaults.set(enabled, forKey: "applicationMemory.vocabularyEnabled")
            defaults.set(enabled, forKey: "inputHistory.enabled")

            for _ in 0..<2 {
                let settings = LanguageSettings(defaults: defaults)
                for key in ["typing.aiComparison", "typing.aiContext", "typing.aiWeight"] {
                    #expect(defaults.object(forKey: key) == nil)
                }
                #expect(settings.enabledLanguages == [.simplifiedChinese])
                #expect(settings.usesPassthrough(in: "com.example.Terminal"))
                #expect(defaults.bool(forKey: "applicationMemory.vocabularyEnabled") == enabled)
                #expect(defaults.bool(forKey: "inputHistory.enabled") == enabled)
            }
        }
    }

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
        #expect(!appMemory.vocabularyEnabled)
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
        #expect(!appMemory.vocabularyEnabled)
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
        #expect(!appMemory.vocabularyEnabled)
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
