//! Versioned, label-free features shared by offline export and runtime reranking.
use crate::{Candidate, CandidateLanguage, ConversionPreferences};

/// Evidence from the exact derivation supplying the candidate's score.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PathEvidence {
    // Exact selected path, retained only during explicit offline extraction.
    pub(crate) words: Vec<EvidenceWord>,
    pub(crate) statistics: Vec<Option<f64>>,
    pub abbreviated_syllables: usize,
    pub missing_letters: usize,
    pub correction_cost_bits: f64,
    pub chinese_tokens: usize,
    pub gram_model_available: bool,
    pub unigram_bits: f64,
    pub gram_adjustment_bits: f64,
    pub token_cost_bits: f64,
    pub language_cost_bits: f64,
    pub spelling_cost_bits: f64,
    pub gram_hit_tokens: usize,
    pub max_gram_order: usize,
    pub gram_log_support: f64,
    pub context_history_words: usize,
    pub context_matched: bool,
    pub context_gram_order: usize,
    pub context_log_support: f64,
    pub tokens: usize,
    pub single_character_tokens: usize,
    pub min_token_scalars: usize,
    pub max_token_scalars: usize,
    pub language_switches: usize,
    pub abbreviated_tokens: usize,
    pub pinyin_syllables: usize,
    pub aligned_separators: usize,
    pub word_boundary_separators: usize,
    pub has_direct_match: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct EvidenceWord {
    pub language: u8,
    pub base: Option<si_lexicon::WordId>,
    pub user: Option<si_lexicon::WordId>,
}

impl PathEvidence {
    pub(crate) fn append(&self, next: &Self) -> Self {
        Self {
            words: self.words.iter().chain(&next.words).cloned().collect(),
            statistics: Vec::new(),
            abbreviated_syllables: self.abbreviated_syllables + next.abbreviated_syllables,
            missing_letters: self.missing_letters + next.missing_letters,
            correction_cost_bits: self.correction_cost_bits + next.correction_cost_bits,
            chinese_tokens: self.chinese_tokens + next.chinese_tokens,
            unigram_bits: self.unigram_bits + next.unigram_bits,
            gram_adjustment_bits: self.gram_adjustment_bits + next.gram_adjustment_bits,
            token_cost_bits: self.token_cost_bits + next.token_cost_bits,
            language_cost_bits: self.language_cost_bits + next.language_cost_bits,
            spelling_cost_bits: self.spelling_cost_bits + next.spelling_cost_bits,
            gram_hit_tokens: self.gram_hit_tokens + next.gram_hit_tokens,
            max_gram_order: self.max_gram_order.max(next.max_gram_order),
            gram_log_support: self.gram_log_support + next.gram_log_support,
            tokens: self.tokens + next.tokens,
            single_character_tokens: self.single_character_tokens + next.single_character_tokens,
            min_token_scalars: self.min_token_scalars.min(next.min_token_scalars),
            max_token_scalars: self.max_token_scalars.max(next.max_token_scalars),
            language_switches: self.language_switches + next.language_switches,
            abbreviated_tokens: self.abbreviated_tokens + next.abbreviated_tokens,
            pinyin_syllables: self.pinyin_syllables + next.pinyin_syllables,
            aligned_separators: self.aligned_separators + next.aligned_separators,
            word_boundary_separators: self.word_boundary_separators + next.word_boundary_separators,
            has_direct_match: false,
            ..self.clone()
        }
    }
}

pub const SCHEMA: &str = "si-rank-features-v3";
pub const V1_NAMES: [&str; 12] = [
    "lexical_bits",
    "context_bits",
    "effective_bits",
    "consumed_scalars",
    "output_scalars",
    "lexical_tokens",
    "bits_per_source_scalar",
    "bits_per_output_scalar",
    "is_chinese",
    "is_english",
    "is_mixed",
    "separator_count",
];

