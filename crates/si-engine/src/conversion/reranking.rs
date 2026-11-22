use std::io;
use std::path::Path;

use si_neural::Reranker;

pub(super) const MAX_CANDIDATES: usize = 12;
pub(super) const MAX_CANDIDATE_BYTES: usize = MAX_CANDIDATE_TOKENS * 4;
const MAX_BONUS_BITS: f64 = 2.0;
const MAX_CANDIDATE_TOKENS: usize = 12;
const MAX_CONTEXT_TOKENS: usize = 16;
const MODEL_WEIGHT: f64 = 0.8;

/// Immutable local character scorer shared across base and user engines.
pub struct SmallReranker(Reranker);

impl SmallReranker {
    pub fn open(path: &Path) -> io::Result<Self> {
        Reranker::open(path).map(Self)
    }

    pub(super) fn bonuses(&self, context: &str, texts: &[&str]) -> Option<Vec<f64>> {
        let scores = self
            .0
            .bounded_mean_scores(context, texts, MAX_CONTEXT_TOKENS, MAX_CANDIDATE_TOKENS)
            .ok()??;
        if !scores.iter().all(|score| score.is_finite()) {
            return None;
        }
        let lowest = scores.iter().copied().reduce(f64::min)?;
        Some(
            scores
                .into_iter()
                .map(|score| {
                    ((score - lowest) * std::f64::consts::LOG2_E * MODEL_WEIGHT).min(MAX_BONUS_BITS)
                })
                .collect(),
        )
    }
}
