public struct PinyinLexiconEntry: Sendable {
    public let syllables: [String]
    public let text: String
    /// Compatibility score for injected test/extension lexicons; bundled entries use upstreamWeight.
    public let score: Int
    /// Exact imported frequency; nil means spelling coverage without a supplied frequency.
    public let upstreamWeight: UInt64?
    let usesUpstreamWeight: Bool
    let code: String
    let boundaries: Set<Int>

    public init(syllables: [String], text: String, score: Int = 100) {
        self.init(syllables: syllables, text: text, score: score, upstreamWeight: nil, usesUpstreamWeight: false)
    }

    public init(syllables: [String], text: String, upstreamWeight: UInt64?) {
        self.init(syllables: syllables, text: text, score: 0, upstreamWeight: upstreamWeight, usesUpstreamWeight: true)
    }

    private init(syllables: [String], text: String, score: Int, upstreamWeight: UInt64?, usesUpstreamWeight: Bool) {
        self.syllables = syllables
        self.text = text
        self.score = score
        self.upstreamWeight = upstreamWeight
        self.usesUpstreamWeight = usesUpstreamWeight
        code = syllables.joined()
        var offset = 0
        boundaries = Set(syllables.dropLast().map { syllable in
            offset += syllable.utf8.count
            return offset
        })
    }
}
