//! Platform-independent final ordering and candidate-window selection.
//!
//! Clients supply transient scores and stable language/span-aware identities.
//! Results refer to the original rows, so normalization of comparison keys never
//! changes output bytes, spelling alignment, or confirmation evidence. There is
//! no font, window, selection state, persistence, or resource loading here.

use std::borrow::Cow;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use unicode_normalization::{IsNormalized, UnicodeNormalization, is_nfc_quick};
use unicode_segmentation::UnicodeSegmentation;

use crate::{Candidate, CandidateLanguage, EnabledLanguages};

pub const ORDINARY_LIMIT: usize = 27;
pub const WORD_LIMIT: usize = 9;
const LEADING_CHOICES: usize = 4;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Order {
    #[default]
    Statistical,
    CoverageAdjusted,
}

/// Metadata for conversion results, personal vocabulary, or punctuation choices.
/// `None` consumption means the whole input; other offsets count UTF-8 bytes.
#[derive(Clone, Debug)]
pub struct PresentationCandidate<'a> {
    pub identity: Cow<'a, str>,
    pub text: &'a str,
    pub language: CandidateLanguage,
    pub consumed_bytes: Option<usize>,
    pub lexical_tokens: usize,
    pub lexical_score: f64,
    pub statistical_score: Option<f64>,
    pub reranking_bonus: f64,
    pub preferred: bool,
    pub remembered: bool,
    pub personal: bool,
    pub punctuation: bool,
    pub completion: bool,
    pub verbatim: bool,
    pub corrected: bool,
    pub chinese_sentence: bool,
}

impl<'a> PresentationCandidate<'a> {
    /// Adapt an engine result without discarding its full conversion evidence.
    pub fn from_conversion(candidate: &'a Candidate, input: &str) -> Self {
        let language = match candidate.language {
            CandidateLanguage::Chinese => "zh-Hans",
            CandidateLanguage::English => "en",
            CandidateLanguage::Mixed => "zh-Hans+en",
            CandidateLanguage::Literal => "literal",
        };
        let consumed_bytes =
            (candidate.consumed_bytes < input.len()).then_some(candidate.consumed_bytes);
        let base = format!("{language}:{}", candidate.text);
        let identity = if let Some(end) = consumed_bytes {
            let count = input.get(..end).unwrap_or_default().graphemes(true).count();
            format!("prefix{count}:{base}")
        } else {
            base
        };
        Self {
            identity: Cow::Owned(identity),
            text: &candidate.text,
            language: candidate.language,
            consumed_bytes,
            lexical_tokens: candidate.lexical_tokens,
            lexical_score: candidate.score_bits.unwrap_or_default(),
            statistical_score: candidate
                .score_bits
                .map(|score| score + candidate.context_adjustment + candidate.token_bonus),
            reranking_bonus: candidate.reranking_bonus,
            preferred: candidate.preferred,
            remembered: false,
            personal: candidate.personal,
            punctuation: false,
            completion: candidate.completion,
            verbatim: candidate.verbatim,
            corrected: candidate.is_corrected(),
            chinese_sentence: candidate.language == CandidateLanguage::Chinese
                && candidate.lexical_tokens > 1
                && consumed_bytes.is_none()
                && !candidate.personal
                && !candidate.verbatim
                && !candidate.is_corrected(),
        }
    }

    fn literal(&self) -> bool {
        self.language == CandidateLanguage::Literal
    }

    fn remembered(&self) -> bool {
        self.remembered
            && self.consumed_bytes.is_none()
            && !self.literal()
            && !self.personal
            && !self.verbatim
            && !self.corrected
            && !self.punctuation
    }

    fn statistical(&self) -> f64 {
        self.statistical_score.unwrap_or(self.lexical_score)
    }

    fn word(&self) -> bool {
        !self.literal()
            && !self.corrected
            && self.language != CandidateLanguage::Mixed
            && !self.verbatim
            && !self.completion
            && (self.lexical_tokens == 1 || self.personal || self.punctuation)
    }

    fn character(&self) -> bool {
        self.word()
            && self.language == CandidateLanguage::Chinese
            && !self.personal
            && !self.punctuation
            && self.text.graphemes(true).count() == 1
    }

    fn score(&self, input: &str, order: Order, rerank: bool) -> f64 {
        let coverage = if order == Order::CoverageAdjusted {
            let spelling = input
                .get(..self.consumed_bytes.unwrap_or(input.len()))
                .unwrap_or_default();
            coverage_bonus(spelling, self.literal(), self.verbatim)
        } else {
            0.0
        };
        self.statistical() + coverage + if rerank { self.reranking_bonus } else { 0.0 }
    }
}

