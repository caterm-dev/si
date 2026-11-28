mod prefixes;

use std::path::Path;

use crate::json;

use crate::layers::{Block, BlockKind, Norm};
use crate::{
    BOS, Manifest, Matrix, Result, Tokenizer, Weights, check_architecture, embed, embed_at,
    invalid, normalization,
};
use prefixes::PrefixBatch;

const MAX_CANDIDATES: usize = 96;
// Keep the temporary full-vocabulary logits bounded independently of trie size.
const PROJECTION_ROWS: usize = 32;

struct Config {
    vocab_size: usize,
    width: usize,
    heads: usize,
    layers: usize,
    feedforward: usize,
    context: usize,
}

#[derive(Debug)]
pub struct Ranking {
    /// Scores in the original request order, missing if the pool does not fit.
    pub scores: Vec<Option<f64>>,
    pub order: Vec<usize>,
    pub abstained: bool,
    pub context_tokens_used: usize,
}

/// Whole-candidate natural-log probabilities, without length normalization.
pub struct SequenceScores {
    pub scores: Vec<f64>,
    pub context_tokens_used: usize,
}

pub struct Reranker {
    checkpoint_sha256: String,
    tokenizer: Tokenizer,
    embedding: Matrix,
    positions: Matrix,
    blocks: Vec<Block>,
    norm: Norm,
    context: usize,
    length_penalty: f64,
}

struct ScoredPool {
    scores: Vec<Option<f64>>,
    context_tokens_used: Option<usize>,
}

impl Reranker {
    pub fn checkpoint_sha256(&self) -> &str {
        &self.checkpoint_sha256
    }

    pub fn open(path: &Path) -> Result<Self> {
        let manifest = Manifest::open(path, "reranker")?;
        let c = Config {
            vocab_size: json::integer(&manifest.model["vocab_size"])?,
            width: json::integer(&manifest.model["width"])?,
            heads: json::integer(&manifest.model["heads"])?,
            layers: json::integer(&manifest.model["layers"])?,
            feedforward: json::integer(&manifest.model["feedforward"])?,
            context: json::integer(&manifest.model["context"])?,
        };
        check_architecture(c.width, c.heads, c.feedforward, c.layers)?;
        if !(1..=512).contains(&c.context) {
            return Err(invalid("unsupported context length"));
        }
        let tokenizer = Tokenizer::new(manifest.characters, c.vocab_size)?;
        let mut w = Weights::open(
            &path.join(manifest.weight_format.file_name()),
            manifest.tensors,
            manifest.weight_format,
        )?;
        let embedding = w.matrix("embedding.weight", c.vocab_size, c.width)?;
        let positions = w.matrix("positions.weight", c.context, c.width)?;
        let blocks = (0..c.layers)
            .map(|i| {
                Block::load(
                    &mut w,
                    &format!("blocks.{i}"),
                    c.width,
                    c.heads,
                    c.feedforward,
                    BlockKind::CharacterLm,
                )
            })
            .collect::<Result<_>>()?;
        let norm = Norm::load(&mut w, "norm", c.width)?;
        w.finish()?;
        Ok(Self {
            checkpoint_sha256: manifest.checkpoint_sha256,
            tokenizer,
            embedding,
            positions,
            blocks,
            norm,
            context: c.context,
            length_penalty: manifest.length_penalty,
        })
    }

    pub fn rank(
        &self,
        context: &str,
        candidates: &[String],
        length_penalty: Option<f64>,
    ) -> Result<Ranking> {
        let penalty = length_penalty.unwrap_or(self.length_penalty);
        if !(0.0..=2.0).contains(&penalty) {
            return Err(invalid("invalid candidate scoring request"));
        }
        let ScoredPool {
            mut scores,
            context_tokens_used,
        } = self.score_pool(context, candidates, self.context, self.context)?;
        let mut order: Vec<_> = (0..scores.len()).collect();
        if context_tokens_used.is_some() {
            for (score, text) in scores.iter_mut().zip(candidates) {
                *score = score.map(|value| value / (text.chars().count() as f64).powf(penalty));
            }
            order.sort_by(|&a, &b| {
                scores[b]
                    .unwrap()
                    .total_cmp(&scores[a].unwrap())
                    .then(a.cmp(&b))
            });
        }
        Ok(Ranking {
            scores,
            order,
            abstained: context_tokens_used.is_none(),
            context_tokens_used: context_tokens_used.unwrap_or_default(),
        })
    }

