import Foundation
import Testing
@testable import SICore

struct UserDictionaryTests {
    @Test func preferredFullCodeRemainsAnExplicitOverrideAfterStatisticalScoring() throws {
        let phrase = try UserPhrase(input: "he", text: "Synthetic preferred output", language: .english, isPinned: true)
        let dictionary = try UserDictionary(entries: [phrase])
        let learned = InputCandidate(text: "he", language: .english, score: 100)
        var profile = LearningProfile()
        for _ in 0..<8 { profile.record(InputCommit(input: "he", candidate: learned, reason: .explicitSelection)) }
        let engine = CandidateEngine()
        for values in [engine.candidates(for: "he", languages: Set(InputLanguage.allCases), learning: profile, dictionary: dictionary),
                       engine.previewCandidates(for: "he", languages: Set(InputLanguage.allCases), learning: profile,
                                                dictionary: dictionary, now: .now, context: nil)] {
            #expect(values.first?.text == phrase.text)
            #expect(values.first?.isPreferred == true)
            #expect(values.first?.canLearn == false)
        }
        #expect(!dictionary.candidates(for: "h", languages: [.english]).contains { $0.isPreferred })
    }

    @Test func addingAnIdenticalPersonalPhraseDoesNotDiscardStrongerExistingLearning() throws {
        let candidate = InputCandidate(text: "he", language: .english, score: 110)
        var profile = LearningProfile()
        for _ in 0..<4 { profile.record(InputCommit(input: "he", candidate: candidate, reason: .explicitSelection)) }
        let dictionary = try UserDictionary(entries: [
            UserPhrase(input: "he", text: "he", language: .english),
            UserPhrase(input: "he", text: "HELLO", language: .english),
        ])
        let candidates = CandidateEngine().candidates(for: "he", languages: Set(InputLanguage.allCases),
                                                     learning: profile, dictionary: dictionary)
        #expect(candidates.first?.text == "he")
        #expect(candidates.count(where: { $0.text == "he" && !$0.isLiteral }) == 1)
    }

    @Test func phrasesWorkWithLearningOffAndRespectEnabledLanguages() throws {
        let phrase = try UserPhrase(input: "xm", text: "项目代号", language: .simplifiedChinese)
        let dictionary = try UserDictionary(entries: [phrase])
        let engine = CandidateEngine()
        let candidates = engine.candidates(for: "xm", languages: [.english, .simplifiedChinese], dictionary: dictionary)
        #expect(candidates.first?.text == "项目代号")
        #expect(candidates.first?.isUserPhrase == true)
        #expect(candidates.last?.text == "xm")
        #expect(candidates.last?.isLiteral == true)
        #expect(!engine.candidates(for: "xm", languages: [.english], dictionary: dictionary).contains { $0.isUserPhrase })
        #expect(engine.candidates(for: "xm", languages: [], dictionary: dictionary).count == 1)
    }

    @Test func pinAndDuplicateDerivationsPreserveAllAlternatives() throws {
        let phrase = try UserPhrase(input: "he", text: "he", language: .english, isPinned: true)
        let dictionary = try UserDictionary(entries: [phrase])
        let candidates = CandidateEngine().candidates(for: "he", languages: Set(InputLanguage.allCases), dictionary: dictionary)
        #expect(candidates.first?.text == "he")
        #expect(candidates.first?.isUserPhrase == true)
        #expect(candidates.first?.isUserPhrase == true)
        #expect(candidates.count(where: { $0.text == "he" && $0.language == .english }) == 1)
        #expect(candidates.contains { $0.text == "和" })
        #expect(candidates.last?.isLiteral == true)
    }

    @Test func outputIsExactAndLanguageIsExplicitRatherThanGuessedFromScript() throws {
        let text = "iPhone 👩🏽‍💻"
        let phrase = try UserPhrase(input: " IP ", text: text, language: .simplifiedChinese)
        let dictionary = try UserDictionary(entries: [phrase])
        #expect(phrase.input == "ip")
        let candidate = try #require(dictionary.candidates(for: "IP", languages: [.simplifiedChinese]).first)
        #expect(candidate.text == text)
        #expect(!candidate.isMixed)
        #expect(candidate.language == .simplifiedChinese)
        let mixed = InputCandidate(text: text, language: .simplifiedChinese, score: 90, isMixed: true)
        #expect(candidate.id != mixed.id)
    }

