import Foundation
import Testing
@testable import SICore

struct EnglishVocabularyTests {
    private static let database = LexiconDatabase(url:
        DictionaryResources.url("si-english", extension: "sqlite", languageDirectory: "English"))
    private static let rows = database.allEntries().sorted {
        if $0.key != $1.key { return $0.key < $1.key }
        return $0.weight == $1.weight ? $0.ordinal < $1.ordinal : $0.weight > $1.weight
    }
    private static let words = rows.map(\.text)
    private static let keys = Dictionary(uniqueKeysWithValues: rows.map { ($0.text, $0.key) })
    private static let weights = Dictionary(uniqueKeysWithValues: rows.map { ($0.text, Double(max(1, $0.weight))) })

    private func referenceScore(_ word: String, input: String) -> Double {
        let lexicalScore = (1.05 * log(Self.weights[word]!) - 20) / log(2.0) - 1
        let length = Self.keys[word]!.utf8.count
        let missing = length - input.lowercased().utf8.count
        let normalizer = 16 + (1 - exp2(-Double(length - 1)))
        let channel = (missing == 0 ? 16 : exp2(-Double(missing))) / normalizer
        return lexicalScore + log2(channel)
    }

    @Test func technologySourcesProvideCanonicalExactWordsCompletionsAndMixedTokens() {
        let engine = CandidateEngine()
        for (input, expected) in [("gmail", "gmail"), ("GMAIL", "GMAIL"), ("github", "GitHub"),
                                  ("openai", "OpenAI"), ("chatgpt", "ChatGPT"), ("wechat", "WeChat"),
                                  ("iphone", "iPhone"), ("kubernetes", "Kubernetes")] {
            let result = engine.candidates(for: input, languages: [.english])
            #expect(result.contains { $0.text == expected && $0.language == .english && !$0.hasCompletion })
            #expect(result.last?.text == input && result.last?.isLiteral == true)
        }
        let completion = EnglishCandidateProvider().candidates(for: "gm")
        #expect(completion.contains { $0.text == "gmail" && $0.hasCompletion && $0.rankingScore.isFinite })
        for (input, expected) in [("nihaogmail", "你好 gmail"), ("nihaoGMAIL", "你好 GMAIL")] {
            let result = engine.candidates(for: input, languages: Set(InputLanguage.allCases))
            #expect(result.contains { $0.text == expected && $0.isMixed && !$0.isPartial && !$0.hasLiteralSegments })
            #expect(result.last?.text == input && result.last?.isLiteral == true)
        }
        for languages: Set<InputLanguage> in [[], [.simplifiedChinese]] {
            let result = engine.candidates(for: "gmail", languages: languages)
            #expect(!result.contains { $0.language == .english || $0.isMixed })
            #expect(result.last?.text == "gmail" && result.last?.isLiteral == true)
        }
        for word in ["may", "can", "will"] {
            #expect(EnglishCandidateProvider().candidates(for: word).contains { $0.text == word && !$0.hasCompletion })
        }
    }

