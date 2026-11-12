use std::cmp::Ordering;
use std::collections::HashMap;

use super::{Candidate, CandidateLanguage};

const DIRECT_COMPLETIONS_PER_LANGUAGE: usize = 32;

#[derive(Default)]
pub(super) struct Results {
    rows: HashMap<(usize, CandidateLanguage, String), (f64, bool)>,
}

impl Results {
    pub(super) fn insert(&mut self, candidate: Candidate) {
        let score = candidate
            .score_bits
            .expect("converted candidates have scores");
        let completion = candidate.completion;
        let current = self
            .rows
            .entry((candidate.consumed_bytes, candidate.language, candidate.text))
            .or_insert((score, completion));
        if score > current.0 || (score == current.0 && !completion) {
            *current = (score, completion);
        }
    }

    pub(super) fn ranked(self) -> Vec<Candidate> {
        let mut candidates: Vec<_> = self
            .rows
            .into_iter()
            .map(
                |((consumed_bytes, language, text), (score, completion))| Candidate {
                    text,
                    language,
                    consumed_bytes,
                    score_bits: Some(score),
                    completion,
                },
            )
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
        .consumed_bytes
        .cmp(&left.consumed_bytes)
        .then_with(|| {
            right
                .score_bits
                .unwrap()
                .total_cmp(&left.score_bits.unwrap())
        })
        .then_with(|| left.language.cmp(&right.language))
        .then_with(|| left.text.cmp(&right.text))
}
