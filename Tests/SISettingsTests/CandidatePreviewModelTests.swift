import Foundation
import Testing
import SICore
@testable import SISettings

@MainActor
struct CandidatePreviewModelTests {
    @MainActor
    private final class Consent {
        var isCurrent = true
    }

    @Test func punctuationSettingRefreshesPreviewAndReplacesPendingResults() async throws {
        let model = CandidatePreviewModel()
        let enabled = query(",", punctuationCandidatesEnabled: true)
        let disabled = query(",")
        #expect(enabled != disabled)
        model.submit(enabled, isCurrent: { true })
        await Task.yield()
        model.submit(disabled, isCurrent: { true })
        try await settle(model)
        #expect(model.candidates.count == 1 && model.candidates.first?.text == ",")
        #expect(model.candidates.first?.isPunctuation == false)
        model.submit(enabled, isCurrent: { true })
        try await settle(model)
        #expect(model.candidates.contains { $0.text == "，" && $0.punctuationLanguage == .simplifiedChinese })
        #expect(model.candidates.last?.isPunctuation == true)
        model.submit(disabled, isCurrent: { true })
        try await settle(model)
        #expect(model.candidates.count == 1 && model.candidates.first?.isPunctuation == false)
    }

    @Test func latestInputAndLanguageConfigurationReplacePendingResults() async throws {
        let model = CandidatePreviewModel()
        model.submit(query("ne"), isCurrent: { true })
        await Task.yield()
        model.submit(query("ExactIdentifier", languages: []), isCurrent: { true })
        try await settle(model)
        #expect(model.candidates.count == 1)
        #expect(model.candidates.first?.text == "ExactIdentifier")
        #expect(model.candidates.first?.isLiteral == true)
    }

    @Test func consentIsCheckedAgainWhenTheWorkerDelivers() async throws {
        let model = CandidatePreviewModel()
        let consent = Consent()
        model.submit(query("ne"), isCurrent: { consent.isCurrent })
        consent.isCurrent = false
        try await settle(model)
        #expect(model.candidates.isEmpty)
    }

    @Test func cancellationCannotRestoreOldResultsAfterReopening() async throws {
        let model = CandidatePreviewModel()
        model.submit(query("julitebieyuan"), isCurrent: { true })
        await Task.yield()
        model.cancel()
        #expect(model.candidates.isEmpty && !model.isSearching)
        model.submit(query("ne"), isCurrent: { true })
        try await settle(model)
        #expect(model.candidates.first?.text == "呢")
        #expect(model.candidates.last?.text == "ne" && model.candidates.last?.isLiteral == true)
    }

    private func query(_ input: String, languages: Set<InputLanguage> = [.simplifiedChinese],
                       punctuationCandidatesEnabled: Bool = false) -> CandidatePreviewQuery {
        CandidatePreviewQuery(input: input, languages: languages, learning: LearningProfile(), dictionary: UserDictionary(),
                              punctuationCandidatesEnabled: punctuationCandidatesEnabled)
    }

    private func settle(_ model: CandidatePreviewModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while model.isSearching && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isSearching)
    }
}