    @Test func directLookupPreservesReferenceCandidatesAndMetadata() {
        let provider = EnglishCandidateProvider()
        for input in ["a", "I", "he", "sub", "SUB", "Sub", "sUb", "swift", "SwiftUI", "SWIFTUI",
                      "subtitle", "google.com", "github.", "mail.16", "rust-lang.org", "zzzzzz", "", "a1", "a'b", "é", "👩🏽‍💻", "K"] {
            let key = input.lowercased()
            let supported = !key.isEmpty && key.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
            let expected: [InputCandidate] = supported ? Self.rows.filter { $0.key.hasPrefix(key) }.map(\.text).map { word in
                let text: String
                if input == input.uppercased() { text = word.uppercased() }
                else if input.first?.isUppercase == true { text = word.prefix(1).uppercased() + word.dropFirst() }
                else { text = word }
                let exact = Self.keys[word] == key
                return InputCandidate(text: text, language: .english,
                                      score: Int(referenceScore(word, input: input)), rankingScore: referenceScore(word, input: input),
                                      hasCompletion: !exact, lexicalTokenCount: 1)
            } : []
            let actual = provider.candidates(for: input)
            #expect(actual.map(\.id) == expected.map(\.id))
            #expect(actual.map(\.hasCompletion) == expected.map(\.hasCompletion))
            for (a, e) in zip(actual, expected) { #expect(abs(a.rankingScore - e.rankingScore) < 1e-10) }
        }
    }

    @Test func everyWordHasExactTrieMetadataAndEveryPrefixKeepsItsFullRange() {
        let words = Self.words
        var prefixRanges: [String: Range<Int>] = [:]
        for (index, word) in words.enumerated() {
            let key = Self.keys[word]!
            var node = 0
            for byte in key.utf8 {
                guard let next = EnglishLexicon.advance(node, byte: byte) else {
                    Issue.record("Missing trie path for a vocabulary entry")
                    return
                }
                node = next
            }
            guard let entry = EnglishLexicon.exactMatches(at: node).first(where: { $0.text == word }) else {
                Issue.record("Missing exact vocabulary entry")
                return
            }
            #expect(entry.text == word)
            #expect(entry.length == key.utf8.count)
            #expect(entry.probability > 0 && entry.probability < 1)
            #expect(entry.cost(typedLength: key.count).isFinite)
            #expect(entry.text(for: .uppercase) == word.uppercased())
            #expect(entry.text(for: .capitalized) == word.prefix(1).uppercased() + word.dropFirst())
            for length in 1...key.count {
                let prefix = String(key.prefix(length))
                prefixRanges[prefix] = (prefixRanges[prefix]?.lowerBound ?? index)..<(index + 1)
            }
        }
        for (prefix, range) in prefixRanges {
            #expect(EnglishLexicon.matches(for: prefix).map(\.text) == Array(words[range]))
        }
    }

    @Test func mixedTrieWalkRespectsEnglishBoundariesCaseAndCompletionMinimum() {
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好", score: 100)])
        let languages = Set(InputLanguage.allCases)
        for input in ["nihaoSwiftUI", "nihao'SwiftUI"] {
            #expect(decoder.compositionCandidates(for: input, languages: languages, allowsVerbatim: false)
                .contains { $0.text == "你好 SwiftUI" && $0.isMixed && !$0.hasCompletion && !$0.isPartial })
        }
        #expect(!decoder.compositionCandidates(for: "nihaoswi'ftui", languages: languages, allowsVerbatim: false)
            .contains { $0.text == "你好 SwiftUI" && !$0.isPartial })
        #expect(decoder.compositionCandidates(for: "nihaoSWI'", languages: languages, allowsVerbatim: false)
            .contains { $0.text == "你好 SWIFT" && $0.hasCompletion && !$0.isPartial })
        #expect(!decoder.compositionCandidates(for: "nihaow", languages: languages, allowsVerbatim: false)
            .contains { $0.text == "你好 world" && !$0.isPartial })
    }

    @Test func lowFrequencyTechnologyCompletionsRemainAvailableThroughDirectLookup() {
        // Mixed paths are bounded; an absent corpus term need not enter their top twelve.
        #expect(EnglishCandidateProvider().candidates(for: "SWI").contains { $0.text == "SWIFTUI" && $0.hasCompletion })
    }

    @Test func trieCompletionsExcludeExactTerminalsAndKeepLexicalOrder() {
        for prefix in ["a", "he", "sub", "subtit", "subtitle", "swiftui", "z"] {
            var node = 0
            for byte in prefix.utf8 {
                guard let next = EnglishLexicon.advance(node, byte: byte) else {
                    Issue.record("Missing test prefix")
                    return
                }
                node = next
            }
            let expected = Self.words.filter {
                Self.keys[$0]!.hasPrefix(prefix) && Self.keys[$0] != prefix
            }
            #expect(EnglishLexicon.completions(at: node).map(\.text) == expected)
        }
        for byte: UInt8 in [0, 65, 96, 123, 255] {
            #expect(EnglishLexicon.advance(0, byte: byte) == nil)
        }
    }

    @Test func expandedWordsAndTerminologyAreAvailableWithCaseAndLiteralPreserved() {
        let engine = CandidateEngine()
        for input in ["subtitle", "subtitles", "SUBTITLE", "Subtitle", "SwiftUI", "abandon"] {
            let result = engine.candidates(for: input, languages: [.english])
            #expect(result.contains { $0.text == input && $0.language == .english && !$0.hasCompletion })
            #expect(result.last?.text == input && result.last?.isLiteral == true)
        }
        #expect(!engine.candidates(for: "subtitle", languages: [.simplifiedChinese])
            .contains { $0.language == .english })
    }

    @Test func indexedPrefixesKeepEveryMatchingWordIncludingLargeResultSets() {
        let provider = EnglishCandidateProvider()
        for prefix in ["a", "sub", "wor", "z", "zzzz", ""] {
            let expected = prefix.isEmpty ? [] : EnglishLexicon.entries.filter { $0.key.hasPrefix(prefix) }.map(\.text)
            #expect(provider.candidates(for: prefix).map(\.text) == expected)
        }
        #expect(provider.candidates(for: "a").count > 100)
        #expect(provider.candidates(for: "sub").contains { $0.text == "subtitle" && $0.hasCompletion })
        #expect(provider.candidates(for: "sub").contains { $0.text == "subtitles" && $0.hasCompletion })
    }

    @Test func originalCompletionsRemainAvailableInsideExpandedMixedSearch() {
        let engine = CandidateEngine()
        let languages = Set(InputLanguage.allCases)
        #expect(engine.candidates(for: "nihaowor", languages: languages)
            .contains { $0.text == "你好 world" && !$0.isPartial && $0.hasCompletion })
        #expect(engine.candidates(for: "nihaosubtitle", languages: languages)
            .contains { $0.text == "你好 subtitle" && $0.isMixed && !$0.hasLiteralSegments })
        #expect(engine.candidates(for: "shi", languages: languages).contains { $0.text == "是" })
        #expect(engine.candidates(for: "shi", languages: languages).contains { $0.text == "ship" })
    }
}
