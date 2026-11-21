import Foundation

/// Immutable, transient work for one composition revision. No client/UI objects cross this boundary.
public struct CandidateRequest: Sendable {
    public enum RankingPolicy: Sendable {
        case engineOrder
        case app
    }

    public let id = UUID()
    fileprivate let input: String
    fileprivate let languages: Set<InputLanguage>
    fileprivate let engine: CandidateEngine
    fileprivate let learning: LearningProfile
    fileprivate let dictionary: UserDictionary
    fileprivate let now: Date
    fileprivate let context: CandidateContext?
    fileprivate let precedingText: String
    fileprivate let automaticConfirmationEnabled: Bool
    fileprivate let experimentalRankingEnabled: Bool
    fileprivate let rankingPolicy: RankingPolicy
    fileprivate let applicationMemory: ApplicationMemorySnapshot

    private var usesStatisticalOrder: Bool {
        rankingPolicy == .app && engine.pinyinCorrectionMode == .off
    }

    public var offersPreview: Bool { !usesStatisticalOrder }

    public func generate(useExperimentalRanking: Bool = false) -> CandidateResult {
        let useRanker = useExperimentalRanking && experimentalRankingEnabled && !usesStatisticalOrder
        let generated = engine.candidates(for: input, languages: languages, learning: learning, dictionary: dictionary,
                                           now: now, context: context, includesConfirmationEvidence: automaticConfirmationEnabled,
                                           applicationMemory: applicationMemory, precedingText: precedingText,
                                           experimentalRanking: useRanker)
        let candidates: [InputCandidate]
        if usesStatisticalOrder {
            candidates = Self.statisticalOrder(generated)
        } else if rankingPolicy == .app && useRanker {
            candidates = Self.limitModelOrder(generated)
        } else {
            candidates = generated
        }
        let isModelRanked = candidates.contains { $0.modelRankingScore != nil }
        return CandidateResult(requestID: id, candidates: candidates,
                               confirmationPrefixes: automaticConfirmationEnabled && !isModelRanked
                                ? AutomaticConfirmation.prefixes(for: candidates, input: input, learning: learning,
                                                                 now: now, context: context) : [])
    }

    public func generatePreview() -> CandidateResult {
        CandidateResult(requestID: id, candidates: engine.previewCandidates(
            for: input, languages: languages, learning: learning, dictionary: dictionary, now: now, context: context,
            applicationMemory: applicationMemory, precedingText: precedingText),
            isPreview: true)
    }

    private static func statisticalOrder(_ candidates: [InputCandidate]) -> [InputCandidate] {
        candidates.filter { !$0.isLiteral && !$0.isNeuralSuggestion }
            .sorted(by: InputCandidate.precedesInStatistics) + candidates.filter(\.isLiteral)
    }

    private static func limitModelOrder(_ candidates: [InputCandidate]) -> [InputCandidate] {
        let statistical = statisticalOrder(candidates)
        let prioritized = statistical.prefix { $0.isPreferred || $0.isRememberedChoice }
        let remaining = statistical.dropFirst(prioritized.count)
        guard let leader = remaining.first, !leader.isPartial, let best = leader.statisticalScore else {
            return statistical
        }
        let eligible = remaining.filter {
            !$0.isPartial && ($0.statisticalScore ?? -.infinity) >= best - 6
        }
        let scoredIDs = Set(eligible.lazy.filter { $0.modelRankingScore != nil }.map(\.id))
        guard !scoredIDs.isEmpty else { return statistical }
        let eligibleIDs = Set(eligible.map(\.id))
        var ranked = candidates.lazy.filter { scoredIDs.contains($0.id) }.makeIterator()
        // Unscored candidates keep their slots. The tail keeps statistical order.
        let head = eligible.map { scoredIDs.contains($0.id) ? ranked.next() ?? $0 : $0 }
        return Array(prioritized) + head + remaining.filter { !eligibleIDs.contains($0.id) }
    }
}

public struct CandidateResult: Sendable {
    fileprivate let requestID: UUID
    public let candidates: [InputCandidate]
    public let isPreview: Bool
    public var isModelRanked: Bool { candidates.contains { $0.modelRankingScore != nil } }
    fileprivate let confirmationPrefixes: [AutomaticConfirmation.Prefix]

    fileprivate init(requestID: UUID, candidates: [InputCandidate], isPreview: Bool = false,
                     confirmationPrefixes: [AutomaticConfirmation.Prefix] = []) {
        self.requestID = requestID
        self.candidates = candidates
        self.isPreview = isPreview
        self.confirmationPrefixes = confirmationPrefixes
    }
}

