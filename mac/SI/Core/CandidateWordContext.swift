import Foundation

/// Bounded lexical boundary evidence for a continuation; never retained in learning records.
struct CandidateWordContext: Equatable, Sendable {
    var firstLanguage = 0
    var lastLanguage = 0
    var firstChineseWords: [String] = []
    var lastChineseWords: [String] = []
    var firstChineseRunEnded = false
    var corpusScore = 0.0
    var usesChineseContext = false

    static let english = CandidateWordContext(firstLanguage: 2, lastLanguage: 2, firstChineseRunEnded: true)

    static func chinese(_ words: [String], corpusScore: Double, usesContext: Bool) -> Self {
        Self(firstLanguage: 1, lastLanguage: 1, firstChineseWords: Array(words.prefix(2)),
             lastChineseWords: Array(words.suffix(2)), corpusScore: corpusScore, usesChineseContext: usesContext)
    }

    func appending(word: String, language: Int, corpusScore: Double, usesContext: Bool) -> Self {
        var result = self
        if firstLanguage == 0 { result.firstLanguage = language }
        if language == 1 {
            if !firstChineseRunEnded && result.firstLanguage == 1 && firstChineseWords.count < 2 {
                result.firstChineseWords.append(word)
            }
            result.lastChineseWords = Array((lastLanguage == 1 ? lastChineseWords + [word] : [word]).suffix(2))
        } else {
            result.firstChineseRunEnded = true
            result.lastChineseWords = []
        }
        result.lastLanguage = language
        result.corpusScore += corpusScore
        result.usesChineseContext = usesChineseContext || usesContext
        return result
    }

    /// Replace the suffix's synthetic BOS boundary with the prefix's actual lexical context.
    static func joining(_ prefix: InputCandidate, to suffix: InputCandidate) -> Double {
        guard let after = suffix.wordContext else { return 0 }
        let excludesContext = prefix.isUserPhrase || prefix.hasLiteralSegments || suffix.isUserPhrase || suffix.hasLiteralSegments
        guard let before = prefix.wordContext else { return excludesContext ? -after.corpusScore : 0 }
        var adjustment = CandidateScoring.initialLanguageCost
            - CandidateScoring.languageCost(previous: before.lastLanguage, next: after.firstLanguage)
        if excludesContext {
            return adjustment - after.corpusScore
        }
        guard before.lastLanguage == 1, after.firstLanguage == 1,
              before.usesChineseContext, after.usesChineseContext,
              let previous = before.lastChineseWords.last, let first = after.firstChineseWords.first else { return adjustment }
        let bos = "\u{1}"
        let earlier = before.lastChineseWords.count > 1 ? before.lastChineseWords[0] : bos
        let lexicon = ChineseLexicon.standard
        func bigram(_ word: String) -> Double { 2 * max(0, lexicon.bigram?.score([word, first]) ?? 0) }
        func trigram(_ a: String, _ b: String, _ c: String) -> Double { lexicon.trigram?.score([a, b, c]) ?? 0 }
        adjustment += (bigram(previous) - bigram(bos)
            + trigram(earlier, previous, first) - trigram(bos, bos, first)) / log(2.0)
        if after.firstChineseWords.count > 1 {
            let second = after.firstChineseWords[1]
            adjustment += (trigram(previous, first, second) - trigram(bos, first, second)) / log(2.0)
        }
        return adjustment
    }

    static func combining(_ before: Self, _ after: Self, joiningAdjustment: Double) -> Self {
        var result = before
        if before.firstLanguage == 1 && !before.firstChineseRunEnded && after.firstLanguage == 1 {
            result.firstChineseWords = Array((before.firstChineseWords + after.firstChineseWords).prefix(2))
        }
        result.firstChineseRunEnded = before.firstChineseRunEnded || after.firstChineseRunEnded || after.firstLanguage != 1
        result.lastLanguage = after.lastLanguage
        if after.lastLanguage == 1 && !after.firstChineseRunEnded && before.lastLanguage == 1 {
            result.lastChineseWords = Array((before.lastChineseWords + after.lastChineseWords).suffix(2))
        } else { result.lastChineseWords = after.lastChineseWords }
        let languageAdjustment = CandidateScoring.initialLanguageCost
            - CandidateScoring.languageCost(previous: before.lastLanguage, next: after.firstLanguage)
        result.corpusScore = before.corpusScore + after.corpusScore + joiningAdjustment - languageAdjustment
        result.usesChineseContext = before.usesChineseContext || after.usesChineseContext
        return result
    }
}