pub const V2_NAMES: [&str; 38] = [
    "lexical_bits",
    "context_bits",
    "effective_bits",
    "consumed_scalars",
    "output_scalars",
    "lexical_tokens",
    "bits_per_source_scalar",
    "bits_per_output_scalar",
    "is_chinese",
    "is_english",
    "is_mixed",
    "separator_count",
    "unigram_bits",
    "gram_adjustment_bits",
    "token_cost_bits",
    "language_cost_bits",
    "spelling_cost_bits",
    "gram_hit_fraction",
    "max_gram_order",
    "gram_log_support",
    "gram_model_available",
    "context_available",
    "context_history_words",
    "context_matched",
    "context_gram_order",
    "context_log_support",
    "best_path_tokens",
    "has_direct_match",
    "single_character_tokens",
    "min_token_scalars",
    "max_token_scalars",
    "language_switches",
    "abbreviated_tokens",
    "pinyin_syllables",
    "aligned_separators",
    "normalized_input_units",
    "bits_per_normalized_unit",
    "word_boundary_separators",
];

/// Only complete, noncompletion dictionary paths are eligible in protocol v1.
/// Prefixes, personal and verbatim paths need separate supervision and policies.
pub fn extract_v1(source: &str, candidate: &Candidate) -> Option<[f64; 12]> {
    if source.is_empty()
        || candidate.consumed_bytes != source.len()
        || candidate.language == CandidateLanguage::Literal
        || candidate.completion
        || candidate.personal
        || candidate.verbatim
        || candidate.is_corrected()
        || candidate.preferred
    {
        return None;
    }
    let score = candidate.score_bits?;
    let input_len = source.chars().count() as f64;
    let output_len = candidate.text.chars().count() as f64;
    if output_len == 0.0 {
        return None;
    }
    let values = [
        score,
        candidate.context_adjustment,
        score + candidate.context_adjustment,
        input_len,
        output_len,
        candidate.lexical_tokens as f64,
        score / input_len,
        score / output_len,
        f64::from(candidate.language == CandidateLanguage::Chinese),
        f64::from(candidate.language == CandidateLanguage::English),
        f64::from(candidate.language == CandidateLanguage::Mixed),
        source.chars().filter(|c| *c == '\'').count() as f64,
    ];
    values
        .iter()
        .all(|value| value.is_finite())
        .then_some(values)
}

/// V2 keeps the first twelve columns byte-compatible with the v1 feature meanings.
pub fn extract_v2(source: &str, context: &str, candidate: &Candidate) -> Option<Vec<f64>> {
    let mut values = extract_v1(source, candidate)?.to_vec();
    let evidence = candidate.ranking_evidence.as_ref()?;
    let units = crate::conversion::normalized_units(source) as f64;
    if evidence.tokens == 0 || units == 0.0 {
        return None;
    }
    values.extend([
        evidence.unigram_bits,
        evidence.gram_adjustment_bits,
        evidence.token_cost_bits,
        evidence.language_cost_bits,
        evidence.spelling_cost_bits,
        evidence.gram_hit_tokens as f64 / evidence.tokens as f64,
        evidence.max_gram_order as f64,
        evidence.gram_log_support,
        f64::from(evidence.gram_model_available),
        f64::from(!context.is_empty()),
        evidence.context_history_words as f64,
        f64::from(evidence.context_matched),
        evidence.context_gram_order as f64,
        evidence.context_log_support,
        evidence.tokens as f64,
        f64::from(evidence.has_direct_match),
        evidence.single_character_tokens as f64,
        evidence.min_token_scalars as f64,
        evidence.max_token_scalars as f64,
        evidence.language_switches as f64,
        evidence.abbreviated_tokens as f64,
        evidence.pinyin_syllables as f64,
        evidence.aligned_separators as f64,
        units,
        candidate.score_bits? / units,
        evidence.word_boundary_separators as f64,
    ]);
    values
        .iter()
        .all(|value| value.is_finite())
        .then_some(values)
}