public struct InputSession: Sendable {
    public enum CandidateGeneration: Sendable { case synchronous, deferred }
    public static let contextLifetime: TimeInterval = 5 * 60
    private struct RecentContext: Sendable {
        let candidate: CandidateContext
        let committedAt: Date
    }
    public private(set) var buffer = ""
    public private(set) var cursor = 0
    public var cursorUTF16Offset: Int { buffer.prefix(cursor).utf16.count }
    public private(set) var candidates: [InputCandidate] = []
    public private(set) var pendingCandidateRequest: CandidateRequest?
    public private(set) var hasCandidatePreview = false
    public static let automaticConfirmationPause = AutomaticConfirmation.pauseDelay
    public private(set) var automaticConfirmationRevision: UInt64 = 0
    private var languages: Set<InputLanguage> = Set(InputLanguage.allCases)
    private var engine: CandidateEngine
    private let candidateGeneration: CandidateGeneration
    private var learning = LearningProfile()
    private var dictionary = UserDictionary()
    private var applicationMemory: ApplicationMemorySnapshot = .empty
    private var usesContext = false
    private var recentContext: RecentContext?
    private var precedingText = ""
    private var contextGeneration: UInt64 = 0
    private var experimentalRankingEnabled = false
    private var rankingPolicy: CandidateRequest.RankingPolicy = .engineOrder
    private var automaticConfirmationEnabled = false
    private var configurationGeneration: UInt64 = 0
    private var automaticConfirmation = AutomaticConfirmation()
    private var compositionLearning = CompositionLearning()
    private var compositionLearningEnabled = false

    public init(engine: CandidateEngine = CandidateEngine(), candidateGeneration: CandidateGeneration = .synchronous) {
        self.engine = engine
        self.candidateGeneration = candidateGeneration
    }

    public mutating func configure(languages: Set<InputLanguage>, learning: LearningProfile = LearningProfile(),
                                   dictionary: UserDictionary = UserDictionary(), usesContext: Bool = false,
                                   contextGeneration: UInt64 = 0, automaticConfirmationEnabled: Bool = false,
                                   configurationGeneration: UInt64 = 0, now: Date = .now,
                                   applicationMemory: ApplicationMemorySnapshot = .empty,
                                   compositionLearningEnabled: Bool = false,
                                   punctuationCandidatesEnabled: Bool = false,
                                   pinyinCorrectionMode: CandidateEngine.PinyinCorrectionMode = .off,
                                   experimentalRankingEnabled: Bool = false,
                                   rankingPolicy: CandidateRequest.RankingPolicy = .engineOrder) {
        if self.compositionLearningEnabled != compositionLearningEnabled || self.languages != languages
            || self.contextGeneration != contextGeneration || self.dictionary != dictionary
            || self.configurationGeneration != configurationGeneration {
            compositionLearning.invalidate()
        }
        self.compositionLearningEnabled = compositionLearningEnabled
        let languagesChanged = self.languages != languages
        let contextChanged = self.contextGeneration != contextGeneration
        let expired = recentContext.map { now.timeIntervalSince($0.committedAt) >= Self.contextLifetime || now < $0.committedAt } ?? false
        if expired { recentContext = nil }
        guard self.languages != languages || self.learning != learning || self.dictionary != dictionary
                || self.usesContext != usesContext || contextChanged || expired
                || self.automaticConfirmationEnabled != automaticConfirmationEnabled
                || self.experimentalRankingEnabled != experimentalRankingEnabled
                || self.rankingPolicy != rankingPolicy
                || self.configurationGeneration != configurationGeneration
                || engine.punctuationCandidatesEnabled != punctuationCandidatesEnabled
                || engine.pinyinCorrectionMode != pinyinCorrectionMode
                || self.applicationMemory != applicationMemory else { return }
        self.languages = languages
        self.learning = learning
        self.dictionary = dictionary
        self.applicationMemory = applicationMemory
        self.usesContext = usesContext
        self.contextGeneration = contextGeneration
        self.automaticConfirmationEnabled = automaticConfirmationEnabled
        self.experimentalRankingEnabled = experimentalRankingEnabled
        self.rankingPolicy = rankingPolicy
        self.configurationGeneration = configurationGeneration
        engine.punctuationCandidatesEnabled = punctuationCandidatesEnabled
        engine.pinyinCorrectionMode = pinyinCorrectionMode
        automaticConfirmation = AutomaticConfirmation()
        if !usesContext || languagesChanged || contextChanged { recentContext = nil }
        refresh(now: now)
    }

