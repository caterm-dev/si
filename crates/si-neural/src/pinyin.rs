use std::collections::HashSet;
use std::path::Path;

use crate::json;

use crate::layers::{Block, BlockKind, KeyValue, Norm};
use crate::{
    BOS, BYTE_OFFSET, EOS, Manifest, Matrix, PINYIN_START, Result, Tokenizer, Weights,
    check_architecture, embed, invalid, normalization,
};

struct Config {
    vocab_size: usize,
    d_model: usize,
    nhead: usize,
    dim_feedforward: usize,
    encoder_layers: usize,
    decoder_layers: usize,
    max_source_tokens: usize,
    max_target_tokens: usize,
    source_format: Option<String>,
}

#[derive(Debug)]
pub struct Generation {
    pub model_candidates: Vec<String>,
    pub candidates: Vec<String>,
}

struct Beam {
    tokens: Vec<usize>,
    logp: f64,
}

pub struct Pinyin {
    checkpoint_sha256: String,
    tokenizer: Tokenizer,
    embedding: Matrix,
    positions: Matrix,
    encoder: Vec<Block>,
    decoder: Vec<Block>,
    encoder_norm: Norm,
    decoder_norm: Norm,
    max_source: usize,
    max_target: usize,
    contextual: bool,
    length_penalty: f64,
}

impl Pinyin {
    pub fn checkpoint_sha256(&self) -> &str {
        &self.checkpoint_sha256
    }

    pub fn open(path: &Path) -> Result<Self> {
        let manifest = Manifest::open(path, "pinyin")?;
        let c = Config {
            vocab_size: json::integer(&manifest.model["vocab_size"])?,
            d_model: json::integer(&manifest.model["d_model"])?,
            nhead: json::integer(&manifest.model["nhead"])?,
            dim_feedforward: json::integer(&manifest.model["dim_feedforward"])?,
            encoder_layers: json::integer(&manifest.model["encoder_layers"])?,
            decoder_layers: json::integer(&manifest.model["decoder_layers"])?,
            max_source_tokens: json::integer(&manifest.model["max_source_tokens"])?,
            max_target_tokens: json::integer(&manifest.model["max_target_tokens"])?,
            source_format: manifest.model["source_format"].as_str().map(str::to_owned),
        };
        for count in [c.encoder_layers, c.decoder_layers] {
            check_architecture(c.d_model, c.nhead, c.dim_feedforward, count)?;
        }
        if !(2..=512).contains(&c.max_source_tokens) || !(2..=128).contains(&c.max_target_tokens) {
            return Err(invalid("unsupported Pinyin sequence limits"));
        }
        let contextual = match c.source_format.as_deref() {
            None => false,
            Some("contextual-pinyin") => true,
            _ => return Err(invalid("unknown Pinyin source format")),
        };
        let tokenizer = Tokenizer::new(manifest.characters, c.vocab_size)?;
        let mut w = Weights::open(&path.join("weights.f32"), manifest.tensors)?;
        let embedding = w.matrix("embedding.weight", c.vocab_size, c.d_model)?;
        let positions = w.matrix(
            "positions",
            c.max_source_tokens.max(c.max_target_tokens),
            c.d_model,
        )?;
        let mut load_blocks = |name, count, kind| {
            (0..count)
                .map(|i| {
                    Block::load(
                        &mut w,
                        &format!("{name}.{i}"),
                        c.d_model,
                        c.nhead,
                        c.dim_feedforward,
                        kind,
                    )
                })
                .collect::<Result<Vec<_>>>()
        };
        let encoder = load_blocks("encoder", c.encoder_layers, BlockKind::Encoder)?;
        let decoder = load_blocks("decoder", c.decoder_layers, BlockKind::Decoder)?;
        let encoder_norm = Norm::load(&mut w, "encoder_norm", c.d_model)?;
        let decoder_norm = Norm::load(&mut w, "decoder_norm", c.d_model)?;
        w.finish()?;
        Ok(Self {
            checkpoint_sha256: manifest.checkpoint_sha256,
            tokenizer,
            embedding,
            positions,
            encoder,
            decoder,
            encoder_norm,
            decoder_norm,
            max_source: c.max_source_tokens,
            max_target: c.max_target_tokens,
            contextual,
            length_penalty: manifest.length_penalty,
        })
    }