/// Missing observations are None, never numeric zero or nonfinite JSON numbers.
pub const NAMES: [&str; 43] = [
    "word_log_count_mean",
    "word_log_count_min",
    "unigram_logp_sum",
    "unigram_logp_mean",
    "unigram_logp_min",
    "internal_ngram_logp_sum",
    "internal_ngram_logp_mean",
    "internal_ngram_logp_min",
    "internal_ngram_hit_ratio",
    "internal_ngram_max_order",
    "internal_ngram_log_support_mean",
    "context_available",
    "at_sentence_start",
    "context_history_words",
    "candidate_context_logp",
    "candidate_context_gain",
    "context_ngram_hit_order",
    "is_exact_spelling",
    "abbreviated_syllable_ratio",
    "completion_missing_letters",
    "explicit_separator_alignment",
    "token_count",
    "single_han_token_ratio",
    "language_switch_count",
    "candidate_language",
    "user_lexicon_available",
    "user_word_hit_ratio",
    "user_word_log_count_mean",
    "user_word_log_count_min",
    "user_unigram_logp_mean",
    "user_unigram_lift_mean",
    "user_gram_available",
    "user_internal_ngram_hit_ratio",
    "user_internal_ngram_log_support_mean",
    "user_internal_ngram_gain_mean",
    "user_context_ngram_log_support",
    "user_candidate_context_gain",
    "is_corrected",
    "correction_edit_count",
    "correction_cost_bits",
    "correction_missing_key",
    "correction_neighbor_key",
    "correction_adjacent_swap",
];

pub const V5_LEXICAL_SCHEMA: &str = "si-rank-features-v5-lexical";
pub const V5_ADDITIONS: [&str; 12] = [
    "abbreviated_token_count",
    "abbreviated_syllable_count",
    "pinyin_syllable_count",
    "english_token_count",
    "single_han_token_count",
    "is_completion",
    "has_exact_dictionary_match",
    "base_gram_available",
    "lexical_score_bits",
    "field_context_adjustment_bits",
    "user_choice_whole_bonus",
    "user_choice_token_bonus",
];

/// V5 scores same-span dictionary completions and adds evidence observed before selection.
pub fn extract_v5(
    source: &str,
    context: &str,
    context_available: bool,
    candidate: &Candidate,
    preferences: ConversionPreferences<'_>,
) -> Option<Vec<Option<f64>>> {
    let mut values = extract_path(source, context, context_available, candidate)?;
    let evidence = candidate.ranking_evidence.as_ref()?;
    let has_preferences = !preferences.paths.is_empty() || !preferences.tokens.is_empty();
    let whole = has_preferences.then(|| {
        preferences
            .paths
            .iter()
            .take(5_000)
            .rev()
            .find(|item| {
                item.consumed_bytes == candidate.consumed_bytes
                    && item.language == candidate.language
                    && item.text == candidate.text
                    && item.frequency.is_finite()
                    && item.contextual.is_finite()
            })
            .map_or(0.0, |item| item.frequency.clamp(0.0, 32.0))
    });
    values.extend([
        Some(evidence.abbreviated_tokens as f64),
        Some(evidence.abbreviated_syllables as f64),
        Some(evidence.pinyin_syllables as f64),
        Some(evidence.tokens.saturating_sub(evidence.chinese_tokens) as f64),
        Some(evidence.single_character_tokens as f64),
        Some(f64::from(candidate.completion)),
        Some(f64::from(
            evidence.has_direct_match && candidate.correction.is_none(),
        )),
        Some(f64::from(evidence.gram_model_available)),
        candidate.score_bits,
        context_available.then_some(candidate.context_adjustment),
        whole,
        has_preferences.then_some(candidate.token_bonus),
    ]);
    values
        .iter()
        .flatten()
        .all(|value| value.is_finite())
        .then_some(values)
}

pub fn extract(source: &str, context: &str, candidate: &Candidate) -> Option<Vec<Option<f64>>> {
    extract_with_context_state(source, context, !context.is_empty(), candidate)
}

/// Known empty context is a field start; unavailable context has unknown sentence position.
pub fn extract_with_context_state(
    source: &str,
    context: &str,
    context_available: bool,
    candidate: &Candidate,
) -> Option<Vec<Option<f64>>> {
    if candidate.completion {
        return None;
    }
    extract_path(source, context, context_available, candidate)
}

