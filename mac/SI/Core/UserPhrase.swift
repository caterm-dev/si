import Foundation

public struct UserPhrase: Codable, Equatable, Identifiable, Sendable {
    public enum ValidationError: Error, Equatable {
        case invalidInput
        case invalidText
    }

    public let id: UUID
    public let input: String
    public let text: String
    public let language: InputLanguage
    public let isPinned: Bool

    public init(id: UUID = UUID(), input: String, text: String, language: InputLanguage, isPinned: Bool = false) throws {
        let code = LearningProfile.normalizedInput(input.trimmingCharacters(in: .whitespacesAndNewlines), language: language)
        guard !code.isEmpty, code.utf8.count <= 64, !code.hasPrefix("'"), !code.hasSuffix("'"),
              !code.contains("''"), code.unicodeScalars.allSatisfy({
                  $0.isASCII && (($0.value >= 97 && $0.value <= 122) || $0 == "'")
              }) else { throw ValidationError.invalidInput }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_024,
              text.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) || $0.value == 0x200C || $0.value == 0x200D
              }) else { throw ValidationError.invalidText }
        self.id = id
        self.input = code
        self.text = text
        self.language = language
        self.isPinned = isPinned
    }

    var identity: String { LearnedPreference.identity(input: input, language: language, text: text) }
    var code: String { input.replacing("'", with: "") }
    var boundaries: Set<Int> {
        var count = 0
        var result = Set<Int>()
        for character in input {
            if character == "'" { result.insert(count) } else { count += 1 }
        }
        return result
    }

    func validated() throws -> UserPhrase {
        try UserPhrase(id: id, input: input, text: text, language: language, isPinned: isPinned)
    }
}