    fn sources(
        &self,
        spelling: &str,
        context: Option<&str>,
        paths: &[String],
    ) -> Result<Vec<Vec<usize>>> {
        if self.contextual {
            if paths.len() > 3
                || paths.iter().any(|path| {
                    path.split(' ').any(|s| {
                        s.is_empty() || !s.chars().all(|c| c.is_ascii_lowercase() || c == 'ü')
                    }) || path.replace(' ', "") != spelling
                })
            {
                return Err(invalid("invalid Pinyin syllable paths"));
            }
            let mut seen = HashSet::new();
            Ok(paths
                .iter()
                .filter(|p| seen.insert(*p))
                .filter_map(|p| {
                    let pinyin = self.tokenizer.encode(p);
                    let room = self.max_source.checked_sub(pinyin.len() + 3)?;
                    Some(
                        [BOS]
                            .into_iter()
                            .chain(self.tokenizer.suffix(context.unwrap_or(""), room))
                            .chain([PINYIN_START])
                            .chain(pinyin)
                            .chain([EOS])
                            .collect(),
                    )
                })
                .collect())
        } else {
            if context.is_some() || !paths.is_empty() {
                return Err(invalid("checkpoint accepts spelling only"));
            }
            let tokens = self.tokenizer.encode(spelling);
            if tokens.len() + 2 > self.max_source {
                return Ok(vec![]);
            }
            Ok(vec![[BOS].into_iter().chain(tokens).chain([EOS]).collect()])
        }
    }

    pub fn uses_context(&self) -> bool {
        self.contextual
    }

    pub fn generate(
        &self,
        spelling: &str,
        context: Option<&str>,
        paths: &[String],
        beam_size: usize,
    ) -> Result<Generation> {
        if !(1..=32).contains(&beam_size)
            || spelling.len() > 4096
            || paths.iter().any(|p| p.len() > 4096)
        {
            return Err(invalid("invalid Pinyin generation limits"));
        }
        if spelling.is_empty() {
            return Ok(Generation {
                model_candidates: vec![],
                candidates: vec![],
            });
        }
        let mut completed = Vec::new();
        for tokens in self.sources(spelling, context, paths)? {
            completed.extend(self.beam_search(&tokens, beam_size)?);
        }
        self.sort_beams(&mut completed);
        let mut seen = HashSet::new();
        let model_candidates: Vec<_> = completed
            .into_iter()
            .filter_map(|b| self.tokenizer.decode(&b.tokens[1..]))
            .filter(|text| seen.insert(text.clone()))
            .take(beam_size)
            .collect();
        let mut candidates = model_candidates.clone();
        if !seen.contains(spelling) {
            candidates.push(spelling.to_owned());
        }
        Ok(Generation {
            model_candidates,
            candidates,
        })
    }

    fn sort_beams(&self, beams: &mut [Beam]) {
        let score =
            |b: &Beam| b.logp / ((b.tokens.len() - 1).max(1) as f64).powf(self.length_penalty);
        beams.sort_by(|a, b| {
            score(b)
                .total_cmp(&score(a))
                .then_with(|| a.tokens.cmp(&b.tokens))
        });
    }

    fn beam_search(&self, source: &[usize], beam_size: usize) -> Result<Vec<Beam>> {
        let scale = (self.embedding.cols as f32).sqrt();
        let mut memory = embed(&self.embedding, &self.positions, source, scale);
        for block in &self.encoder {
            block.run(&mut memory, None);
        }
        memory = self.encoder_norm.run(&memory);
        let cached: Vec<KeyValue> = self
            .decoder
            .iter()
            .map(|b| b.cross_key_values(&memory))
            .collect();
        let mut beams = vec![Beam {
            tokens: vec![BOS],
            logp: 0.0,
        }];
        for _ in 1..self.max_target {
            if beams.iter().all(|b| b.tokens.last() == Some(&EOS)) {
                break;
            }
            let mut next = Vec::new();
            for beam in beams {
                if beam.tokens.last() == Some(&EOS) {
                    next.push(beam);
                    continue;
                }
                let mut hidden = embed(&self.embedding, &self.positions, &beam.tokens, scale);
                for (block, cross) in self.decoder.iter().zip(&cached) {
                    block.run(&mut hidden, Some(cross));
                }
                let logits = self
                    .decoder_norm
                    .run(&hidden.select_rows([hidden.rows - 1]))
                    .project(&self.embedding);
                let logits = logits.row(0);
                let end = self.tokenizer.active_end();
                let (max, sum) = normalization(logits, end)?;
                let mut tokens: Vec<_> = [EOS].into_iter().chain(BYTE_OFFSET..end).collect();
                let cmp = |&a: &usize, &b: &usize| logits[b].total_cmp(&logits[a]).then(a.cmp(&b));
                if tokens.len() > beam_size {
                    tokens.select_nth_unstable_by(beam_size, cmp);
                }
                for &token in tokens.iter().take(beam_size) {
                    let mut tokens = beam.tokens.clone();
                    tokens.push(token);
                    next.push(Beam {
                        tokens,
                        logp: beam.logp + (logits[token] - max - sum) as f64,
                    });
                }
            }
            self.sort_beams(&mut next);
            next.truncate(beam_size);
            beams = next;
        }
        Ok(beams
            .into_iter()
            .filter(|b| b.tokens.last() == Some(&EOS))
            .collect())
    }
}
