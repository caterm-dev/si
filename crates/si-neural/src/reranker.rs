use std::path::Path;

use crate::json;

use crate::layers::{Block, BlockKind, Norm};
use crate::{
    BOS, Manifest, Matrix, Result, Tokenizer, Weights, check_architecture, embed, invalid,
    normalization,
};

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
        let mut w = Weights::open(&path.join("weights.f32"), manifest.tensors)?;
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

    /// Number of model tokens, if this surface can be scored in a pool.
    pub fn scoreable_token_count(&self, text: &str) -> Option<usize> {
        if text.is_empty() || text.len() > 4096 || text.chars().any(char::is_control) {
            return None;
        }
        let count = self.tokenizer.encode(text).len();
        (count <= self.context).then_some(count)
    }

    pub fn rank(
        &self,
        context: &str,
        candidates: &[String],
        length_penalty: Option<f64>,
    ) -> Result<Ranking> {
        let penalty = length_penalty.unwrap_or(self.length_penalty);
        if candidates.len() > 96
            || !(0.0..=2.0).contains(&penalty)
            || candidates.iter().any(|text| {
                text.is_empty() || text.len() > 4096 || text.chars().any(char::is_control)
            })
        {
            return Err(invalid("invalid candidate scoring request"));
        }
        let encoded: Vec<_> = candidates
            .iter()
            .map(|text| self.tokenizer.encode(text))
            .collect();
        let Some(longest) = encoded.iter().map(Vec::len).max() else {
            return Ok(Ranking {
                scores: vec![],
                order: vec![],
                abstained: false,
                context_tokens_used: 0,
            });
        };
        let Some(available) = self.context.checked_sub(longest) else {
            return Ok(Ranking {
                scores: vec![None; candidates.len()],
                order: (0..candidates.len()).collect(),
                abstained: true,
                context_tokens_used: 0,
            });
        };
        let history = self.tokenizer.suffix(context, available);
        let mut scores = Vec::with_capacity(candidates.len());
        for (text, target) in candidates.iter().zip(encoded) {
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
            for (i, token) in target.into_iter().enumerate() {
                let row = logits.row(i);
                let (max, sum) = normalization(row, self.tokenizer.active_end())?;
                score += (row[token] - max - sum) as f64;
            }
            scores.push(Some(score / (text.chars().count() as f64).powf(penalty)));
        }
        let mut order: Vec<_> = (0..scores.len()).collect();
        order.sort_by(|&a, &b| {
            scores[b]
                .unwrap()
                .total_cmp(&scores[a].unwrap())
                .then(a.cmp(&b))
        });
        Ok(Ranking {
            scores,
            order,
            abstained: false,
            context_tokens_used: history.len(),
        })
    }
}
