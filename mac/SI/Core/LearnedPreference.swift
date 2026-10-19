import Foundation

public struct LearnedPreference: Codable, Equatable, Identifiable, Sendable {
    public let input: String
    public let text: String
    public let language: InputLanguage
    public let mixed: Bool?
    public let context: CandidateContext?
    public internal(set) var strength: Double
    public internal(set) var lastUsed: Date

    public var id: String { Self.identity(input: input, language: language, text: text, isMixed: mixed == true, context: context) }

    public init(input: String, text: String, language: InputLanguage, strength: Double, lastUsed: Date,
                isMixed: Bool = false, context: CandidateContext? = nil) {
        self.input = input
        self.text = text
        self.language = language
        self.mixed = isMixed ? true : nil
        self.context = context
        self.strength = strength
        self.lastUsed = lastUsed
    }

    static func identity(input: String, language: InputLanguage, text: String, isMixed: Bool = false,
                         context: CandidateContext? = nil) -> String {
        // A length-prefixed input prevents delimiter collisions in candidate text.
        let base = "\(input.utf8.count):\(input)\(isMixed ? "zh-Hans+en" : language.rawValue):\(text)"
        guard let context else { return base }
        return "\(base.utf8.count):\(base)after:\(context.id)"
    }
}