    /// Mean log probability per output scalar with a shared, bounded context.
    /// Abstains when a complete candidate would exceed the token budget.
    pub fn bounded_mean_scores(
        &self,
        context: &str,
        candidates: &[&str],
        context_tokens: usize,
        candidate_tokens: usize,
    ) -> Result<Option<Vec<f64>>> {
        Ok(self
            .bounded_sequence_scores(context, candidates, context_tokens, candidate_tokens)?
            .map(|pool| {
                pool.scores
                    .into_iter()
                    .zip(candidates)
                    .map(|(score, text)| score / text.chars().count() as f64)
                    .collect()
            }))
    }

    /// Score complete candidate sequences under the same token bounds as mean
    /// scoring. The reported context length distinguishes a truncated-away
    /// context from an informative prefix, without exposing tokenizer internals.
    pub fn bounded_sequence_scores(
        &self,
        context: &str,
        candidates: &[&str],
        context_tokens: usize,
        candidate_tokens: usize,
    ) -> Result<Option<SequenceScores>> {
        let pool = self.score_pool(context, candidates, context_tokens, candidate_tokens)?;
        Ok(pool
            .context_tokens_used
            .map(|context_tokens_used| SequenceScores {
                scores: pool
                    .scores
                    .into_iter()
                    .map(|score| score.expect("scored pool"))
                    .collect(),
                context_tokens_used,
            }))
    }

    fn score_pool(
        &self,
        context: &str,
        candidates: &[impl AsRef<str>],
        context_tokens: usize,
        candidate_tokens: usize,
    ) -> Result<ScoredPool> {
        if candidates.len() > MAX_CANDIDATES
            || candidates.iter().any(|text| {
                let text = text.as_ref();
                text.is_empty() || text.len() > 4096 || text.chars().any(char::is_control)
            })
        {
            return Err(invalid("invalid candidate scoring request"));
        }
        let encoded: Vec<_> = candidates
            .iter()
            .map(|text| self.tokenizer.encode(text.as_ref()))
            .collect();
        let Some(longest) = encoded.iter().map(Vec::len).max() else {
            return Ok(ScoredPool {
                scores: vec![],
                context_tokens_used: Some(0),
            });
        };
        let Some(available) = self
            .context
            .checked_sub(longest)
            .filter(|_| longest <= candidate_tokens)
        else {
            return Ok(ScoredPool {
                scores: vec![None; candidates.len()],
                context_tokens_used: None,
            });
        };
        let history = self
            .tokenizer
            .suffix(context, available.min(context_tokens));
        let scores = match PrefixBatch::new(&history, &encoded) {
            Some(batch) => self.score_prefixes(batch)?,
            None => self.score_individual(&history, &encoded)?,
        };
        Ok(ScoredPool {
            scores,
            context_tokens_used: Some(history.len()),
        })
    }

    fn score_prefixes(&self, batch: PrefixBatch) -> Result<Vec<Option<f64>>> {
        let positions = batch.ancestors.iter().map(|path| path.len() - 1);
        let mut state = embed_at(
            &self.embedding,
            &self.positions,
            &batch.tokens,
            positions,
            1.0,
        );
        for block in &self.blocks {
            block.run_prefixes(&mut state, &batch.ancestors);
        }
        let output_rows: Vec<_> = batch
            .predictions
            .iter()
            .enumerate()
            .filter_map(|(row, edges)| (!edges.is_empty()).then_some(row))
            .collect();
        let mut probabilities = vec![0.0; batch.score_count];
        for chunk in output_rows.chunks(PROJECTION_ROWS) {
            let logits = self
                .norm
                .run(&state.select_rows(chunk.iter().copied()))
                .project(&self.embedding);
            for (index, &row) in chunk.iter().enumerate() {
                let values = logits.row(index);
                let (max, sum) = normalization(values, self.tokenizer.active_end())?;
                for &(token, score_index) in &batch.predictions[row] {
                    probabilities[score_index] = (values[token] - max - sum) as f64;
                }
            }
        }
        Ok(batch
            .score_paths
            .into_iter()
            .map(|path| Some(path.into_iter().map(|i| probabilities[i]).sum()))
            .collect())
    }

