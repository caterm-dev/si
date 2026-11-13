use std::cmp::Ordering;
use std::collections::HashMap;

use super::{Candidate, CandidateLanguage, ConversionBoundary};

const DIRECT_COMPLETIONS_PER_LANGUAGE: usize = 32;

#[derive(Default)]
pub(super) struct Results {
    rows: HashMap<(usize, CandidateLanguage, String), Evidence>,
}

struct Evidence {
    score: f64,
    effective_score: f64,
    completion: bool,
    lexical_tokens: usize,
    source_boundaries: Vec<usize>,
    confirmation_boundaries: Vec<ConversionBoundary>,
    personal: bool,
    preferred: bool,
    verbatim: bool,
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
            score,
            effective_score,
            completion,
            lexical_tokens: candidate.lexical_tokens,
            source_boundaries: candidate.source_boundaries,
            confirmation_boundaries: candidate.confirmation_boundaries,
            personal: candidate.personal,
            preferred: candidate.preferred,
            verbatim: candidate.verbatim,
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
                let direct = current.lexical_tokens == 1 || evidence.lexical_tokens == 1;
                if (evidence.preferred && !current.preferred)
                    || (evidence.preferred == current.preferred
                        && (evidence.effective_score > current.effective_score
                            || (evidence.effective_score == current.effective_score
                                && !completion
                                && current.completion)))
                {
                    *current = evidence;
                } else if score == current.score {
                    current
                        .confirmation_boundaries
                        .retain(|boundary| evidence.confirmation_boundaries.contains(boundary));
                }
                if direct {
                    current.lexical_tokens = 1;
                }
            }
        }
    }

    pub(super) fn ranked(self) -> Vec<Candidate> {
        let mut rows: Vec<_> = self.rows.into_iter().collect();
        rows.sort_unstable_by(
            |((left_end, left_language, left_text), left),
             ((right_end, right_language, right_text), right)| {
                right
                    .preferred
                    .cmp(&left.preferred)
                    .then_with(|| right_end.cmp(left_end))
                    .then_with(|| right.effective_score.total_cmp(&left.effective_score))
                    .then_with(|| left_language.cmp(right_language))
                    .then_with(|| left_text.cmp(right_text))
            },
        );
        rows.into_iter()
            .map(|((consumed_bytes, language, text), evidence)| Candidate {
                text,
                language,
                consumed_bytes,
                score_bits: Some(evidence.score),
                completion: evidence.completion,
                lexical_tokens: evidence.lexical_tokens,
                source_boundaries: evidence.source_boundaries,
                confirmation_boundaries: evidence.confirmation_boundaries,
                personal: evidence.personal,
                preferred: evidence.preferred,
                verbatim: evidence.verbatim,
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