/// One chosen derivation, with lexical evidence retained across equivalent rows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PresentedCandidate {
    pub index: usize,
    pub lexical_tokens: usize,
    pub chinese_sentence: bool,
    pub remembered: bool,
    /// Includes coverage even when `Order::Statistical` determines the order.
    pub presentation_score: f64,
}

/// Five presentation points per matched source unit; separators earn nothing.
pub fn coverage_bonus(spelling: &str, literal: bool, verbatim: bool) -> f64 {
    if literal || verbatim {
        return 0.0;
    }
    spelling
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, 'ü' | 'Ü'))
        .count() as f64
        * 5.0
}

fn canonical_identity(identity: &str) -> Cow<'_, str> {
    // Keep the common ASCII/CJK path borrowed. Normalize the complete key on
    // fallback: combining marks can compose across lexical-token boundaries.
    if identity
        .chars()
        .all(|c| c.is_ascii() || ('\u{4e00}'..='\u{9fff}').contains(&c))
        || is_nfc_quick(identity.chars()) == IsNormalized::Yes
    {
        Cow::Borrowed(identity)
    } else {
        Cow::Owned(identity.nfc().collect())
    }
}

fn compare(
    left: &PresentationCandidate<'_>,
    left_key: &str,
    right: &PresentationCandidate<'_>,
    right_key: &str,
    input: &str,
    order: Order,
    rerank: bool,
) -> Ordering {
    right
        .preferred
        .cmp(&left.preferred)
        .then_with(|| right.remembered().cmp(&left.remembered()))
        .then_with(|| {
            right
                .consumed_bytes
                .unwrap_or(usize::MAX)
                .cmp(&left.consumed_bytes.unwrap_or(usize::MAX))
        })
        .then_with(|| {
            right
                .score(input, order, rerank)
                .partial_cmp(&left.score(input, order, rerank))
                .unwrap_or(Ordering::Equal)
        })
        .then_with(|| left_key.cmp(right_key))
}