    fn score_individual(
        &self,
        history: &[usize],
        encoded: &[Vec<usize>],
    ) -> Result<Vec<Option<f64>>> {
        let mut scores = Vec::with_capacity(encoded.len());
        for target in encoded {
            let input: Vec<_> = [BOS]
                .into_iter()
                .chain(history.iter().copied())
                .chain(target[..target.len() - 1].iter().copied())
                .collect();
            let mut state = embed(&self.embedding, &self.positions, &input, 1.0);
            for block in &self.blocks {
                block.run(&mut state, None);
            }
            let logits = self
                .norm
                .run(&state.select_rows(history.len()..state.rows))
                .project(&self.embedding);
            let mut score = 0.0;
            for (i, &token) in target.iter().enumerate() {
                let row = logits.row(i);
                let (max, sum) = normalization(row, self.tokenizer.active_end())?;
                score += (row[token] - max - sum) as f64;
            }
            scores.push(Some(score));
        }
        Ok(scores)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CHAR_OFFSET;

    #[test]
    fn longest_candidate_sets_a_shared_context_budget() {
        let model = Reranker {
            checkpoint_sha256: String::new(),
            tokenizer: Tokenizer::new(vec!['甲', '乙'], CHAR_OFFSET + 2).unwrap(),
            embedding: Matrix {
                rows: CHAR_OFFSET + 2,
                cols: 2,
                values: (0..CHAR_OFFSET + 2)
                    .flat_map(|i| [(i % 5) as f32 / 4.0, (i % 7) as f32 / 6.0])
                    .collect(),
            },
            positions: Matrix {
                rows: 4,
                cols: 2,
                values: vec![0.6, 0.0, 0.0, 0.6, 0.25, 0.5, 0.9, 0.0],
            },
            blocks: Vec::new(),
            norm: Norm::unit(2),
            context: 4,
            length_penalty: 0.0,
        };
        let candidates = ["甲".to_owned(), "乙乙乙".to_owned()];
        let full = model.rank("甲乙甲", &candidates, None).unwrap();
        assert_eq!(full.context_tokens_used, 1);
        let shorter_pool = model.rank("甲乙甲", &candidates[..1], None).unwrap();
        assert_eq!(shorter_pool.context_tokens_used, 3);
        assert!((full.scores[0].unwrap() - shorter_pool.scores[0].unwrap()).abs() > 0.01);

        let texts = ["甲", "乙乙乙"];
        assert_eq!(
            model.bounded_mean_scores("甲乙甲", &texts, 1, 2).unwrap(),
            None
        );
        let bounded = model
            .bounded_mean_scores("前缀甲", &texts, 1, 3)
            .unwrap()
            .unwrap();
        let sequence = model
            .bounded_sequence_scores("前缀甲", &texts, 1, 3)
            .unwrap()
            .unwrap();
        assert_eq!(sequence.context_tokens_used, 1);
        for ((text, mean), total) in texts.iter().zip(&bounded).zip(&sequence.scores) {
            assert_eq!(*mean, total / text.chars().count() as f64);
        }
        assert!(
            model
                .bounded_sequence_scores("", &texts, 0, 2)
                .unwrap()
                .is_none()
        );
        let unavailable = model
            .bounded_sequence_scores("🙂", &texts, 1, 3)
            .unwrap()
            .unwrap();
        assert_eq!(unavailable.context_tokens_used, 0);
        assert_eq!(
            unavailable.scores,
            model
                .bounded_sequence_scores("", &texts, 0, 3)
                .unwrap()
                .unwrap()
                .scores
        );
        assert_eq!(
            bounded,
            model
                .bounded_mean_scores("甲", &texts, 1, 3)
                .unwrap()
                .unwrap()
        );
        assert!((bounded[1] - full.scores[1].unwrap() / 3.0).abs() < 1e-8);
    }
}
