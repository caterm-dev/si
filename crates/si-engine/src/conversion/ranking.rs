use std::cmp::Ordering;
use std::collections::HashMap;

use super::{Candidate, CandidateLanguage, ConversionBoundary, Correction, SmallReranker};

const MAX_CORRECTIONS: usize = 4;

#[derive(Default)]
pub(super) struct Results {
    rows: HashMap<(usize, CandidateLanguage, String), Evidence>,
}

type Row = ((usize, CandidateLanguage, String), Evidence);

struct Evidence {
    score: f64,
    context_adjustment: f64,
    effective_score: f64,
    reranking_bonus: f64,
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
            score,
            context_adjustment: candidate.context_adjustment,
            effective_score,
            reranking_bonus: 0.0,
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
                if direct {
                    current.lexical_tokens = 1;
                }
            }
        }
    }

    pub(super) fn ranked(
        self,
        correction_floor: f64,
        completion_correction_floor: f64,
        reranking: Option<(&SmallReranker, &str, usize)>,
    ) -> Vec<Candidate> {
        let mut rows: Vec<_> = self
            .rows
            .into_iter()
            .filter(|(_, evidence)| {
                let floor = if evidence.completion {
                    correction_floor.max(completion_correction_floor)
                } else {
                    correction_floor
                };
                evidence.correction.is_none() || evidence.effective_score > floor
            })
            .collect();
        rows.sort_unstable_by(compare);
        if let Some((model, context, full_span)) = reranking {
            rerank(&mut rows, model, context, full_span);
        }
        let mut corrections = 0;
        rows.into_iter()
            .filter(|(_, evidence)| {
                corrections += usize::from(evidence.correction.is_some());
                evidence.correction.is_none() || corrections <= MAX_CORRECTIONS
            })
            .map(|((consumed_bytes, language, text), evidence)| Candidate {
                text,
                language,
                consumed_bytes,
                score_bits: Some(evidence.score),
                context_adjustment: evidence.context_adjustment,
                reranking_bonus: evidence.reranking_bonus,
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

fn compare(left: &Row, right: &Row) -> Ordering {
    let ((left_end, left_language, left_text), left) = left;
    let ((right_end, right_language, right_text), right) = right;
    right
        .preferred
        .cmp(&left.preferred)
        .then_with(|| right_end.cmp(left_end))
        .then_with(|| {
            (right.effective_score + right.reranking_bonus)
                .total_cmp(&(left.effective_score + left.reranking_bonus))
        })
        .then_with(|| left_language.cmp(right_language))
        .then_with(|| left_text.cmp(right_text))
}

fn rerank(rows: &mut [Row], model: &SmallReranker, context: &str, full_span: usize) {
    let whole = rows
        .iter()
        .enumerate()
        .take_while(|(_, ((end, ..), _))| *end == full_span)
        .filter(|(_, (_, row))| !row.personal && !row.verbatim && row.correction.is_none());
    let mut pool = Vec::with_capacity(model.candidate_limit());
    let mut texts = Vec::with_capacity(model.candidate_limit());
    for (index, ((_, _, text), _)) in whole.filter(|(_, ((_, _, text), row))| {
        !row.completion && text.len() <= model.candidate_byte_limit()
    }) {
        let text = text.as_str();
        let slot = texts
            .iter()
            .position(|&value| value == text)
            .unwrap_or_else(|| {
                texts.push(text);
                texts.len() - 1
            });
        pool.push((index, slot));
        if pool.len() == model.candidate_limit() {
            break;
        }
    }
    if texts.len() < 2 {
        return;
    }
    let Some(bonuses) = model.bonuses(context, &texts) else {
        return;
    };
    for (index, slot) in pool {
        rows[index].1.reranking_bonus = bonuses[slot];
    }
    // Signed adjustments can put previously lower unscored whole results ahead
    // of scored candidates. Re-sort with the same span and preference policy.
    rows.sort_unstable_by(compare);
}

/// Direct completions from one language at the whole input span.
pub(super) struct Completions(Vec<(Candidate, f64)>, usize);

impl Completions {
    pub(super) fn new(limit: usize) -> Self {
        Self(Vec::new(), limit)
    }
    pub(super) fn could_enter(&self, score: f64) -> bool {
        self.0.len() < self.1 || score >= self.0.last().unwrap().1
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
        if position < self.1 {
            self.0.insert(position, (candidate, score));
            self.0.truncate(self.1);
        }
    }

    pub(super) fn into_rows(self) -> Vec<(Candidate, f64)> {
        self.0
    }
}