    @Test func manualPhrasesDoNotDuplicateTheirTextInLearningRecords() throws {
        let phrase = try UserPhrase(input: "sig", text: "Synthetic Test Name", language: .english)
        let candidate = try #require(UserDictionary(entries: [phrase]).candidates(for: "sig", languages: [.english]).first)
        var profile = LearningProfile()
        let learned = profile.record(InputCommit(input: "sig", candidate: candidate, reason: .explicitSelection))
        #expect(!learned)
        #expect(profile.entries.isEmpty)
        #expect(profile.bonus(for: candidate, input: "sig") == 0)
    }

    @Test func editsAndDeletesRefreshCompositionAndRejectRemovedSelection() throws {
        let phrase = try UserPhrase(input: "xm", text: "项目代号", language: .simplifiedChinese)
        var dictionary = try UserDictionary(entries: [phrase])
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese], dictionary: dictionary)
        session.append("xm")
        let old = try #require(session.candidates.first)
        dictionary.remove(id: phrase.id)
        session.configure(languages: [.simplifiedChinese], dictionary: dictionary)
        #expect(session.candidates.allSatisfy { !$0.isUserPhrase })
        #expect(session.commit(old) == "xm")
        try dictionary.upsert(UserPhrase(id: phrase.id, input: "xm", text: "新项目", language: .simplifiedChinese))
        #expect(dictionary.entries.count == 1)
        #expect(dictionary.entries.first?.id == phrase.id)
        #expect(dictionary.entries.first?.text == "新项目")
    }

    @Test func validationRejectsUnreachableCodesAndControlText() {
        for input in ["", "'hi", "hi'", "n''h", "x1", "你好", String(repeating: "a", count: 65)] {
            #expect(throws: UserPhrase.ValidationError.invalidInput) {
                try UserPhrase(input: input, text: "test", language: .english)
            }
        }
        for text in ["", "  ", "line\nbreak", "tab\t", "zero\u{0}", String(repeating: "a", count: 1_025)] {
            #expect(throws: UserPhrase.ValidationError.invalidText) {
                try UserPhrase(input: "test", text: text, language: .english)
            }
        }
    }

    @Test func mergeIsAdditiveDeduplicatedAndPreservesLocalPins() throws {
        let local = try UserPhrase(input: "xm", text: "项目", language: .simplifiedChinese, isPinned: true)
        var dictionary = try UserDictionary(entries: [local])
        let duplicate = try UserPhrase(input: "xm", text: "项目", language: .simplifiedChinese)
        let collidingID = try UserPhrase(id: local.id, input: "sig", text: "Synthetic Name", language: .english)
        let imported = try UserDictionary(entries: [duplicate, collidingID])
        let added = try dictionary.merge(imported)
        #expect(added == 1)
        #expect(dictionary.entries.count == 2)
        #expect(dictionary.entries.first { $0.text == "项目" }?.isPinned == true)
        #expect(Set(dictionary.entries.map(\.id)).count == 2)
        #expect(dictionary.entries.first { $0.text == "Synthetic Name" }?.id != local.id)
    }

    @Test func exceedingCapacityLeavesTheWholeImportUnapplied() throws {
        let entries = try (0..<UserDictionary.maximumEntries).map {
            try UserPhrase(input: "test", text: "synthetic\($0)", language: .english)
        }
        var dictionary = try UserDictionary(entries: entries)
        let original = dictionary
        let imported = try UserDictionary(entries: [UserPhrase(input: "new", text: "new", language: .english)])
        #expect(throws: UserDictionary.DictionaryError.capacityExceeded) { try dictionary.merge(imported) }
        #expect(dictionary == original)
        #expect(throws: UserDictionary.DictionaryError.duplicatePhrase) {
            try UserDictionary(entries: [entries[0], UserPhrase(input: "test", text: "synthetic0", language: .english)])
        }
    }

    @Test func archiveRoundTripAndInvalidPayloadValidation() throws {
        let phrase = try UserPhrase(input: "lv", text: "绿色", language: .simplifiedChinese, isPinned: true)
        let dictionary = try UserDictionary(entries: [phrase])
        let data = try UserDictionaryArchive.encode(dictionary)
        #expect(try UserDictionaryArchive.decode(data) == dictionary)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 999
        let unsupported = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: UserDictionaryArchive.ArchiveError.unsupportedFormat) { try UserDictionaryArchive.decode(unsupported) }
        json["version"] = 1
        var rows = try #require(json["entries"] as? [[String: Any]])
        rows[0]["input"] = "bad123"
        json["entries"] = rows
        let invalid = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: UserPhrase.ValidationError.invalidInput) { try UserDictionaryArchive.decode(invalid) }
        #expect(throws: UserDictionaryArchive.ArchiveError.tooLarge) {
            try UserDictionaryArchive.decode(Data(repeating: 0, count: UserDictionaryArchive.maximumBytes + 1))
        }
    }
}
