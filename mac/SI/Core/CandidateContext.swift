import Foundation

/// One prior confirmed candidate, not surrounding document text or a sentence history.
public struct CandidateContext: Codable, Equatable, Sendable {
    public let text: String
    public let language: InputLanguage
    public let isMixed: Bool

    public init?(candidate: InputCandidate) {
        guard let language = candidate.language, candidate.canLearn else { return nil }
        self.text = candidate.text
        self.language = language
        self.isMixed = candidate.isMixed
        guard isValid else { return nil }
    }

    var id: String { "\(isMixed ? "zh-Hans+en" : language.rawValue):\(text)" }
    var isValid: Bool {
        !text.isEmpty && text.utf8.count <= 512
            && (!isMixed || language == .simplifiedChinese)
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
