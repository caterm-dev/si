import Foundation

/// Shared facade used by the input method, Settings preview and package callers.
/// Chinese decoding is the Swift MSIME adaptation; English remains an independent lane.
public struct PinyinDecoder: Sendable {
    public static let standard = PinyinDecoder()
    public static let maximumOutputBytes = 4_096
    private let chinese: ChineseDecoder?

    public init(entries: [PinyinLexiconEntry]) {
        chinese = ChineseDecoder(lexicon: ChineseLexicon(entries: entries))
    }

    private init() { chinese = nil }

    public func candidates(for input: String) -> [InputCandidate] {
        compositionCandidates(for: input, languages: [.simplifiedChinese], includesPartials: false,
                              allowsVerbatim: false)
    }

    public func mixedCandidates(for input: String) -> [InputCandidate] {
        // Mixed lexical paths return after the Chinese baseline has been established. Keeping
        // this entry point does not let the former model alter Chinese sentence candidates.
        []
    }

    public func compositionCandidates(for input: String, languages: Set<InputLanguage>,
                                      dictionary: UserDictionary = UserDictionary(),
                                      learning: LearningProfile = LearningProfile(), now: Date = .now,
                                      context: CandidateContext? = nil,
                                      includesPartials: Bool = true, allowsVerbatim: Bool = true,
                                      preview: Bool = false, includesConfirmationEvidence: Bool = false) -> [InputCandidate] {
        var result: [InputCandidate] = []
        if languages.contains(.simplifiedChinese) {
            result += (chinese ?? .standard).candidates(for: input, dictionary: dictionary, learning: learning, now: now,
                                         context: context, includesPartials: includesPartials,
                                         includesConfirmationEvidence: includesConfirmationEvidence, preview: preview)
        }
        if languages.contains(.english) {
            result += EnglishCompositionDecoder.standard.compositionCandidates(
                for: input, languages: [.english], dictionary: dictionary, learning: learning, now: now,
                context: context, includesPartials: includesPartials, allowsVerbatim: allowsVerbatim,
                preview: preview, includesConfirmationEvidence: false)
        }
        return result
    }
}