    public mutating func append(_ text: String, now: Date = .now) {
        guard !text.isEmpty else { return }
        if buffer.isEmpty { compositionLearning = CompositionLearning() }
        else { compositionLearning.edited() }
        let wasAtEnd = cursor == buffer.count
        let insertionEnd = cursorUTF16Offset + text.utf16.count
        let index = buffer.index(buffer.startIndex, offsetBy: cursor)
        buffer.insert(contentsOf: text, at: index)
        // Inserted scalars can join adjacent graphemes (accents, flags, emoji ZWJ sequences).
        // Place the caret at the next whole-character boundary, rather than counting fragments.
        cursor = 0
        var utf16Offset = 0
        for character in buffer {
            guard utf16Offset < insertionEnd else { break }
            utf16Offset += String(character).utf16.count
            cursor += 1
        }
        automaticConfirmation.appended(input: buffer, atEnd: wasAtEnd, now: now)
        refresh(now: now)
    }

    mutating func setPrecedingText(_ text: String) {
        guard !precedingText.utf8.elementsEqual(text.utf8) else { return }
        precedingText = text
        automaticConfirmation = AutomaticConfirmation()
        if !buffer.isEmpty { refresh() }
    }

    public mutating func deleteBackward() {
        compositionLearning.edited()
        suspendAutomaticConfirmation()
        guard cursor > 0 else { return }
        let index = buffer.index(buffer.startIndex, offsetBy: cursor - 1)
        buffer.remove(at: index)
        cursor -= 1
        refresh()
    }

    public mutating func deleteForward() {
        compositionLearning.edited()
        suspendAutomaticConfirmation()
        guard cursor < buffer.count else { return }
        buffer.remove(at: buffer.index(buffer.startIndex, offsetBy: cursor))
        refresh()
    }

    public mutating func moveCursor(by offset: Int) {
        suspendAutomaticConfirmation()
        cursor += max(-cursor, min(offset, buffer.count - cursor))
    }

    public mutating func moveToStart() { suspendAutomaticConfirmation(); cursor = 0 }
    public mutating func moveToEnd() { suspendAutomaticConfirmation(); cursor = buffer.count }

    @discardableResult
    public mutating func commit(_ candidate: InputCandidate? = nil) -> String {
        commitResult(candidate, reason: candidate == nil ? .literal : .explicitSelection).text
    }

    public mutating func commitResult(_ candidate: InputCandidate? = nil, reason: CommitReason, now: Date = .now) -> InputCommit {
        let validCandidate = candidate.flatMap { value -> InputCandidate? in
            guard let current = candidates.first(where: { $0.hasSameCommitValue(as: value) }) else { return nil }
            guard !current.requiresExplicitSelection || reason == .explicitSelection else { return nil }
            if let count = value.consumedInputCount, count <= 0 || count >= buffer.count { return nil }
            return current
        }
        return commitValidated(validCandidate, reason: validCandidate == nil ? .literal : reason, now: now)
    }

    private mutating func commitValidated(_ validCandidate: InputCandidate?, reason: CommitReason, now: Date) -> InputCommit {
        let count = validCandidate?.consumedInputCount ?? buffer.count
        let remaining = String(buffer.dropFirst(count))
        let remainingCursor = max(0, cursor - count)
        let result = InputCommit(input: String(buffer.prefix(count)), candidate: validCandidate,
                                 reason: validCandidate == nil ? .literal : reason, context: currentContext(now: now),
                                 remainingInput: remaining)
        let confirmedFragments = compositionLearning
        reset()
        compositionLearning = confirmedFragments
        if usesContext, reason.learningWeight > 0, let validCandidate,
           let context = CandidateContext(candidate: validCandidate) {
            recentContext = RecentContext(candidate: context, committedAt: now)
        }
        buffer = remaining
        cursor = min(remainingCursor, remaining.count)
        if !remaining.isEmpty { refresh(now: now) }
        return result
    }

    /// Never resolves a pending search synchronously. The timer and result callback share this path.
    public mutating func automaticallyConfirm(now: Date = .now, afterPause: Bool = false) -> InputCommit? {
        guard automaticConfirmationEnabled, pendingCandidateRequest == nil, !hasCandidatePreview,
              cursor == buffer.count, let candidate = automaticConfirmation.candidate(now: now, afterPause: afterPause)
        else { return nil }
        return commitValidated(candidate, reason: .automaticConfirmation, now: now)
    }

