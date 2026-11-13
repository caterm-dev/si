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
    pub(super) fn insert(&mut self, candidate: Candidate) {
        let score = candidate
            .score_bits
            .expect("converted candidates have scores");
        let completion = candidate.completion;
        use std::collections::hash_map::Entry;
        let evidence = Evidence {
            score,
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
                        && (score + evidence.token_bonus > current.score + current.token_bonus
                            || (score + evidence.token_bonus
                                == current.score + current.token_bonus
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
        let mut candidates: Vec<_> = self
            .rows
            .into_iter()
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
            .collect();
        candidates.sort_unstable_by(compare);
        candidates
    }
}

/// Direct completions from one language at the whole input span.
#[derive(Default)]
pub(super) struct Completions(Vec<Candidate>);

impl Completions {
    pub(super) fn could_enter(&self, score: f64) -> bool {
        self.0.len() < DIRECT_COMPLETIONS_PER_LANGUAGE
            || score >= self.0.last().unwrap().score_bits.unwrap()
    }

    pub(super) fn insert(&mut self, candidate: Candidate) {
        if let Some(index) = self.0.iter().position(|row| row.text == candidate.text) {
            if compare(&candidate, &self.0[index]) != Ordering::Less {
                return;
            }
            self.0.remove(index);
        }
        let position = self
            .0
            .partition_point(|row| compare(row, &candidate) != Ordering::Greater);
        if position < DIRECT_COMPLETIONS_PER_LANGUAGE {
            self.0.insert(position, candidate);
            self.0.truncate(DIRECT_COMPLETIONS_PER_LANGUAGE);
        }
    }

    pub(super) fn into_rows(self) -> Vec<Candidate> {
        self.0
    }
}

fn compare(left: &Candidate, right: &Candidate) -> Ordering {
    right
        .preferred
        .cmp(&left.preferred)
        .then_with(|| right.consumed_bytes.cmp(&left.consumed_bytes))
        .then_with(|| {
            right
                .score_bits
                .unwrap()
                .total_cmp(&left.score_bits.unwrap())
        })
        .then_with(|| left.language.cmp(&right.language))
        .then_with(|| left.text.cmp(&right.text))
}
