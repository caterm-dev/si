import Foundation
import CSIRust
import os

/// Owns one immutable Rust engine. The C ABI supports simultaneous const queries.
final class RustConversion: @unchecked Sendable {
    private let engine: OpaquePointer
    private static let ready = OSAllocatedUnfairLock<RustConversion?>(initialState: nil)
    static var loaded: RustConversion? { ready.withLock { $0 } }

    static let shared: RustConversion? = {
        #if SWIFT_PACKAGE
        let resourceDirectory = ProcessInfo.processInfo.environment["SI_ENGINE_RESOURCE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        let resourceDirectory = Bundle.main.resourceURL?.appendingPathComponent("SIEngine", isDirectory: true)
        #endif
        guard let resourceDirectory else { return nil }
        let lexicon = resourceDirectory.appendingPathComponent("main.silex")
        #if SWIFT_PACKAGE
        let engine = RustConversion(lexicon: lexicon)
        #else
        let grams = resourceDirectory.appendingPathComponent("words.sigram")
        let engine = RustConversion(lexicon: lexicon, grams: grams)
        #endif
        ready.withLock { $0 = engine }
        return engine
    }()

    init?(lexicon: URL, grams: URL? = nil) {
        guard let handle = lexicon.withUnsafeFileSystemRepresentation({ lexiconPath in
            if let grams {
                return grams.withUnsafeFileSystemRepresentation { si_engine_open(lexiconPath, $0) }
            }
            return si_engine_open(lexiconPath, nil)
        }) else { return nil }
        engine = handle
    }

    private init(engine: OpaquePointer) { self.engine = engine }

    deinit { si_engine_close(engine) }

    func loadUserModel(at profile: URL) throws -> RustConversion? {
        var handle: OpaquePointer?
        guard profile.withUnsafeFileSystemRepresentation({ si_engine_load_user(engine, $0, &handle) }) else {
            throw SentenceLearningStore.StoreError.profile
        }
        return handle.map(RustConversion.init(engine:))
    }

    func ingestUserSentences(_ sentences: [String], batchID: UUID, at profile: URL) throws {
        var text = sentences.joined(separator: "\n")
        guard profile.withUnsafeFileSystemRepresentation({ path in
            batchID.uuidString.withCString { id in
                text.withUTF8 { si_engine_ingest_user(engine, path, id, $0.baseAddress, $0.count) }
            }
        }) else { throw SentenceLearningStore.StoreError.profile }
    }

    static func clearUserModel(at profile: URL) throws {
        guard profile.withUnsafeFileSystemRepresentation({ si_engine_clear_user($0) }) else {
            throw SentenceLearningStore.StoreError.profile
        }
    }

    func hasEnglishWordPrefix(_ input: String, minimum: Int) -> Bool {
        Array(input.utf8).withUnsafeBufferPointer {
            si_engine_has_english_word_prefix(engine, $0.baseAddress, $0.count, minimum)
        }
    }

    func candidates(for input: String, languages: Set<InputLanguage>, preview: Bool = false,
                    dictionary: UserDictionary = UserDictionary(), includesConfirmation: Bool = false,
                    learning: LearningProfile = LearningProfile(), now: Date = .now,
                    context: CandidateContext? = nil, precedingText: String = "") -> [InputCandidate] {
        var mask: UInt8 = 0
        if languages.contains(.simplifiedChinese) { mask |= 1 }
        if languages.contains(.english) { mask |= 2 }
        guard mask != 0, !input.isEmpty else { return [] }

        let offsets = Self.sourceOffsets(input)
        let bytes = Array(input.utf8)
        let learned = learning.tokenPreferences(for: input, now: now)
        let paths = learning.pathPreferences(for: input, now: now, context: context)
        var precedingText = precedingText
        guard let result = withRows(dictionary.entries, learned, paths, { phrases, tokens, paths in
            bytes.withUnsafeBufferPointer { input in
                precedingText.withUTF8 { preceding in
                    si_engine_candidates(engine, input.baseAddress, input.count, preceding.baseAddress, preceding.count,
                                         mask, preview, phrases.baseAddress, phrases.count,
                                         tokens.baseAddress, tokens.count, paths.baseAddress, paths.count)
                }
            }
        }) else { return [] }
        defer { si_candidates_free(result) }
        return (0..<si_candidates_count(result)).compactMap { index in
            var row = SICandidateView()
            guard si_candidates_get(result, index, &row), row.language != 0,
                  let start = row.text, row.text_bytes > 0, row.score_bits.isFinite,
                  let characters = offsets[row.consumed_bytes], characters > 0,
                  (1...3).contains(row.language) else { return nil }
            let output = String(decoding: UnsafeBufferPointer(start: start, count: row.text_bytes), as: UTF8.self)
            let language: InputLanguage = row.language == 2 ? .english : .simplifiedChinese
            let boundaries = UnsafeBufferPointer(start: row.source_boundaries, count: row.source_boundary_count)
                .compactMap { offsets[$0] }
            let confirmation = UnsafeBufferPointer(start: row.confirmation_boundaries,
                count: includesConfirmation && !row.personal && row.language == 1 ? row.confirmation_boundary_count : 0)
                .compactMap { boundary -> ConfirmationBoundary? in
                    guard let count = offsets[boundary.source_bytes], count <= characters,
                          (1...row.text_bytes).contains(boundary.output_bytes) else { return nil }
                    return ConfirmationBoundary(sourceCount: count, outputByteCount: boundary.output_bytes)
                }
            var candidate = InputCandidate(text: output, language: language,
                score: Int(row.score_bits.rounded(.towardZero)), isMixed: row.language == 3,
                isUserPhrase: row.personal,
                hasLiteralSegments: row.verbatim,
                consumedInputCount: row.consumed_bytes < bytes.count ? characters : nil,
                rankingScore: row.score_bits, hasCompletion: row.completion, tokenLearningBonus: row.token_bonus,
                isPreferred: row.preferred,
                lexicalTokenCount: row.lexical_tokens,
                confirmationBoundaries: confirmation).withDisplaySourceBoundaries(boundaries)
            if candidate.canLearn && row.context_adjustment.isFinite {
                candidate.fieldContextAdjustment = row.context_adjustment
            }
            return row.language == 1 && row.lexical_tokens > 1 ? candidate.withChineseSentenceOrigin() : candidate
        }
    }

    private func withRows<T>(_ phrases: [UserPhrase], _ learned: [(entry: LearnedPreference, bonus: Double)],
                             _ paths: [LearningProfile.PathPreference],
                             _ body: (UnsafeBufferPointer<SIUserPhrase>, UnsafeBufferPointer<SILearnedToken>,
                                      UnsafeBufferPointer<SILearnedPath>) -> T) -> T {
        var bytes: [UInt8] = []
        func append(_ spelling: String, _ text: String) -> (Int, Int, Int) {
            let spellingStart = bytes.count
            bytes.append(contentsOf: spelling.utf8)
            let textStart = bytes.count
            bytes.append(contentsOf: text.utf8)
            return (spellingStart, textStart, bytes.count)
        }
        let phraseSpans = phrases.map { append($0.input, $0.text) }
        let tokenSpans = learned.map { append($0.entry.input, $0.entry.text) }
        let pathSpans = paths.map { append("", $0.text) }
        return bytes.withUnsafeBufferPointer { buffer in
            let rows = zip(phrases, phraseSpans).map { phrase, span in
                SIUserPhrase(spelling: buffer.baseAddress?.advanced(by: span.0),
                             spelling_bytes: span.1 - span.0,
                             text: buffer.baseAddress?.advanced(by: span.1),
                             text_bytes: span.2 - span.1,
                             language: phrase.language == .english ? 2 : 1, pinned: phrase.isPinned)
            }
            let tokens = zip(learned, tokenSpans).map { token, span in
                SILearnedToken(spelling: buffer.baseAddress?.advanced(by: span.0),
                               spelling_bytes: span.1 - span.0,
                               text: buffer.baseAddress?.advanced(by: span.1),
                               text_bytes: span.2 - span.1,
                               language: token.entry.language == .english ? 2 : 1, bonus: token.bonus)
            }
            let pathRows = zip(paths, pathSpans).map { path, span in
                SILearnedPath(consumed_bytes: path.consumedBytes,
                              text: buffer.baseAddress?.advanced(by: span.1), text_bytes: span.2 - span.1,
                              language: path.language, frequency: path.frequency, contextual: path.contextual)
            }
            return rows.withUnsafeBufferPointer { phrases in
                tokens.withUnsafeBufferPointer { tokens in
                    pathRows.withUnsafeBufferPointer { body(phrases, tokens, $0) }
                }
            }
        }
    }

    private static func sourceOffsets(_ input: String) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var bytes = 0
        for (index, character) in input.enumerated() {
            bytes += String(character).utf8.count
            result[bytes] = index + 1
        }
        return result
    }
}
