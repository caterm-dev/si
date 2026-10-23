/// Local punctuation alternatives shared by the input method and Settings preview.
public enum PunctuationCandidates {
    private static let chinese: [String: [String]] = [
        ",": ["，", "、"], ".": ["。", "…"], "/": ["、"], ";": ["；"],
        "'": ["‘", "’"], "\"": ["“", "”"], ":": ["："], "!": ["！"], "?": ["？"],
        "(": ["（"], ")": ["）"], "[": ["【"], "]": ["】"],
    ]

    public static func recognizes(_ text: String) -> Bool { chinese[text] != nil }

    public static func hasRecognizedSuffix(_ input: String) -> Bool {
        input.last.map { recognizes(String($0)) } ?? false
    }

    static func split(_ input: String) -> (prefix: String, symbol: String)? {
        guard let last = input.last else { return nil }
        let symbol = String(last)
        guard recognizes(symbol) else { return nil }
        let prefix = String(input.dropLast())
        // Inside Pinyin, apostrophes remain explicit syllable boundaries.
        guard symbol != "'" || prefix.isEmpty else { return nil }
        return (prefix, symbol)
    }

    static func candidates(symbol: String, prefixes: [InputCandidate], languages: Set<InputLanguage>,
                           rankingScore: (InputCandidate) -> Double = { $0.rankingScore }) -> [InputCandidate] {
        var variants: [(text: String, language: InputLanguage)] = []
        if languages.contains(.english) { variants.append((symbol, .english)) }
        if languages.contains(.simplifiedChinese) {
            variants += (chinese[symbol] ?? []).map { ($0, .simplifiedChinese) }
        }
        var result: [InputCandidate] = []
        var identities: Set<String> = []
        for prefix in prefixes where !prefix.isPartial && !prefix.hasCompletion && !prefix.isHistory
            && (!prefix.isLiteral || prefix.text.isEmpty) {
            for (index, variant) in variants.enumerated() {
                let text = prefix.text + variant.text
                guard text.utf8.count <= 4_096 else { continue }
                let candidate = InputCandidate(text: text, language: prefix.language ?? variant.language,
                    score: prefix.score, isMixed: prefix.isMixed, isUserPhrase: prefix.isUserPhrase,
                    hasLiteralSegments: prefix.hasLiteralSegments,
                    rankingScore: rankingScore(prefix) - Double(index) / 100,
                    punctuationLanguage: variant.language)
                if identities.insert(candidate.id).inserted { result.append(candidate) }
            }
        }
        return result
    }
}
