use std::collections::HashMap;

use crate::BOS;

// Fall back to individual forwards if sharing would require an oversized batch.
const MAX_ROWS: usize = 1024;

struct Edge {
    score_index: usize,
    next_row: Option<usize>,
}

pub(super) struct PrefixBatch {
    pub(super) tokens: Vec<usize>,
    pub(super) ancestors: Vec<Vec<usize>>,
    pub(super) predictions: Vec<Vec<(usize, usize)>>,
    pub(super) score_paths: Vec<Vec<usize>>,
    pub(super) score_count: usize,
}

impl PrefixBatch {
    pub(super) fn new(history: &[usize], candidates: &[Vec<usize>]) -> Option<Self> {
        if candidates.len() < 2 {
            return None;
        }
        let mut batch = Self {
            tokens: std::iter::once(BOS)
                .chain(history.iter().copied())
                .collect(),
            ancestors: (0..=history.len()).map(|i| (0..=i).collect()).collect(),
            predictions: vec![Vec::new(); history.len() + 1],
            score_paths: Vec::with_capacity(candidates.len()),
            score_count: 0,
        };
        let mut edges = HashMap::new();
        for candidate in candidates {
            let mut row = history.len();
            let mut path = Vec::with_capacity(candidate.len());
            for (position, &token) in candidate.iter().enumerate() {
                let edge: &mut Edge = edges.entry((row, token)).or_insert_with(|| {
                    let score_index = batch.score_count;
                    batch.score_count += 1;
                    batch.predictions[row].push((token, score_index));
                    Edge {
                        score_index,
                        next_row: None,
                    }
                });
                path.push(edge.score_index);
                if position + 1 == candidate.len() {
                    break;
                }
                if edge.next_row.is_none() {
                    let next = batch.tokens.len();
                    if next == MAX_ROWS {
                        return None;
                    }
                    batch.tokens.push(token);
                    let mut ancestors = batch.ancestors[row].clone();
                    ancestors.push(next);
                    batch.ancestors.push(ancestors);
                    batch.predictions.push(Vec::new());
                    edge.next_row = Some(next);
                }
                row = edge.next_row.expect("next prefix row");
            }
            batch.score_paths.push(path);
        }
        Some(batch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shares_scored_edges_at_candidate_ends_and_across_branches() {
        let candidates = [vec![10], vec![10, 11], vec![10, 12]];
        let batch = PrefixBatch::new(&[30], &candidates).unwrap();
        assert_eq!(batch.tokens, [BOS, 30, 10]);
        assert_eq!(batch.ancestors, [vec![0], vec![0, 1], vec![0, 1, 2]]);
        assert_eq!(
            batch.predictions,
            [vec![], vec![(10, 0)], vec![(11, 1), (12, 2)]]
        );
        assert_eq!(batch.score_paths, [vec![0], vec![0, 1], vec![0, 2]]);
        assert_eq!(batch.score_count, 3);
    }

    #[test]
    fn falls_back_when_distinct_paths_exceed_the_batch_limit() {
        let candidates: Vec<_> = (1..=3).map(|token| vec![token; 512]).collect();
        assert!(PrefixBatch::new(&[], &candidates).is_none());
    }
}
