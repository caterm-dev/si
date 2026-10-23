import Foundation

/// Reuse retained lexical paths for lookahead instead of decoding each overlapping suffix again.
enum CandidateContinuation {
    private struct LeadingContext: Hashable {
        let language: Int
        let words: [String]
        let personal: Bool
        let verbatim: Bool
    }

    /// Separate contextual and context-free lanes keep private paths from borrowing corpus bonuses.
    static func bounded(_ candidates: [InputCandidate]) -> [InputCandidate] {
        var kept = Set<Int>()
        for ignoresContext in [false, true] {
            let ordered = candidates.indices.sorted {
                let a = candidates[$0].rankingScore - (ignoresContext ? candidates[$0].wordContext?.corpusScore ?? 0 : 0)
                let b = candidates[$1].rankingScore - (ignoresContext ? candidates[$1].wordContext?.corpusScore ?? 0 : 0)
                if a != b { return a > b }
                if candidates[$0].id != candidates[$1].id { return candidates[$0].id < candidates[$1].id }
                return $0 < $1
            }
            var seen = Set<LeadingContext>()
            for index in ordered {
                let candidate = candidates[index]
                let key = LeadingContext(language: candidate.wordContext?.firstLanguage ?? (candidate.language == .english ? 2 : 1),
                    words: candidate.wordContext?.firstChineseWords ?? [candidate.text],
                    personal: candidate.isUserPhrase, verbatim: candidate.hasLiteralSegments)
                if seen.insert(key).inserted { kept.insert(index) }
                if seen.count == 16 { break }
            }
        }
        return candidates.indices.filter(kept.contains).map { candidates[$0] }
    }

    static func joining(_ first: InputCandidate, _ last: InputCandidate) -> InputCandidate? {
        let personal = first.isUserPhrase || last.isUserPhrase
        let verbatim = first.hasLiteralSegments || last.hasLiteralSegments
        let english = first.language == .english && last.language == .english && !first.isMixed && !last.isMixed
        let mixed = first.isMixed || last.isMixed || first.language != last.language
        let text = first.text + (english && !personal && !verbatim ? " " : "") + last.text
        guard text.utf8.count <= PinyinDecoder.maximumOutputBytes else { return nil }
        let adjustment = CandidateWordContext.joining(first, to: last)
        let score = first.rankingScore + last.rankingScore + adjustment
        var result = InputCandidate(text: text, language: english ? .english : .simplifiedChinese, score: Int(score),
            isMixed: mixed, isUserPhrase: personal, hasLiteralSegments: verbatim, rankingScore: score,
            hasCompletion: last.hasCompletion)
        if let before = first.wordContext, let after = last.wordContext {
            result = result.withWordContext(.combining(before, after, joiningAdjustment: adjustment))
        }
        return result
    }

    static func projections(of candidates: [InputCandidate], inputCount: Int,
                            languages enabled: Set<InputLanguage>) -> [Int: [InputCandidate]] {
        let requested = Set(candidates.compactMap(\.consumedInputCount))
        guard !requested.isEmpty else { return [:] }
        var result: [Int: [InputCandidate]] = [:]
        for full in candidates where !full.isPartial && !full.isLiteral && !full.isHistory
            && full.language.map(enabled.contains) == true
            && (!full.isMixed || (full.language == .simplifiedChinese && enabled.contains(.english))) {
            var reversed: [CandidateSourceTrace] = []
            var trace = full.sourceTrace
            while let node = trace {
                reversed.append(node)
                trace = node.previous
            }
            let tokens = Array(reversed.reversed())
            guard tokens.count > 1, tokens.allSatisfy({ $0.wordLanguage != 0 && !$0.word.isEmpty }) else { continue }
            let lexicon: ChineseLexicon? = full.wordContext?.usesChineseContext == true ? .standard : nil
            for start in 1..<tokens.count {
                let boundary = tokens[start - 1].boundary
                guard requested.contains(boundary.sourceCount), boundary.sourceCount < inputCount else { continue }
                let tail = tokens[start...]
                let personal = tail.contains(where: \.personal)
                let verbatim = tail.contains(where: \.verbatim)
                let tailLanguages = tail.reduce(0) { $0 | $1.wordLanguage }
                let text = tail.map(\.word).joined(separator: tailLanguages == 2 && !personal && !verbatim ? " " : "")
                guard text.utf8.count <= PinyinDecoder.maximumOutputBytes else { continue }
                var wordContext = CandidateWordContext()
                var languages = 0
                var score = 0.0
                var passedPersonal = false
                for token in tail {
                    let previous = wordContext.lastChineseWords.last ?? "\u{1}"
                    let before = wordContext.lastChineseWords.count > 1 ? wordContext.lastChineseWords[0] : "\u{1}"
                    let usesContext = token.wordLanguage == 1 && !passedPersonal && !token.personal
                    let bigram = usesContext ? 2 * max(0, lexicon?.bigram?.score([previous, token.word]) ?? 0) / log(2.0) : 0
                    let trigram = usesContext && !personal
                        ? (lexicon?.trigram?.score([before, previous, token.word]) ?? 0) / log(2.0) : 0
                    score -= token.lexicalCost
                        + CandidateScoring.languageCost(previous: wordContext.lastLanguage, next: token.wordLanguage)
                    score += bigram + trigram
                    wordContext = wordContext.appending(word: token.word, language: token.wordLanguage,
                        corpusScore: bigram + trigram, usesContext: lexicon != nil)
                    languages |= token.wordLanguage
                    passedPersonal = passedPersonal || token.personal
                }
                let candidate = InputCandidate(text: text, language: languages == 2 ? .english : .simplifiedChinese,
                    score: Int(score), isMixed: languages == 3, isUserPhrase: personal,
                    hasLiteralSegments: verbatim, rankingScore: score, hasCompletion: full.hasCompletion,
                    lexicalTokenCount: tail.count).withWordContext(wordContext)
                result[boundary.sourceCount, default: []].append(candidate)
            }
        }
        return result.mapValues(bounded)
    }
}
