public struct MixedCandidateProvider: CandidateProvider {
    public let language = InputLanguage.simplifiedChinese
    public let requiredLanguages: Set<InputLanguage> = [.english, .simplifiedChinese]

    public init() {}

    public func candidates(for input: String) -> [InputCandidate] {
        PinyinDecoder.standard.mixedCandidates(for: input)
    }
}
