import Foundation
import Testing
@testable import SICore

struct ChineseMigrationTests {
    @Test func abbreviatedSyllableRetainsSelectablePrefixesAndExactRemainder() throws {
        let input = try #require(PinyinInput("jintjiushi"))
        #expect(ChineseSyllables.primary(input) == ["jin", "t", "jiu", "shi"])
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese])
        session.append("jintjiushi")
        let today = try #require(session.candidates.first { $0.text == "今天" })
        #expect(today.consumedInputCount == 4 && today.isPartial)
        #expect(!session.candidates.contains { $0.text == "今天就是" && !$0.isPartial })
        #expect(session.candidates.last?.text == "jintjiushi" && session.candidates.last?.isLiteral == true)
        let commit = session.commitResult(today, reason: .explicitSelection)
        #expect(commit.input == "jint" && commit.text == "今天")
        #expect(session.buffer == "jiushi")
        #expect(session.candidates.contains { $0.text == "就是" && !$0.isPartial })
    }

    @Test func fullSpellingSuppliesTheReportedWholeSentence() {
        for source in ["jintianjiushi", "jin'tian'jiu'shi"] {
            let values = CandidateEngine().candidates(for: source, languages: [.simplifiedChinese])
            #expect(values.first?.text == "今天就是" && values.first?.isPartial == false)
            #expect(values.last?.text == source && values.last?.isLiteral == true)
        }
    }
    @Test func packagedDictionaryAndContextTablesLoad() {
        #expect(ChineseLexicon.standard.isAvailable)
        #expect(ChineseLexicon.standard.bigram != nil)
        #expect(ChineseLexicon.standard.trigram != nil)
        let row = ChineseLexicon.standard.exactMatches(["ne"]).first
        #expect(row?.text == "呢" && row?.weight == 7_763_286)
    }

    @Test func exactNeRemainsAvailableWhileEnglishCompletionsCompeteByScore() {
        let engine = CandidateEngine()
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            let values = engine.candidates(for: "ne", languages: languages)
            #expect(values.contains { $0.text == "呢" && !$0.hasCompletion })
            if !languages.contains(.english) { #expect(values.first?.text == "呢") }
            #expect(values.last?.text == "ne" && values.last?.isLiteral == true)
            if languages.contains(.english) { #expect(values.contains { $0.text == "new" }) }
            #expect(values == engine.candidates(for: "ne", languages: languages))
        }
    }

    @Test func completeAndExplicitCutsRetainSourceBoundaries() throws {
        for (source, expected) in [("fangan", ["fan", "gan"]), ("xian", ["xian"]),
                                   ("xi'an", ["xi", "an"]), ("ni'hao", ["ni", "hao"])] {
            #expect(ChineseSyllables.primary(try #require(PinyinInput(source))) == expected)
        }
        let engine = CandidateEngine()
        for (source, consumed) in [("lvsepengyou", 4), ("lüsepengyou", 4), ("lu:sepengyou", 5)] {
            let values = engine.candidates(for: source, languages: [.simplifiedChinese])
            let prefix = try #require(values.first { $0.text == "绿色" && $0.isLexicalPrefix })
            #expect(prefix.consumedInputCount == consumed)
            #expect(String(source.dropFirst(consumed)) == "pengyou")
        }
    }

    @Test func aFrequentCompletionPaysForMissingSpellingInsteadOfUsingAReservedSeat() {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好", upstreamWeight: 10),
            PinyinLexiconEntry(syllables: ["ni", "hao", "ma"], text: "你好吗", upstreamWeight: 1_000_000),
        ])
        let values = decoder.candidates(for: "nihao")
        #expect(values.first?.text == "你好吗" && values.first?.hasCompletion == true)
        #expect(values.contains { $0.text == "你好" && !$0.hasCompletion })
        if let full = values.first(where: { $0.text == "你好" }), let completion = values.first(where: { $0.text == "你好吗" }) {
            let expectedDifference = log2(1_000_000.0 / 10) + log2(1.0 / 67)
            #expect(abs(completion.rankingScore - full.rankingScore - expectedDifference) < 1e-12)
        }
    }

    @Test func sentenceUsesNaturalLogEdgesAndRetainsExactWords() throws {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["wo"], text: "我", upstreamWeight: 1_000_000),
            PinyinLexiconEntry(syllables: ["shi"], text: "是", upstreamWeight: 100_000),
        ])
        let values = decoder.candidates(for: "woshi")
        let sentence = try #require(values.first)
        #expect(sentence.text == "我是" && sentence.lexicalTokenCount == 2)
        let expected = (log(100_000_000_000.0) - 44) / log(2.0) - 1
            + log2(1 - RankingCalibration.switchProbability) + log2(64.0 / 67) + log2(128.0 / 135)
        #expect(abs(sentence.rankingScore - expected) < 1e-12)
    }

    @Test func evidenceLeavesVisibleCandidatesAndScoresUnchanged() {
        let engine = CandidateEngine()
        for source in ["nihaopengyou", "julitebieyuan", "womenxuexizhongwen", "shi" + String(repeating: "shi", count: 19)] {
            let plain = engine.candidates(for: source, languages: [.simplifiedChinese])
            let traced = engine.candidates(for: source, languages: [.simplifiedChinese], includesConfirmationEvidence: true)
            #expect(plain.map(\.id) == traced.map(\.id))
            #expect(plain.map(\.rankingScore) == traced.map(\.rankingScore))
            #expect(plain.map { Array($0.text.utf8) } == traced.map { Array($0.text.utf8) })
            #expect(traced.allSatisfy { $0.confirmationBoundaries.count <= 8 })
        }
    }

    @Test func incompleteTailKeepsLearnedPrefixWithoutInventingAWholeSentence() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["a"], text: "甲", upstreamWeight: 100),
            PinyinLexiconEntry(syllables: ["a"], text: "乙", upstreamWeight: 50),
        ])
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "aa", text: "乙乙", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let values = decoder.compositionCandidates(for: "aab", languages: [.simplifiedChinese], learning: profile, now: now)
        let prefix = try #require(values.first { $0.text == "乙乙" && $0.consumedInputCount == 2 })
        #expect(profile.bonus(for: prefix, input: "aa", now: now) == 32)
        #expect(profile.bonus(for: prefix, input: "aab", now: now) == 0)
        #expect(!values.contains { !$0.isPartial })
    }

    @Test func independentLatticeCalculationMatchesPinnedResourcesAndLocalScoring() throws {
        // Independent Python calculation of SQL spans, SI word scores and ngram increments.
        // SI intentionally uses a smaller single-character insertion cost than upstream.
        // These are arithmetic fixtures, not desired-language-quality assertions. In particular
        // the first fixture records the unresolved discrepancy with the reported MSIME output.
        let fixtures: [(String, String, Double, [Int], Int)] = [
            ("julitebieyuan", "距离特别圆", 118.69906632548162, [2, 2, 2, 3, 4], 2),
            ("bangwozaixie", "帮我在写", 91.31678246909371, [4, 2, 3, 3], 2),
            ("nihaopengyou", "你好朋友", 101.34944880941819, [2, 3, 4, 3], 2),
            ("nengxiangbanfayouhuama", "能想办法优化吗", 162.56195220015462, [4, 5, 3, 2, 3, 3, 2], 4),
        ]
        for (input, text, legacyScore, syllableLengths, words) in fixtures {
            let candidate = try #require(PinyinDecoder.standard.candidates(for: input).first)
            // Convert the independently calculated legacy oracle to the shared scale:
            // remove its per-syllable offset, then include BOS, spelling and transitions.
            let spelling = syllableLengths.reduce(0.0) { $0 + log2((16 + 1 - exp2(-Double($1))) / 16) }
            let score = legacyScore - 20 * Double(syllableLengths.count) / log(2.0) - 1 - spelling
                + Double(words - 1) * log2(1 - RankingCalibration.switchProbability)
            #expect(candidate.text == text)
            #expect(abs(candidate.rankingScore - score) < 1e-10)
        }
    }

    @Test func ngramBinaryContractAndMalformedTables() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.bin")
        // FNV-1a keys computed independently from zero-byte-joined UTF-8 words.
        let keys: [UInt64] = [2_309_531_045_028_478_214, 5_351_390_074_750_261_782, 9_154_027_115_281_161_702]
        var data = Data([77, 83, 78, 71])
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(1)); append(UInt32(3)); append(UInt32(0))
        for key in keys { append(key) }
        for value: Float in [0.5, 2.25, -1.5] { append(value.bitPattern) }
        try data.write(to: url)
        let table = try #require(ChineseNgramTable(url: url))
        #expect(table.score(["配置", "与"]) == 2.25)
        #expect(table.score(["\u{1}", "你好"]) == -1.5)
        #expect(table.score(["\u{1}", "你好", "朋友"]) == 0.5)
        #expect(table.score(["missing"]) == 0)
        let malformed = directory.appendingPathComponent("malformed.bin")
        try data.dropLast().write(to: malformed)
        #expect(ChineseNgramTable(url: malformed) == nil)
        data[4] = 2
        try data.write(to: malformed)
        #expect(ChineseNgramTable(url: malformed) == nil)
    }
}
