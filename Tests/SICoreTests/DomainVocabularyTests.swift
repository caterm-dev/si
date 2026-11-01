import Testing
@testable import SICore

struct DomainVocabularyTests {
    @Test func domainLookupUsesLiteralDotsHyphensAndDigits() {
        let provider = EnglishCandidateProvider()
        for domain in ["google.com", "github.com", "python.org", "rust-lang.org", "mail.163.com"] {
            #expect(EnglishLexicon.reading(for: domain) == domain)
            #expect(provider.candidates(for: domain).contains {
                $0.text == domain && !$0.hasCompletion && $0.language == .english
            })
            #expect(provider.candidates(for: domain.uppercased()).contains {
                $0.text == domain.uppercased() && !$0.hasCompletion
            })
        }
        #expect(provider.candidates(for: "github.").contains { $0.text == "github.com" && $0.hasCompletion })
        #expect(provider.candidates(for: "mail.16").contains { $0.text == "mail.163.com" && $0.hasCompletion })
        for suffix in [".ai", ".com", ".org", ".co.uk"] {
            #expect(provider.candidates(for: suffix).isEmpty)
        }
        #expect(!provider.candidates(for: "googlecom").contains { $0.text == "google.com" })
        #expect(provider.candidates(for: "WORLD").first?.text == "WORLD")
    }

    @Test func domainCandidatesRespectLanguageSettingsAndExactLiteralInput() {
        let engine = CandidateEngine()
        let input = "google.com"
        for languages: Set<InputLanguage> in [[.english], Set(InputLanguage.allCases)] {
            let values = engine.candidates(for: input, languages: languages)
            #expect(values.contains { $0.text == input && $0.language == .english && !$0.hasCompletion })
            #expect(values.last?.text == input && values.last?.isLiteral == true)
            #expect(values.map(\.id) == engine.candidates(for: input, languages: languages).map(\.id))
            let preview = engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                dictionary: UserDictionary(), now: .now, context: nil)
            #expect(preview.contains { $0.text == input && $0.language == .english && !$0.hasCompletion })
            #expect(preview.last?.text == input && preview.last?.isLiteral == true)
        }
        for languages: Set<InputLanguage> in [[], [.simplifiedChinese]] {
            let values = engine.candidates(for: input, languages: languages)
            #expect(!values.contains { $0.text == input && $0.language == .english })
            #expect(values.last?.text == input && values.last?.isLiteral == true)
        }
        for input in [".ai", "private-host.example", "MyHost.internal"] {
            let values = engine.candidates(for: input, languages: Set(InputLanguage.allCases))
            #expect(values.last?.text == input && values.last?.isLiteral == true)
        }
    }

    @Test func domainValidationRejectsSuffixesInvalidLabelsAndNonASCII() {
        for text in [".ai", "google..com", "-host.com", "host-.com", "host.com/", "host.123", "café.com", "K.org"] {
            #expect(EnglishLexicon.domainReading(for: text) == nil)
        }
        #expect(EnglishLexicon.domainReading(for: "mail.163.com") == "mail.163.com")
        #expect(EnglishLexicon.domainReading(for: "163.com") == "163.com")
    }
}
