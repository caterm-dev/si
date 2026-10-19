import Testing
@testable import SICore

struct PinyinDecoderTests {
    private let decoder = PinyinDecoder.standard

    @Test func explicitApostropheConstrainsSyllableBoundaries() {
        let ambiguous = decoder.candidates(for: "xian").map(\.text)
        #expect(ambiguous.contains("先"))
        #expect(ambiguous.contains("西安"))
        let separated = decoder.candidates(for: "xi'an").map(\.text)
        #expect(separated.contains("西安"))
        #expect(!separated.contains("先"))
        #expect(decoder.candidates(for: "s'hi").isEmpty)
    }

    @Test func incompleteLastSyllableAndInitialsSuggestPhrases() {
        #expect(decoder.candidates(for: "niha").contains { $0.text == "你好" })
        #expect(decoder.candidates(for: "nh").contains { $0.text == "你好" })
        #expect(decoder.candidates(for: "srf").contains { $0.text == "输入法" })
        #expect(decoder.candidates(for: "ni'").contains { $0.text == "你好" })
    }

    @Test func combinesWordsNotStoredAsWholePhrases() {
        let tiny = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["ni"], text: "你"),
            PinyinLexiconEntry(syllables: ["hao"], text: "好"),
            PinyinLexiconEntry(syllables: ["ma"], text: "吗"),
        ])
        #expect(tiny.candidates(for: "nihaoma").contains { $0.text == "你好吗" })
        #expect(tiny.candidates(for: "ni'hao'ma").contains { $0.text == "你好吗" })
        #expect(decoder.candidates(for: "womenxuexizhongwen").contains { $0.text == "我们学习中文" })
    }

    @Test func normalizesCaseAndUmlautSpellings() {
        for input in ["lv", "lü", "lu:", "LÜ"] {
            #expect(decoder.candidates(for: input).contains { $0.text == "绿" })
        }
        #expect(decoder.candidates(for: "Ni'Hao").contains { $0.text == "你好" })
    }

    @Test func invalidAndLongInputsKeepExactLiteralFallback() {
        let engine = CandidateEngine()
        for input in ["'ni", "ni''hao", "ni7hao", "👩🏽‍💻", String(repeating: "shi", count: 100)] {
            #expect(decoder.candidates(for: input).isEmpty)
            let candidates = engine.candidates(for: input, languages: [.simplifiedChinese])
            #expect(candidates.count == 1)
            #expect(candidates.first?.text == input)
            #expect(candidates.first?.isLiteral == true)
        }
        #expect(PinyinDecoder(entries: []).candidates(for: "ni").isEmpty)
    }

    @Test func directAndComposedDerivationsAreDeduplicatedDeterministically() {
        let candidates = decoder.candidates(for: "nihao")
        #expect(candidates.first?.text == "你好")
        #expect(candidates.count(where: { $0.text == "你好" }) == 1)
        #expect(Set(candidates.map(\.id)).count == candidates.count)
        #expect(candidates == decoder.candidates(for: "nihao"))
    }

    @Test func originalsHaveValidReadingsAndConsistentCharacterCounts() {
        for entry in OriginalPinyinLexicon.entries {
            #expect(entry.syllables.count == entry.text.count)
            #expect(!entry.syllables.isEmpty)
            #expect(entry.syllables.allSatisfy { $0.utf8.allSatisfy { $0 >= 97 && $0 <= 122 } })
        }
    }
}
