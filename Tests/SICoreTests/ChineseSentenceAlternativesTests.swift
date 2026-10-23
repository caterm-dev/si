import Foundation
import Testing
@testable import SICore

struct ChineseSentenceAlternativesTests {
    @Test func reportedSentenceRemainsReachableInBothSearchStagesAndLanguageSets() throws {
        for input in ["erbeizuoduo", "er'bei'zuo'duo"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                for result in [request.generatePreview(), request.generate()] {
                    let sentence = try #require(result.candidates.first { $0.text == "二倍做多" && !$0.isPartial })
                    #expect(sentence.isChineseSentence)
                    let visible = CandidateShortlist.candidates(from: result.candidates)
                    #expect(visible.contains { $0.id == sentence.id })
                    #expect(visible.last?.isLiteral == true && visible.last?.text == input)
                    let accepted = session.accept(result)
                    #expect(accepted)
                }
                let chosen = try #require(session.candidates.first { $0.text == "二倍做多" && !$0.isPartial })
                let commit = session.commitResult(chosen, reason: .explicitSelection)
                #expect(commit.text == "二倍做多" && commit.input == input && session.buffer.isEmpty)
            }
        }
    }

    @Test func decoderEmitsSixDistinctBoundedSentencesWithoutChangingEvidenceResults() {
        let decoder = PinyinDecoder(entries: ["是", "时", "事", "市", "十", "使", "试", "式"].enumerated().map {
            PinyinLexiconEntry(syllables: ["shi"], text: $0.element, upstreamWeight: UInt64(1_000 - $0.offset * 50))
        })
        for preview in [false, true] {
            let plain = decoder.compositionCandidates(for: "shishishi", languages: [.simplifiedChinese], preview: preview)
            let sentences = plain.filter { !$0.isPartial }
            #expect(sentences.count == 6 && Set(sentences.map(\.id)).count == 6)
            #expect(sentences.allSatisfy { $0.isChineseSentence })
            #expect(plain == decoder.compositionCandidates(for: "shishishi", languages: [.simplifiedChinese], preview: preview))
            let traced = decoder.compositionCandidates(for: "shishishi", languages: [.simplifiedChinese],
                preview: preview, includesConfirmationEvidence: true)
            #expect(plain.map(\.id) == traced.map(\.id))
            #expect(plain.map(\.rankingScore) == traced.map(\.rankingScore))
        }
    }

    @Test func directLexicalMatchesDoNotAcquireSentencePlacementFromDuplicatePaths() throws {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["ni"], text: "你", upstreamWeight: 100),
            PinyinLexiconEntry(syllables: ["hao"], text: "好", upstreamWeight: 100),
            PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好", upstreamWeight: 10_000),
        ])
        let greeting = try #require(decoder.candidates(for: "nihao").first { $0.text == "你好" })
        #expect(!greeting.isChineseSentence && greeting.lexicalTokenCount == 1)
        let generated = sentence("甲乙丙", score: 10)
        let direct = InputCandidate(text: "甲乙丙", language: .simplifiedChinese, score: 9, lexicalTokenCount: 1)
        for (var retained, other) in [(generated, direct), (direct, generated)] {
            retained.retainLexicalEvidence(from: other)
            #expect(!retained.isChineseSentence && retained.lexicalTokenCount == 1)
        }
        #expect(generated.id == direct.id && generated.hasSameCommitValue(as:
            InputCandidate(text: "甲乙丙", language: .simplifiedChinese, score: 10)))
    }

    @Test func personalizedAlternativesKeepTheBaseLaneAndStayBounded() {
        let decoder = PinyinDecoder(entries: ["是", "时", "事", "市"].enumerated().map {
            PinyinLexiconEntry(syllables: ["shi"], text: $0.element, upstreamWeight: UInt64(1_000 - $0.offset * 50))
        })
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let learning = LearningProfile(entries: [
            LearnedPreference(input: "shishishi", text: "时时时", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let base = decoder.candidates(for: "shishishi")
        let personalized = decoder.compositionCandidates(for: "shishishi", languages: [.simplifiedChinese],
            learning: learning, now: now, includesPartials: false)
        #expect(personalized.first?.text == "时时时")
        #expect(base.allSatisfy { original in personalized.contains { $0.id == original.id } })
        #expect(personalized.count <= 12 && Set(personalized.map(\.id)).count == personalized.count)
    }

    @Test func longReadingsGroupThreeAndMoveOtherReadingsBehindOrdinaryChoices() {
        let english = InputCandidate(text: "English", language: .english, score: 100)
        let prefix = InputCandidate(text: "甲", language: .simplifiedChinese, score: 95, consumedInputCount: 1)
        let mixed = InputCandidate(text: "甲word", language: .simplifiedChinese, score: 85, isMixed: true)
        let short = sentence("甲乙", score: 70)
        let readings = ["甲乙丙", "甲乙丁", "甲乙戊", "甲乙己", "甲乙庚", "甲乙辛"].enumerated()
            .map { sentence($0.element, score: 99 - $0.offset * 10) }
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        let input = [english, readings[0], prefix, readings[1], mixed, readings[2], short] + Array(readings.dropFirst(3)) + [literal]
        let result = CandidateShortlist.candidates(from: input)
        #expect(result == [english] + Array(readings.prefix(3)) + [prefix, mixed, short] + Array(readings.dropFirst(3)) + [literal])
        #expect(Set(result.map(\.id)) == Set(input.map(\.id)))
    }

    @Test func twoCharacterReadingsKeepOneBeforeWordsAndRetainTheRestAtTheEnd() {
        let readings = ["甲乙", "甲丙", "甲丁"].map { sentence($0, score: 10) }
        let word = InputCandidate(text: "词语", language: .simplifiedChinese, score: 9, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        #expect(CandidateShortlist.candidates(from: readings + [word, literal]) == [readings[0], word] + Array(readings.dropFirst()) + [literal])
    }

    @Test func tailReadingsSurviveShortlistingAlongsidePinsHistoryLanguagesAndLiteral() throws {
        let pin = InputCandidate(text: "固定", language: .simplifiedChinese, score: 100, isUserPhrase: true, isPreferred: true)
        let readings = ["甲乙丙", "甲乙丁", "甲乙戊", "甲乙己", "甲乙庚", "甲乙辛"].map { sentence($0, score: 90) }
        let words = (0..<50).map { InputCandidate(text: "词\($0)", language: .simplifiedChinese, score: 80) }
        let english = InputCandidate(text: "word", language: .english, score: 1)
        let mixed = InputCandidate(text: "甲word", language: .simplifiedChinese, score: 1, isMixed: true)
        let history = InputCandidate(text: "历史", language: .simplifiedChinese, score: 1, isHistory: true, historyInput: "synthetic")
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        let result = CandidateShortlist.candidates(from: [pin, readings[0], history] + words + Array(readings.dropFirst()) + [english, mixed, literal])
        #expect(result.count == 27 && result.first == pin && result.last == literal)
        #expect(result[2] == history)
        #expect(readings.allSatisfy(result.contains))
        #expect(result.contains(english) && result.contains(mixed))
        #expect(Array(result.suffix(4)) == Array(readings.suffix(3)) + [literal])
    }

    private func sentence(_ text: String, score: Int) -> InputCandidate {
        InputCandidate(text: text, language: .simplifiedChinese, score: score).withChineseSentenceOrigin()
    }
}
