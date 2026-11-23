import CSIRust

/// Stateless translation to SI engine presentation policy. UI/session state stays in Swift.
enum RustCandidatePresentation {
    static let limits: (ordinary: Int, words: Int) = {
        let limits = si_presentation_limits()
        return (limits.ordinary, limits.words)
    }()

    static func merge(_ candidates: [InputCandidate], input: String, languages: Set<InputLanguage>,
                      coverageOrder: Bool) -> [InputCandidate] {
        var mask: UInt8 = 0
        if languages.contains(.simplifiedChinese) { mask |= 1 }
        if languages.contains(.english) { mask |= 2 }
        return withRows(candidates, input: input) { rows in
            var spelling = input
            let result = spelling.withUTF8 {
                si_presentation_merge($0.baseAddress, $0.count, mask, coverageOrder, rows.baseAddress, rows.count)
            }
            return read(result, candidates: candidates) { candidate, row in
                if candidate.isLiteral { return candidate }
                return candidate.withPresentationScore(row.presentation_score, remembered: row.remembered,
                                                        statisticalScore: candidate.statisticalScore)
                    .withPresentationEvidence(lexicalTokenCount: row.lexical_tokens > 0 ? row.lexical_tokens : nil,
                                              chineseSentence: row.chinese_sentence)
            }
        }
    }

    static func shortlist(_ candidates: [InputCandidate]) -> [InputCandidate] {
        withRows(candidates) { rows in
            read(si_presentation_shortlist(rows.baseAddress, rows.count), candidates: candidates) { candidate, _ in candidate }
        }
    }

    static func statisticalLeader(in candidates: [InputCandidate]) -> InputCandidate? {
        withRows(candidates) { rows in
            let index = si_presentation_statistical_leader(rows.baseAddress, rows.count)
            return candidates.indices.contains(index) ? candidates[index] : nil
        }
    }

    static func coverageBonus(for candidate: InputCandidate, spelling: String) -> Double {
        var spelling = spelling
        return spelling.withUTF8 {
            si_presentation_coverage_bonus($0.baseAddress, $0.count, candidate.isLiteral, candidate.hasLiteralSegments)
        }
    }

    private static func read(_ result: OpaquePointer?, candidates: [InputCandidate],
                             transform: (InputCandidate, SIPresentationRow) -> InputCandidate) -> [InputCandidate] {
        // Invalid bridge metadata must not remove the exact original input.
        guard let result else { return candidates.filter(\.isLiteral) }
        defer { si_presentation_free(result) }
        return (0..<si_presentation_count(result)).compactMap { index in
            var row = SIPresentationRow()
            guard si_presentation_get(result, index, &row), candidates.indices.contains(row.index) else { return nil }
            return transform(candidates[row.index], row)
        }
    }

    private static func withRows<T>(_ candidates: [InputCandidate], input: String? = nil,
                                    _ body: (UnsafeBufferPointer<SIPresentationCandidate>) -> T) -> T {
        // The C ABI uses UTF-8 source offsets; the session's public spans count Characters.
        var sourceBytes = [0]
        if let input {
            for character in input { sourceBytes.append(sourceBytes.last! + String(character).utf8.count) }
        }
        var bytes: [UInt8] = []
        let spans = candidates.map { candidate in
            let start = bytes.count
            bytes.append(contentsOf: candidate.id.utf8)
            let text = bytes.count
            bytes.append(contentsOf: candidate.text.utf8)
            return (start, text, bytes.count)
        }
        return bytes.withUnsafeBufferPointer { buffer in
            let rows = zip(candidates, spans).map { candidate, span in
                var flags: UInt32 = 0
                if candidate.isPreferred { flags |= UInt32(SI_PRESENTATION_PREFERRED) }
                if candidate.isRememberedChoice { flags |= UInt32(SI_PRESENTATION_REMEMBERED) }
                if candidate.isUserPhrase { flags |= UInt32(SI_PRESENTATION_PERSONAL) }
                if candidate.punctuationLanguage != nil || candidate.isPunctuation { flags |= UInt32(SI_PRESENTATION_PUNCTUATION) }
                if candidate.hasCompletion { flags |= UInt32(SI_PRESENTATION_COMPLETION) }
                if candidate.hasLiteralSegments { flags |= UInt32(SI_PRESENTATION_VERBATIM) }
                if candidate.isPinyinCorrection { flags |= UInt32(SI_PRESENTATION_CORRECTED) }
                if candidate.isChineseSentence { flags |= UInt32(SI_PRESENTATION_CHINESE_SENTENCE) }
                let consumed: Int
                if let count = candidate.consumedInputCount {
                    // Shortlisting compares span lengths only; merging validates byte boundaries.
                    consumed = input == nil ? count : (sourceBytes.indices.contains(count) ? sourceBytes[count] : 0)
                } else {
                    consumed = -1 // SIZE_MAX: whole input.
                }
                let language: UInt8 = candidate.isLiteral ? 0 : candidate.isMixed ? 3 : candidate.language == .english ? 2 : 1
                return SIPresentationCandidate(identity: buffer.baseAddress?.advanced(by: span.0),
                    identity_bytes: span.1 - span.0, text: buffer.baseAddress?.advanced(by: span.1),
                    text_bytes: span.2 - span.1, consumed_bytes: consumed,
                    lexical_tokens: candidate.lexicalTokenCount ?? 0, lexical_score: candidate.rankingScore,
                    statistical_score: candidate.statisticalScore ?? 0, reranking_bonus: candidate.rerankingBonus,
                    flags: flags, language: language, has_statistical_score: candidate.statisticalScore != nil)
            }
            return rows.withUnsafeBufferPointer(body)
        }
    }
}