/// Merge all providers, preserving the supplied exact literal as the last row.
/// Deduplication retains the historical coverage comparison in both order modes.
pub fn merge(
    input: &str,
    languages: EnabledLanguages,
    candidates: &[PresentationCandidate<'_>],
    order: Order,
) -> Vec<PresentedCandidate> {
    if input.is_empty() {
        return Vec::new();
    }
    let keys: Vec<_> = candidates
        .iter()
        .map(|c| canonical_identity(&c.identity))
        .collect();
    let mut best: HashMap<&str, PresentedCandidate> = HashMap::new();
    let boundaries: HashSet<_> = input
        .grapheme_indices(true)
        .map(|(offset, _)| offset)
        .collect();
    let mut literal = None;
    for (index, candidate) in candidates.iter().enumerate() {
        let row = PresentedCandidate {
            index,
            lexical_tokens: candidate.lexical_tokens,
            chinese_sentence: candidate.chinese_sentence,
            remembered: candidate.remembered(),
            presentation_score: candidate.score(input, Order::CoverageAdjusted, true),
        };
        if candidate.literal() {
            if candidate.text.as_bytes() == input.as_bytes() {
                literal = Some(row);
            }
            continue;
        }
        let enabled = match candidate.language {
            CandidateLanguage::Chinese => languages.chinese,
            CandidateLanguage::English => languages.english,
            CandidateLanguage::Mixed => languages.chinese && languages.english,
            CandidateLanguage::Literal => false,
        };
        if !enabled
            || candidate.text.is_empty()
            || candidate
                .consumed_bytes
                .is_some_and(|end| end == 0 || end >= input.len() || !boundaries.contains(&end))
        {
            continue;
        }
        let key = keys[index].as_ref();
        let Some(current) = best.get_mut(key) else {
            best.insert(key, row);
            continue;
        };
        let previous = &candidates[current.index];
        if previous.corrected != candidate.corrected {
            if previous.corrected {
                *current = row;
            }
            continue;
        }
        let lexical_tokens = if current.lexical_tokens == 1 || row.lexical_tokens == 1 {
            1
        } else {
            row.lexical_tokens
        };
        let chinese_sentence = current.chinese_sentence && row.chinese_sentence;
        if compare(
            previous,
            key,
            candidate,
            key,
            input,
            Order::CoverageAdjusted,
            true,
        )
        .is_lt()
        {
            if lexical_tokens == 1 {
                current.lexical_tokens = 1;
            }
            current.chinese_sentence = chinese_sentence;
        } else {
            *current = PresentedCandidate {
                lexical_tokens,
                chinese_sentence,
                ..row
            };
        }
    }
    let mut rows: Vec<_> = best.into_values().collect();
    rows.sort_by(|left, right| {
        compare(
            &candidates[left.index],
            &keys[left.index],
            &candidates[right.index],
            &keys[right.index],
            input,
            order,
            true,
        )
    });
    rows.extend(literal);
    rows
}

/// Index of the first statistical choice, excluding character-model rewards.
/// The caller chooses the eligible pool (for example only whole candidates).
pub fn statistical_leader(candidates: &[PresentationCandidate<'_>]) -> Option<usize> {
    let keys: Vec<_> = candidates
        .iter()
        .map(|c| canonical_identity(&c.identity))
        .collect();
    (0..candidates.len()).min_by(|&left, &right| {
        compare(
            &candidates[left],
            &keys[left],
            &candidates[right],
            &keys[right],
            "",
            Order::Statistical,
            false,
        )
    })
}

/// Window indices in incoming rank order, with literals last. Full conversion
/// remains independently available to previews and confirmation evidence.
pub fn shortlist(candidates: &[PresentationCandidate<'_>]) -> Vec<usize> {
    let keys: Vec<_> = candidates
        .iter()
        .map(|c| canonical_identity(&c.identity))
        .collect();
    let ordinary: Vec<_> = (0..candidates.len())
        .filter(|&i| !candidates[i].literal())
        .collect();
    // The leading constructed result estimates output length for this composition.
    // A shared budget covers exact sentences, prefixes, corrections and completions.
    let sentence_limit = ordinary
        .iter()
        .take(LEADING_CHOICES)
        .map(|&i| &candidates[i])
        .find(|candidate| !candidate.word())
        .map_or(LEADING_CHOICES, |candidate| {
            match candidate
                .text
                .graphemes(true)
                .filter(|g| !g.chars().all(char::is_whitespace))
                .take(9)
                .count()
            {
                0..=5 => 4,
                6 => 3,
                7..=8 => 2,
                _ => 1,
            }
        });
    let mut retained: HashSet<&str> = HashSet::new();
    let mut sentence_count = 0;
    for &i in ordinary.iter().take(LEADING_CHOICES) {
        if candidates[i].word() || retained.contains(keys[i].as_ref()) {
            continue;
        }
        if sentence_count >= sentence_limit {
            continue;
        }
        retained.insert(&keys[i]);
        sentence_count += 1;
    }
    for (i, candidate) in candidates.iter().enumerate() {
        if candidate.literal() {
            retained.insert(&keys[i]);
        }
    }
    let mut word_count = 0;
    for &i in &ordinary {
        let candidate = &candidates[i];
        if !candidate.word() || candidate.character() || retained.contains(keys[i].as_ref()) {
            continue;
        }
        if retained.len() >= ORDINARY_LIMIT {
            break;
        }
        if !candidate.punctuation && word_count >= WORD_LIMIT {
            continue;
        }
        retained.insert(&keys[i]);
        if !candidate.punctuation {
            word_count += 1;
        }
    }
    for &i in &ordinary {
        if candidates[i].character() {
            retained.insert(&keys[i]);
        }
    }
    ordinary
        .into_iter()
        .filter(|&i| retained.contains(keys[i].as_ref()))
        .chain((0..candidates.len()).filter(|&i| candidates[i].literal()))
        .collect()
}

/// Apply the same final statistical order and window policy to Rust conversion
/// results. Callers with additional vocabulary/punctuation use `merge` directly.
pub fn conversion_window(
    input: &str,
    languages: EnabledLanguages,
    candidates: &[Candidate],
) -> Vec<usize> {
    let metadata: Vec<_> = candidates
        .iter()
        .map(|row| PresentationCandidate::from_conversion(row, input))
        .collect();
    let ranked = merge(input, languages, &metadata, Order::Statistical);
    let presented: Vec<_> = ranked
        .iter()
        .map(|row| {
            let mut candidate = metadata[row.index].clone();
            candidate.lexical_tokens = row.lexical_tokens;
            candidate.chinese_sentence = row.chinese_sentence;
            candidate
        })
        .collect();
    shortlist(&presented)
        .into_iter()
        .map(|index| ranked[index].index)
        .collect()
}