fn extract_path(
    source: &str,
    context: &str,
    context_available: bool,
    candidate: &Candidate,
) -> Option<Vec<Option<f64>>> {
    if source.is_empty()
        || candidate.consumed_bytes != source.len()
        || candidate.language == CandidateLanguage::Literal
        || candidate.personal
        || candidate.verbatim
        || candidate.preferred
        || !candidate.score_bits.is_some_and(f64::is_finite)
    {
        return None;
    }
    let evidence = candidate.ranking_evidence.as_ref()?;
    let mut values = evidence.statistics.clone();
    if values.len() != NAMES.len() {
        return None;
    }
    values[11] = Some(f64::from(context_available));
    values[12] = context_available.then(|| f64::from(at_sentence_start(context)));
    if !context_available {
        for i in [13, 14, 15, 16, 35, 36] {
            values[i] = None;
        }
    }
    values[17] = Some(f64::from(
        evidence.abbreviated_tokens == 0
            && evidence.missing_letters == 0
            && candidate.correction.is_none(),
    ));
    values[18] = (evidence.pinyin_syllables > 0)
        .then(|| evidence.abbreviated_syllables as f64 / evidence.pinyin_syllables as f64);
    values[19] = Some(evidence.missing_letters as f64);
    let separators = source.chars().filter(|c| *c == '\'').count();
    values[20] = (separators > 0).then(|| evidence.aligned_separators as f64 / separators as f64);
    values[21] = Some(evidence.tokens as f64);
    values[22] = (evidence.chinese_tokens > 0)
        .then(|| evidence.single_character_tokens as f64 / evidence.chinese_tokens as f64);
    values[23] = Some(evidence.language_switches as f64);
    values[24] = Some(match candidate.language {
        CandidateLanguage::Chinese => 0.0,
        CandidateLanguage::English => 1.0,
        CandidateLanguage::Mixed => 2.0,
        CandidateLanguage::Literal => return None,
    });
    use crate::conversion::CorrectionKind;
    let kind = candidate.correction.map(|c| c.kind);
    values[37] = Some(f64::from(kind.is_some()));
    // The current decoder permits exactly one edit per corrected candidate.
    values[38] = values[37];
    values[39] = Some(evidence.correction_cost_bits);
    values[40] = Some(f64::from(kind == Some(CorrectionKind::MissingKey)));
    values[41] = Some(f64::from(kind == Some(CorrectionKind::NeighborKey)));
    values[42] = Some(f64::from(kind == Some(CorrectionKind::AdjacentSwap)));
    values
        .iter()
        .flatten()
        .all(|v| v.is_finite())
        .then_some(values)
}

fn at_sentence_start(context: &str) -> bool {
    // Keep line boundaries significant while ignoring closing quotes and horizontal space.
    let tail = context.trim_end_matches(|c: char| {
        (c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}'))
            || matches!(
                c,
                '"' | '\'' | '”' | '’' | '」' | '』' | ')' | '）' | '】' | '》'
            )
    });
    tail.chars().next_back().is_none_or(|c| {
        matches!(
            c,
            '.' | '?' | '!' | '。' | '？' | '！' | '…' | '\n' | '\r' | '\u{2028}' | '\u{2029}'
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate() -> Candidate {
        Candidate {
            text: "绿色".into(),
            language: CandidateLanguage::Chinese,
            consumed_bytes: 5,
            score_bits: Some(-8.0),
            context_adjustment: 2.0,
            completion: false,
            lexical_tokens: 1,
            source_boundaries: vec![5],
            confirmation_boundaries: vec![],
            personal: false,
            preferred: false,
            verbatim: false,
            correction: None,
            token_bonus: 0.0,
            ranking_evidence: None,
        }
    }

    #[test]
    fn unicode_lengths_and_context_have_stable_units() {
        let mut row = candidate();
        let source = "lüse";
        row.consumed_bytes = source.len();
        let features = extract_v1(source, &row).unwrap();
        assert_eq!(
            &features[..8],
            &[-8.0, 2.0, -6.0, 4.0, 2.0, 1.0, -2.0, -4.0]
        );
        assert_eq!(&features[8..], &[1.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn ineligible_paths_and_invalid_scores_never_enter_training() {
        let row = candidate();
        assert!(extract_v1("luse", &row).is_none()); // Not a complete byte span.
        for mutate in [
            |c: &mut Candidate| c.personal = true,
            |c: &mut Candidate| c.verbatim = true,
            |c: &mut Candidate| c.completion = true,
            |c: &mut Candidate| c.preferred = true,
            |c: &mut Candidate| c.language = CandidateLanguage::Literal,
            |c: &mut Candidate| c.score_bits = Some(f64::NAN),
            |c: &mut Candidate| c.context_adjustment = f64::INFINITY,
        ] {
            let mut changed = row.clone();
            mutate(&mut changed);
            assert!(extract_v1("lüse", &changed).is_none());
        }
    }
}
