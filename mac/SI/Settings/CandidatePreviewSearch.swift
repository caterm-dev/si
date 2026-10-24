#if SWIFT_PACKAGE
import SICore
#endif

actor CandidatePreviewSearch {
    func generate(_ query: CandidatePreviewQuery) -> [InputCandidate] {
        let engine = CandidateEngine(punctuationCandidatesEnabled: query.punctuationCandidatesEnabled)
        return engine.candidates(for: query.input, languages: query.languages,
                                 learning: query.learning, dictionary: query.dictionary, applicationMemory: query.applicationMemory)
    }
}
