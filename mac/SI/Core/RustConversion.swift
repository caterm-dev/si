import Foundation
import CSIRust
import os

/// Owns one immutable Rust engine. The C ABI supports simultaneous const queries.
final class RustConversion: @unchecked Sendable {
    static let precedingTextUTF16Limit = Int(si_preceding_text_utf16_limit())
    private let engine: OpaquePointer
    private let correctionMode: PinyinCorrectionMode
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
        let grams = resourceDirectory.appendingPathComponent("words.sigram")
        #if SWIFT_PACKAGE
        let gramResource = FileManager.default.fileExists(atPath: grams.path) ? grams : nil
        #else
        let gramResource = grams
        #endif
        let engine = RustConversion(lexicon: lexicon, grams: gramResource,
                                    reranker: resourceDirectory.appendingPathComponent("RerankerSmall", isDirectory: true))
        ready.withLock { $0 = engine }
        return engine
    }()

    typealias PinyinCorrectionMode = CandidateEngine.PinyinCorrectionMode

    init?(lexicon: URL, grams: URL? = nil, correctionMode: PinyinCorrectionMode = .off, reranker: URL? = nil) {
        guard let handle = lexicon.withUnsafeFileSystemRepresentation({ lexiconPath in
            if let grams {
                return grams.withUnsafeFileSystemRepresentation { si_engine_open(lexiconPath, $0) }
            }
            return si_engine_open(lexiconPath, nil)
        }) else { return nil }
        if correctionMode != .off && !si_engine_set_correction(handle, correctionMode.rawValue) {
            si_engine_close(handle)
            return nil
        }
        if let reranker {
            _ = reranker.withUnsafeFileSystemRepresentation { si_engine_load_reranker(handle, $0) }
        }
        engine = handle
        self.correctionMode = correctionMode
    }

    private init(engine: OpaquePointer, correctionMode: PinyinCorrectionMode) {
        self.engine = engine
        self.correctionMode = correctionMode
    }

    deinit { si_engine_close(engine) }

    func loadUserModel(at profile: URL) throws -> RustConversion? {
        var handle: OpaquePointer?
        guard profile.withUnsafeFileSystemRepresentation({ si_engine_load_user(engine, $0, &handle) }) else {
            throw SentenceLearningStore.StoreError.profile
        }
        return handle.map { RustConversion(engine: $0, correctionMode: correctionMode) }
    }

    func openAppLearning(at directory: URL, bundle: String) -> OpaquePointer? {
        directory.withUnsafeFileSystemRepresentation { path in
            bundle.withCString { si_app_learning_open(engine, path, $0) }
        }
    }

    var userEntries: [UserLexiconEntry] {
        var entries: [UserLexiconEntry] = []
        var row = SIUserEntryView()
        while si_engine_user_entry(engine, entries.count, &row) {
            let text = String(decoding: UnsafeBufferPointer(start: row.text, count: row.text_bytes), as: UTF8.self)
            let reading = String(decoding: UnsafeBufferPointer(start: row.reading, count: row.reading_bytes), as: UTF8.self)
            entries.append(UserLexiconEntry(text: text, reading: reading, index: row.index, count: row.count))
        }
        return entries
    }

    static func editUserEntry(at profile: URL, old: UserLexiconEntry?, new: UserLexiconEntry?) throws {
        func withEntry<T>(_ entry: UserLexiconEntry?, _ body: (UnsafePointer<SIUserEntryView>?) -> T) -> T {
            guard let entry else { return body(nil) }
            return Array(entry.text.utf8).withUnsafeBufferPointer { text in
                Array(entry.reading.utf8).withUnsafeBufferPointer { reading in
                    var row = SIUserEntryView(text: text.baseAddress, text_bytes: text.count,
                                              reading: reading.baseAddress, reading_bytes: reading.count,
                                              index: entry.index, count: entry.count)
                    return withUnsafePointer(to: &row, body)
                }
            }
        }
        let saved = profile.withUnsafeFileSystemRepresentation { path in
            withEntry(old) { old in withEntry(new) { si_engine_edit_user_entry(path, old, $0) } }
        }
        guard saved else { throw SentenceLearningStore.StoreError.profile }
    }

    func ingestUserSentences(_ sentences: [String], batchID: UUID, at profile: URL) throws {
        var bytes: [UInt8] = []
        let ends = sentences.map { sentence in
            bytes.append(contentsOf: sentence.utf8)
            return bytes.count
        }
        guard profile.withUnsafeFileSystemRepresentation({ path in
            batchID.uuidString.withCString { id in
                bytes.withUnsafeBufferPointer { text in
                    ends.withUnsafeBufferPointer {
                        si_engine_ingest_user(engine, path, id, text.baseAddress, text.count, $0.baseAddress, $0.count)
                    }
                }
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
                    context: CandidateContext? = nil, precedingText: String? = nil,
                    precedingTextCache: PrecedingTextCache? = nil,
                    correctionMode: PinyinCorrectionMode? = nil, rerankingEnabled: Bool = false) -> [InputCandidate] {
        let mode = correctionMode ?? self.correctionMode
        var mask: UInt8 = 0
        if languages.contains(.simplifiedChinese) { mask |= 1 }
        if languages.contains(.english) { mask |= 2 }
        guard mask != 0, !input.isEmpty else { return [] }

        let offsets = Self.sourceOffsets(input)
        let bytes = Array(input.utf8)
        let learned = learning.tokenPreferences(for: input, now: now)
        let paths = learning.pathPreferences(for: input, now: now, context: context)
        let hasPrecedingText = precedingText != nil
        var precedingText = precedingText ?? ""
        var emptyPrefix: UInt8 = 0
        let result = withExtendedLifetime(precedingTextCache) {
            withRows(dictionary.entries, learned, paths) { phrases, tokens, paths in
                bytes.withUnsafeBufferPointer { input in
                    precedingText.withUTF8 { preceding in
                        withUnsafePointer(to: &emptyPrefix) { empty in
                            si_engine_candidates_with_context_cache(
                                engine, input.baseAddress, input.count,
                                hasPrecedingText ? preceding.baseAddress ?? empty : nil, preceding.count,
                                mask, preview, phrases.baseAddress, phrases.count,
                                tokens.baseAddress, tokens.count, paths.baseAddress, paths.count,
                                mode.rawValue, rerankingEnabled, precedingTextCache?.handle)
                        }
                    }
                }
            }
        }
        guard let result else { return [] }
        defer { si_candidates_free(result) }
        return (0..<si_candidates_count(result)).compactMap { index in
            var row = SICandidateView()
            guard si_candidates_get(result, index, &row), row.language != 0,
                  let start = row.text, row.text_bytes > 0, row.score_bits.isFinite,
                  let characters = offsets[row.consumed_bytes], characters > 0,
                  (1...3).contains(row.language) else { return nil }
            var correction = SICorrectionView()
            let isCorrection = mode != .off && si_candidates_get_correction(result, index, &correction)
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
                confirmationBoundaries: confirmation, isPinyinCorrection: isCorrection).withDisplaySourceBoundaries(boundaries)
            if (candidate.canLearn || isCorrection) && row.context_adjustment.isFinite {
                candidate.fieldContextAdjustment = row.context_adjustment
            }
            candidate.rerankingBonus = row.reranking_bonus
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
