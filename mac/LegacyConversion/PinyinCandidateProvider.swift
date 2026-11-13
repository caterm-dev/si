public struct PinyinCandidateProvider: CandidateProvider {
    public let language = InputLanguage.simplifiedChinese
    private let decoder: PinyinDecoder

    public init(decoder: PinyinDecoder = .standard) { self.decoder = decoder }

    public func candidates(for input: String) -> [InputCandidate] {
        decoder.candidates(for: input)
    }
}
