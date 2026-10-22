#if SWIFT_PACKAGE
import SICore
#endif

actor CandidatePreviewSearch {
    private let engine = CandidateEngine()

    func generate(_ query: CandidatePreviewQuery) -> [InputCandidate] {
        engine.candidates(for: query.input, languages: query.languages,
                          learning: query.learning, dictionary: query.dictionary)
    }
}
