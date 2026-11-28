//! Local inference for the character scorer and Pinyin encoder-decoder.

mod json;
mod layers;
#[cfg(feature = "pinyin-generation")]
mod pinyin;
mod reranker;
mod tensor;

use std::collections::{BTreeMap, HashMap};
use std::io;
use std::path::Path;

use serde_json::Value;

#[cfg(feature = "pinyin-generation")]
pub use pinyin::{Generation, Pinyin};
pub use reranker::{Ranking, Reranker, SequenceScores};
use tensor::{Matrix, Weights};

pub type Result<T> = io::Result<T>;
#[cfg(feature = "pinyin-generation")]
const PAD: usize = 0;
const BOS: usize = 1;
const EOS: usize = 2;
#[cfg(feature = "pinyin-generation")]
const PINYIN_START: usize = 3;
const BYTE_OFFSET: usize = 4;
const CHAR_OFFSET: usize = 260;

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

#[derive(Clone, Copy)]
enum WeightFormat {
    F32,
    F16,
}

impl WeightFormat {
    fn file_name(self) -> &'static str {
        match self {
            Self::F32 => "weights.f32",
            Self::F16 => "weights.f16",
        }
    }
}

struct Manifest {
    weight_format: WeightFormat,
    model: Value,
    characters: Vec<char>,
    checkpoint_sha256: String,
    length_penalty: f64,
    tensors: BTreeMap<String, Vec<usize>>,
}

impl Manifest {
    fn open(path: &Path, kind: &str) -> Result<Self> {
        let manifest = path.join("model.json");
        if manifest.metadata()?.len() > 4 * 1024 * 1024 {
            return Err(invalid("manifest exceeds limit"));
        }
        let mut raw: Value =
            serde_json::from_reader(io::BufReader::new(std::fs::File::open(manifest)?))?;
        let length_penalty = json::number(&raw["length_penalty"])?;
        if raw["schema"].as_u64() != Some(1)
            || raw["kind"].as_str() != Some(kind)
            || !(0.0..=2.0).contains(&length_penalty)
        {
            return Err(invalid("incompatible neural model manifest"));
        }
        let characters = json::array(&raw["characters"])?
            .iter()
            .map(|value| {
                let mut scalars = json::text(value)?.chars();
                let scalar = scalars.next().filter(|_| scalars.next().is_none());
                scalar.ok_or_else(|| invalid("expected one vocabulary scalar"))
            })
            .collect::<Result<_>>()?;
        let tensors = raw["tensors"]
            .as_object()
            .ok_or_else(|| invalid("missing tensor shapes"))?
            .iter()
            .map(|(name, shape)| {
                Ok((
                    name.clone(),
                    json::array(shape)?
                        .iter()
                        .map(json::integer)
                        .collect::<Result<Vec<_>>>()?,
                ))
            })
            .collect::<Result<_>>()?;
        let weight_format = match raw.get("weight_format").map(Value::as_str) {
            None | Some(Some("f32")) => WeightFormat::F32,
            Some(Some("f16")) if kind == "reranker" => WeightFormat::F16,
            _ => return Err(invalid("unsupported weight format")),
        };
        Ok(Self {
            weight_format,
            checkpoint_sha256: json::text(&raw["checkpoint_sha256"])?.to_owned(),
            model: raw["model"].take(),
            characters,
            length_penalty,
            tensors,
        })
    }
}

struct Tokenizer {
    characters: Vec<char>,
    ids: HashMap<char, usize>,
}

impl Tokenizer {
    fn new(characters: Vec<char>, vocab_size: usize) -> Result<Self> {
        if vocab_size > 65_536 || characters.len() + CHAR_OFFSET > vocab_size {
            return Err(invalid("invalid vocabulary limits"));
        }
        let ids: HashMap<_, _> = characters
            .iter()
            .enumerate()
            .map(|(i, &ch)| (ch, i + CHAR_OFFSET))
            .collect();
        if ids.len() != characters.len() {
            return Err(invalid("duplicate vocabulary scalar"));
        }
        Ok(Self { characters, ids })
    }

    fn scalar(&self, ch: char) -> Vec<usize> {
        if let Some(&id) = self.ids.get(&ch) {
            return vec![id];
        }
        ch.encode_utf8(&mut [0; 4])
            .bytes()
            .map(|b| b as usize + BYTE_OFFSET)
            .collect()
    }

    fn encode(&self, text: &str) -> Vec<usize> {
        text.chars().flat_map(|ch| self.scalar(ch)).collect()
    }

    fn suffix(&self, context: &str, budget: usize) -> Vec<usize> {
        let mut result = Vec::new();
        for ch in context.chars().rev() {
            let tokens = self.scalar(ch);
            if result.len() + tokens.len() > budget {
                break;
            }
            result.extend(tokens.into_iter().rev());
        }
        result.reverse();
        result
    }

    #[cfg(feature = "pinyin-generation")]
    fn decode(&self, tokens: &[usize]) -> Option<String> {
        let mut output = Vec::new();
        for &token in tokens {
            match token {
                EOS => break,
                BOS | PAD => (),
                BYTE_OFFSET..CHAR_OFFSET => output.push((token - BYTE_OFFSET) as u8),
                CHAR_OFFSET.. => output.extend(
                    self.characters
                        .get(token - CHAR_OFFSET)?
                        .encode_utf8(&mut [0; 4])
                        .bytes(),
                ),
                _ => return None,
            }
        }
        String::from_utf8(output)
            .ok()
            .filter(|text| !text.is_empty() && !text.chars().any(char::is_control))
    }

    fn active_end(&self) -> usize {
        CHAR_OFFSET + self.characters.len()
    }
}

fn embed(embedding: &Matrix, positions: &Matrix, tokens: &[usize], scale: f32) -> Matrix {
    embed_at(embedding, positions, tokens, 0..tokens.len(), scale)
}

fn embed_at(
    embedding: &Matrix,
    positions: &Matrix,
    tokens: &[usize],
    position_ids: impl IntoIterator<Item = usize>,
    scale: f32,
) -> Matrix {
    let mut out = embedding.select_rows(tokens.iter().copied());
    for (i, position) in position_ids.into_iter().enumerate() {
        for (x, position) in out.row_mut(i).iter_mut().zip(positions.row(position)) {
            *x = *x * scale + position;
        }
    }
    out
}

fn check_architecture(width: usize, heads: usize, hidden: usize, layers: usize) -> Result<()> {
    if width == 0
        || width > 2048
        || heads == 0
        || !width.is_multiple_of(heads)
        || !(1..=8192).contains(&hidden)
        || !(1..=24).contains(&layers)
    {
        return Err(invalid("unsupported neural architecture limits"));
    }
    Ok(())
}

fn normalization(logits: &[f32], active_end: usize) -> Result<(f32, f32)> {
    let valid = || {
        [logits[EOS]]
            .into_iter()
            .chain(logits[BYTE_OFFSET..active_end].iter().copied())
    };
    let max = valid().fold(f32::NEG_INFINITY, f32::max);
    let sum = valid().map(|x| (x - max).exp()).sum::<f32>().ln();
    if !sum.is_finite() {
        return Err(invalid("nonfinite model scores"));
    }
    Ok((max, sum))
}
