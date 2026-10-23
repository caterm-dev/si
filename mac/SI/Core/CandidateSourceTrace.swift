/// Shared immutable lexical boundaries for projecting a complete hypothesis onto a prefix action.
final class CandidateSourceTrace: Equatable, Sendable {
    let boundary: ConfirmationBoundary
    let languages: Int
    let previous: CandidateSourceTrace?
    let word: String
    let wordLanguage: Int
    let lexicalCost: Double
    let personal: Bool
    let verbatim: Bool
    let rawOutputByteCount: Int
    let interiorBoundaries: [ConfirmationBoundary]

    init(sourceCount: Int, outputByteCount: Int, languages: Int, previous: CandidateSourceTrace?,
         word: String = "", wordLanguage: Int = 0, lexicalCost: Double = 0,
         personal: Bool = false, verbatim: Bool = false, rawOutputByteCount: Int? = nil,
         interiorBoundaries: [ConfirmationBoundary] = []) {
        boundary = ConfirmationBoundary(sourceCount: sourceCount, outputByteCount: outputByteCount)
        self.languages = languages
        self.previous = previous
        self.word = word
        self.wordLanguage = wordLanguage
        self.lexicalCost = lexicalCost
        self.personal = personal
        self.verbatim = verbatim
        self.rawOutputByteCount = rawOutputByteCount ?? outputByteCount
        self.interiorBoundaries = interiorBoundaries
    }

    static func == (lhs: CandidateSourceTrace, rhs: CandidateSourceTrace) -> Bool {
        if lhs === rhs { return true }
        return lhs.boundary == rhs.boundary && lhs.languages == rhs.languages && lhs.word == rhs.word
            && lhs.wordLanguage == rhs.wordLanguage && lhs.lexicalCost == rhs.lexicalCost
            && lhs.personal == rhs.personal && lhs.verbatim == rhs.verbatim
            && lhs.rawOutputByteCount == rhs.rawOutputByteCount && lhs.interiorBoundaries == rhs.interiorBoundaries
            && lhs.previous == rhs.previous
    }

    /// A full reading supplies a per-character alignment only for one-syllable-per-Han-character rows.
    static func chineseInteriors(text: String, sourceCounts: [Int]) -> [ConfirmationBoundary] {
        let characters = Array(text)
        guard characters.count == sourceCounts.count + 1,
              characters.allSatisfy({ character in
                  character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy {
                      (0x3400...0x4dbf).contains($0.value) || (0x4e00...0x9fff).contains($0.value)
                  }
              }) else { return [] }
        var bytes = 0
        return zip(sourceCounts, characters).map { source, character in
            bytes += character.utf8.count
            return ConfirmationBoundary(sourceCount: source, outputByteCount: bytes)
        }
    }
}