    public var hasAutomaticPauseCandidate: Bool {
        automaticConfirmationEnabled && pendingCandidateRequest == nil && !hasCandidatePreview
            && cursor == buffer.count && automaticConfirmation.hasPauseCandidate
    }

    public mutating func suspendAutomaticConfirmation() {
        automaticConfirmation.suspend()
        automaticConfirmationRevision &+= 1
    }

    public mutating func reset() {
        compositionLearning = CompositionLearning()
        automaticConfirmation = AutomaticConfirmation()
        automaticConfirmationRevision &+= 1
        buffer = ""
        cursor = 0
        candidates = []
        pendingCandidateRequest = nil
        hasCandidatePreview = false
        recentContext = nil
        precedingText = ""
    }

    public mutating func breakContext() {
        compositionLearning.invalidate()
        suspendAutomaticConfirmation()
        let hadContext = recentContext != nil
        guard hadContext else { return }
        recentContext = nil
        refresh()
    }

    /// Call only after a successful host insertion eligible for local learning.
    /// The returned value is learning evidence only, never another insertion/history event.
    public mutating func recordSuccessfulCommit(_ commit: InputCommit) -> InputCommit? {
        guard compositionLearningEnabled, buffer.utf8.elementsEqual(commit.remainingInput.utf8) else {
            compositionLearning.invalidate()
            return nil
        }
        return compositionLearning.record(commit)
    }

    public mutating func discardCompositionLearning() {
        compositionLearning.invalidate()
    }

    /// Inspect the lexical/preferences score plus coverage of the consumed spelling.
    public func presentationScore(for candidate: InputCandidate, now: Date = .now) -> Double {
        if let score = candidate.presentationScore { return score }
        let spelling = candidate.consumedInputCount.map { String(buffer.prefix($0)) } ?? buffer
        return learning.rankingScore(for: candidate, input: spelling, now: now, context: currentContext(now: now))
            + candidate.fieldContextAdjustment
            + CandidateScoring.inputCoverageBonus(for: candidate, spelling: spelling)
    }

    private func currentContext(now: Date = .now) -> CandidateContext? {
        guard usesContext, let recentContext, now >= recentContext.committedAt,
              now.timeIntervalSince(recentContext.committedAt) < Self.contextLifetime else { return nil }
        return recentContext.candidate
    }

    private mutating func refresh(now: Date = .now) {
        automaticConfirmationRevision &+= 1
        guard !buffer.isEmpty else {
            precedingText = ""
            candidates = []
            pendingCandidateRequest = nil
            hasCandidatePreview = false
            return
        }
        let request = CandidateRequest(input: buffer, languages: languages, engine: engine, learning: learning,
                                       dictionary: dictionary, now: now, context: currentContext(now: now),
                                       precedingText: precedingText,
                                       automaticConfirmationEnabled: automaticConfirmationEnabled,
                                       experimentalRankingEnabled: experimentalRankingEnabled,
                                       rankingPolicy: rankingPolicy,
                                       applicationMemory: applicationMemory)
        pendingCandidateRequest = request
        hasCandidatePreview = false
        if candidateGeneration == .synchronous {
            _ = accept(request.generate(), now: now)
        } else {
            // Old candidates must not be selected while new work is pending. Exact text remains available.
            candidates = [engine.literalCandidate(for: buffer)]
        }
    }

    @discardableResult
    public mutating func accept(_ result: CandidateResult, now: Date = .now) -> Bool {
        guard pendingCandidateRequest?.id == result.requestID else { return false }
        if result.isPreview && hasCandidatePreview { return false }
        candidates = result.candidates
        hasCandidatePreview = result.isPreview
        if !result.isPreview {
            pendingCandidateRequest = nil
            if automaticConfirmationEnabled { automaticConfirmation.observe(result.confirmationPrefixes, input: buffer, now: now) }
        }
        return true
    }

    /// Keep the visible list after the user starts navigating it.
    public mutating func retainPreview(insteadOf result: CandidateResult) -> Bool {
        guard result.isModelRanked, hasCandidatePreview,
              pendingCandidateRequest?.id == result.requestID else { return false }
        pendingCandidateRequest = nil
        return true
    }

    /// Resolve pending conversion for an explicit action.
    public mutating func resolveCandidates() {
        guard let request = pendingCandidateRequest else { return }
        // Keep the currently displayed choices actionable while final search runs on its worker.
        guard !hasCandidatePreview else { return }
        // An explicit action during startup can still commit the current literal.
        guard RustConversion.loaded != nil else { return }
        _ = accept(request.generate())
    }
}
