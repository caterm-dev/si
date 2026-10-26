import Foundation

/// Shared facade used by the input method and package callers.
/// Chinese sentences retain their Swift MSIME lane; bounded lexical search also joins enabled languages.
public struct PinyinDecoder: Sendable {
    public static let standard = PinyinDecoder()
    public static let maximumOutputBytes = 4_096
    private let chinese: ChineseDecoder?
    private let mixed: LexicalCompositionDecoder?

    public init(entries: [PinyinLexiconEntry]) {
        let lexicon = ChineseLexicon(entries: entries)
        chinese = ChineseDecoder(lexicon: lexicon)
        mixed = LexicalCompositionDecoder(chineseLexicon: lexicon)
    }

    private init() {
        chinese = nil
        mixed = nil
    }

    public func candidates(for input: String) -> [InputCandidate] {
        compositionCandidates(for: input, languages: [.simplifiedChinese], includesPartials: false,
                              allowsVerbatim: false)
    }

    public func mixedCandidates(for input: String) -> [InputCandidate] {
        compositionCandidates(for: input, languages: [.english, .simplifiedChinese],
                              includesPartials: false, allowsVerbatim: false).filter(\.isMixed)
    }

    /// Supplemental lookahead for boundaries absent from the retained full paths.
    /// It shares the decoders and dictionary but has a smaller spelling/search budget.
    func continuationCandidates(for input: String, languages: Set<InputLanguage>,
                                dictionary: UserDictionary, now: Date) -> [InputCandidate] {
        var result: [InputCandidate] = []
        if languages.contains(.simplifiedChinese) {
            result += (chinese ?? .standard).candidates(for: input, dictionary: dictionary,
                learning: LearningProfile(), now: now, context: nil, includesPartials: false,
                includesConfirmationEvidence: false, preview: true, lookahead: true)
        }
        if languages.contains(.english) {
            result += LexicalCompositionDecoder.standard.compositionCandidates(for: input, languages: [.english],
                dictionary: dictionary, now: now, includesPartials: false, preview: true, lookahead: true)
        }
        if languages.contains(.english) && languages.contains(.simplifiedChinese) {
            result += (mixed ?? .mixed).compositionCandidates(for: input, languages: languages,
                dictionary: dictionary, now: now, includesPartials: false, preview: true, lookahead: true).filter(\.isMixed)
        }
        return result
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
            result += LexicalCompositionDecoder.standard.compositionCandidates(
                for: input, languages: [.english], dictionary: dictionary, learning: learning, now: now,
                context: context, includesPartials: includesPartials, allowsVerbatim: allowsVerbatim,
                preview: preview, includesConfirmationEvidence: false)
        }
        if languages.contains(.english) && languages.contains(.simplifiedChinese) {
            result += (mixed ?? .mixed).compositionCandidates(for: input, languages: languages, dictionary: dictionary,
                learning: learning, now: now, context: context, includesPartials: includesPartials,
                allowsVerbatim: allowsVerbatim, preview: preview).filter(\.isMixed)
        }
        return result
    }
}
