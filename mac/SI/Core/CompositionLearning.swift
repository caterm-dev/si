/// Transient evidence from successful manual submissions in one unchanged composition.
/// This never reads history or host text and never submits its aggregate to the host.
struct CompositionLearning: Sendable {
    private var input = ""
    private var text = ""
    private var remainder: String?
    private var language: InputLanguage?
    private var mixed = false
    private var corrected = false
    private var score = 0.0
    private var tokenCount = 0
    private var pieces = 0
    private var blocked = false

    mutating func invalidate() {
        self = Self()
        blocked = true
    }

    mutating func edited() {
        if pieces > 0 { invalidate() }
    }

    mutating func record(_ commit: InputCommit) -> InputCommit? {
        defer { if commit.remainingInput.isEmpty { self = Self() } }
        guard !blocked, commit.canLearn, let candidate = commit.candidate, let candidateLanguage = candidate.language,
              !commit.input.isEmpty, !commit.text.isEmpty,
              remainder.map({ $0.utf8.elementsEqual((commit.input + commit.remainingInput).utf8) }) ?? true,
              candidate.consumedInputCount == (commit.remainingInput.isEmpty ? nil : commit.input.count)
        else { invalidate(); return nil }
        let nextInput = input + commit.input
        let nextText = text + commit.text
        let nextMixed = mixed || candidate.isMixed || (language != nil && language != candidate.language)
        let nextLanguage: InputLanguage = nextMixed ? .simplifiedChinese : candidateLanguage
        // Match the existing archive limits; never retain unbounded confirmed fragments.
        guard LearningProfile.normalizedInput(nextInput, language: nextLanguage).utf8.count <= 128,
              nextInput.utf8.count <= 512, nextText.utf8.count <= 512,
              commit.remainingInput.utf8.count <= 512,
              tokenCount + (candidate.lexicalTokenCount ?? 1) <= 512 else { invalidate(); return nil }
        input = nextInput
        text = nextText
        mixed = nextMixed
        language = nextLanguage
        corrected = corrected || commit.reason == .explicitSelection
        score += candidate.rankingScore
        tokenCount += candidate.lexicalTokenCount ?? 1
        pieces += 1
        remainder = commit.remainingInput
        guard commit.remainingInput.isEmpty, pieces > 1 else { return nil }
        let combined = InputCandidate(text: text, language: language, score: 0, isMixed: mixed,
                                      rankingScore: score, lexicalTokenCount: tokenCount)
        return InputCommit(input: input, candidate: combined,
                           reason: corrected ? .explicitSelection : .defaultAcceptance)
    }
}
