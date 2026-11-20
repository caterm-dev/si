//! Shared experiment features for offline pools and the isolated App ranking path.
use si_lexicon::{IndexId, Lexicon};

use super::input::{Input, english_key_byte};
use super::{Candidate, Language};

pub const GROUP_SIZE: usize = 4;
pub const BUFFER_SIZE: usize = 8;
pub const TOTAL_SIZE: usize = GROUP_SIZE + BUFFER_SIZE + 1;
pub const NAMES: [&str; TOTAL_SIZE] = [
    "lexical_delta_from_pool_max_bits",
    "lexical_pool_rank",
    "lexical_pool_percentile",
    "pool_candidate_count",
    "buffer_exact_english_word",
    "buffer_complete_pinyin",
    "buffer_pinyin_segmentation_count",
    "buffer_case_pattern",
    "buffer_has_digit",
    "buffer_has_period",
    "buffer_has_underscore",
    "buffer_has_slash",
    "english_completion_ratio",
];

#[derive(Clone, Copy)]
pub enum Extension {
    Group,
    Buffer,
    Completion,
    All,
}

impl Extension {
    pub const ALL: [Self; 4] = [Self::Group, Self::Buffer, Self::Completion, Self::All];

    pub fn names(self) -> &'static [&'static str] {
        &NAMES[self.range()]
    }

    pub fn values(self, row: &[Option<f64>; TOTAL_SIZE]) -> &[Option<f64>] {
        &row[self.range()]
    }

    fn range(self) -> std::ops::Range<usize> {
        match self {
            Self::Group => 0..GROUP_SIZE,
            Self::Buffer => GROUP_SIZE..GROUP_SIZE + BUFFER_SIZE,
            Self::Completion => TOTAL_SIZE - 1..TOTAL_SIZE,
            Self::All => 0..TOTAL_SIZE,
        }
    }
}

pub fn buffer(source: &str, lexicon: &Lexicon) -> [Option<f64>; BUFFER_SIZE] {
    let input = Input::new(source);
    let english = input.spelling(Language::English);
    let english_word = !source.is_empty()
        && source.bytes().all(|byte| english_key_byte(byte.to_ascii_lowercase()))
        && lexicon.exact(IndexId(1), english).next().is_some();
    let pinyin = pinyin_count(&input, lexicon);
    [
        Some(f64::from(english_word)),
        pinyin.map(|n| f64::from(n > 0)),
        pinyin.map(f64::from),
        Some(case_pattern(source)),
        Some(f64::from(source.bytes().any(|byte| byte.is_ascii_digit()))),
        Some(f64::from(source.contains('.'))),
        Some(f64::from(source.contains('_'))),
        Some(f64::from(source.contains('/'))),
    ]
}

fn pinyin_count(input: &Input<'_>, lexicon: &Lexicon) -> Option<u16> {
    let spelling = input.spelling(Language::Chinese);
    let end = spelling.len();
    if end == 0 || !spelling.iter().all(u8::is_ascii_lowercase) {
        return Some(0);
    }
    if end > 128 {
        return None;
    }
    let mut suffixes = vec![0_u16; end + 1];
    suffixes[end] = 1;
    for start in (0..end).rev() {
        let boundary = start + input.separators(start, end).next().unwrap_or(end - start);
        for next in start + 1..=boundary.min(start + 6) {
            if suffixes[next] > 0
                && lexicon.exact(IndexId(0), &spelling[start..next]).next().is_some()
            {
                suffixes[start] = suffixes[start].saturating_add(suffixes[next]);
            }
        }
    }
    Some(suffixes[0])
}

fn case_pattern(source: &str) -> f64 {
    let cased: Vec<_> = source.chars().filter_map(|ch| {
        if ch.is_lowercase() {
            Some(false)
        } else if ch.is_uppercase() {
            Some(true)
        } else {
            None
        }
    }).collect();
    match cased.split_first() {
        None => 0.0,
        Some(_) if cased.iter().all(|&upper| !upper) => 1.0,
        Some(_) if cased.iter().all(|&upper| upper) => 2.0,
        Some((true, rest)) if rest.iter().all(|&upper| !upper) => 3.0,
        Some(_) => 4.0,
    }
}

pub fn completion(candidate: &Candidate) -> f64 {
    candidate.ranking_evidence.as_ref().map_or(1.0, |path| path.english_completion_ratio)
}

/// Supply the final model-pool order, after union and before model scores or policies.
pub fn enrich(
    lexical: &[Option<f64>],
    buffer: [Option<f64>; BUFFER_SIZE],
    ratios: &[f64],
) -> Vec<[Option<f64>; TOTAL_SIZE]> {
    assert_eq!(lexical.len(), ratios.len());
    let mut sorted: Vec<_> = lexical.iter().flatten().copied().collect();
    sorted.sort_by(|left, right| right.total_cmp(left));
    lexical.iter().zip(ratios).map(|(&score, &ratio)| {
        let mut row = [None; TOTAL_SIZE];
        row[3] = Some(lexical.len() as f64);
        row[GROUP_SIZE..GROUP_SIZE + BUFFER_SIZE].copy_from_slice(&buffer);
        row[TOTAL_SIZE - 1] = Some(ratio);
        if let Some(score) = score {
            let higher = sorted.partition_point(|&other| other > score);
            row[0] = Some(score - sorted[0]);
            row[1] = Some((higher + 1) as f64);
            row[2] = Some(if sorted.len() == 1 {
                1.0
            } else {
                1.0 - higher as f64 / (sorted.len() - 1) as f64
            });
        }
        row
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ties_share_rank_and_model_only_rows_still_count() {
        let rows = enrich(&[Some(-5.0), None, Some(-1.5), Some(-1.5)], [None; BUFFER_SIZE],
                          &[1.0, 1.0, 0.5, 1.0]);
        assert_eq!(rows[0][..4], [Some(-3.5), Some(3.0), Some(0.0), Some(4.0)]);
        assert_eq!(rows[1][..4], [None, None, None, Some(4.0)]);
        assert_eq!(rows[2][..4], [Some(0.0), Some(1.0), Some(1.0), Some(4.0)]);
        assert_eq!(rows[2][12], Some(0.5));
        assert_eq!(rows[3][..4], rows[2][..4]);
    }

    #[test]
    fn case_codes_ignore_uncased_characters() {
        for (source, expected) in [("9/", 0.0), ("go_on", 1.0), ("GO", 2.0),
                                   ("Go", 3.0), ("goOn", 4.0)] {
            assert_eq!(case_pattern(source), expected);
        }
    }
}
