use std::cmp::Ordering;
use std::collections::HashMap;

use super::{Candidate, CandidateLanguage, ConversionBoundary, Correction};

const MAX_CORRECTIONS: usize = 4;
const DIRECT_COMPLETIONS_PER_LANGUAGE: usize = 32;

#[derive(Default)]
pub(super) struct Results {
    rows: HashMap<(usize, CandidateLanguage, String), Evidence>,
}

struct Evidence {
    ranking_evidence: Option<Box<crate::ranking_features::PathEvidence>>,
    score: f64,
    context_adjustment: f64,
    effective_score: f64,
    completion: bool,
    lexical_tokens: usize,
    source_boundaries: Vec<usize>,
    confirmation_boundaries: Vec<ConversionBoundary>,
    personal: bool,
    preferred: bool,
    verbatim: bool,
    correction: Option<Correction>,
    token_bonus: f64,
}

impl Results {
    pub(super) fn insert(&mut self, candidate: Candidate, effective_score: f64) {
        let score = candidate
            .score_bits
            .expect("converted candidates have scores");
        let completion = candidate.completion;
        use std::collections::hash_map::Entry;
        let evidence = Evidence {
            ranking_evidence: candidate.ranking_evidence,
            score,
            context_adjustment: candidate.context_adjustment,
            effective_score,
            completion,
            lexical_tokens: candidate.lexical_tokens,
            source_boundaries: candidate.source_boundaries,
            confirmation_boundaries: candidate.confirmation_boundaries,
            personal: candidate.personal,
            preferred: candidate.preferred,
            verbatim: candidate.verbatim,
            correction: candidate.correction,
            token_bonus: candidate.token_bonus,
        };
        match self
            .rows
            .entry((candidate.consumed_bytes, candidate.language, candidate.text))
        {
            Entry::Vacant(row) => {
                row.insert(evidence);
            }
            Entry::Occupied(mut row) => {
                let current = row.get_mut();
                if current.correction.is_some() != evidence.correction.is_some() {
                    if current.correction.is_some() {
                        *current = evidence;
                    }
                    return;
                }
                let has_direct_match = [&current.ranking_evidence, &evidence.ranking_evidence]
                    .into_iter()
                    .flatten()
                    .any(|row| row.has_direct_match);
                let direct = current.lexical_tokens == 1 || evidence.lexical_tokens == 1;
                if (evidence.preferred && !current.preferred)
                    || (evidence.preferred == current.preferred
                        && (evidence.effective_score > current.effective_score
                            || (evidence.effective_score == current.effective_score
                                && !completion
                                && current.completion)))
                {
                    *current = evidence;
                } else if score + evidence.context_adjustment
                    == current.score + current.context_adjustment
                {
                    current
                        .confirmation_boundaries
                        .retain(|boundary| evidence.confirmation_boundaries.contains(boundary));
                }
                if let Some(row) = &mut current.ranking_evidence {
                    row.has_direct_match = has_direct_match;
                }
                if direct {
                    current.lexical_tokens = 1;
                }
            }
        }
    }

    pub(super) fn ranked(self, correction_floor: f64) -> Vec<Candidate> {
        let mut rows: Vec<_> = self
            .rows
            .into_iter()
            .filter(|(_, evidence)| {
                evidence.correction.is_none() || evidence.effective_score > correction_floor
            })
            .collect();
        rows.sort_unstable_by(
            |((left_end, left_language, left_text), left),
             ((right_end, right_language, right_text), right)| {
                right
                    .preferred
                    .cmp(&left.preferred)
                    .then_with(|| right_end.cmp(left_end))
                    .then_with(|| left.correction.is_some().cmp(&right.correction.is_some()))
                    .then_with(|| right.effective_score.total_cmp(&left.effective_score))
                    .then_with(|| left_language.cmp(right_language))
                    .then_with(|| left_text.cmp(right_text))
            },
        );
        let mut corrections = 0;
        rows.into_iter()
            .filter(|(_, evidence)| {
                corrections += usize::from(evidence.correction.is_some());
                evidence.correction.is_none() || corrections <= MAX_CORRECTIONS
            })
            .map(|((consumed_bytes, language, text), evidence)| Candidate {
                ranking_evidence: evidence.ranking_evidence,
                text,
                language,
                consumed_bytes,
                score_bits: Some(evidence.score),
                context_adjustment: evidence.context_adjustment,
                completion: evidence.completion,
                lexical_tokens: evidence.lexical_tokens,
                source_boundaries: evidence.source_boundaries,
                confirmation_boundaries: evidence.confirmation_boundaries,
                personal: evidence.personal,
                preferred: evidence.preferred,
                verbatim: evidence.verbatim,
                correction: evidence.correction,
                token_bonus: evidence.token_bonus,
            })
            .collect()
    }
}

/// Direct completions from one language at the whole input span.
#[derive(Default)]
pub(super) struct Completions(Vec<(Candidate, f64)>);

impl Completions {
    pub(super) fn could_enter(&self, score: f64) -> bool {
        self.0.len() < DIRECT_COMPLETIONS_PER_LANGUAGE || score >= self.0.last().unwrap().1
    }

    pub(super) fn insert(&mut self, candidate: Candidate, adjustment: f64) {
        let score = candidate.score_bits.unwrap() + adjustment;
        let compare = |(row, effective): &(Candidate, f64)| {
            score
                .total_cmp(effective)
                .then_with(|| row.text.cmp(&candidate.text))
        };
        if let Some(index) = self
            .0
            .iter()
            .position(|(row, _)| row.text == candidate.text)
        {
            if compare(&self.0[index]) != Ordering::Greater {
                return;
            }
            self.0.remove(index);
        }
        let position = self
            .0
            .partition_point(|row| compare(row) != Ordering::Greater);
        if position < DIRECT_COMPLETIONS_PER_LANGUAGE {
            self.0.insert(position, (candidate, score));
            self.0.truncate(DIRECT_COMPLETIONS_PER_LANGUAGE);
        }
    }

    pub(super) fn into_rows(self) -> Vec<(Candidate, f64)> {
        self.0
    }
}
