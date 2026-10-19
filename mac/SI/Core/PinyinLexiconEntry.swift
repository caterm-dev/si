public struct PinyinLexiconEntry: Sendable {
    public let syllables: [String]
    public let text: String
    public let score: Int
    let code: String
    let boundaries: Set<Int>

    public init(syllables: [String], text: String, score: Int = 100) {
        self.syllables = syllables
        self.text = text
        self.score = score
        code = syllables.joined()
        var offset = 0
        boundaries = Set(syllables.dropLast().map { syllable in
            offset += syllable.utf8.count
            return offset
        })
    }
}
