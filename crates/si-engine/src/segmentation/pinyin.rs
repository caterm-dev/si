use std::ops::Range;

use si_lexicon::Reading;

use crate::han;
use crate::pinyin::{canonical_syllable, read_syllables};

/// Readings computed once for the surrounding Han run, indexed by UTF-8 offsets.
pub(super) struct ContextualPinyin {
    offsets: Vec<usize>,
    syllables: Vec<Option<String>>,
}

impl ContextualPinyin {
    pub(super) fn new(text: &str, range: &Range<usize>) -> Option<Self> {
        let start = text[..range.start]
            .char_indices()
            .rev()
            .take_while(|&(_, character)| han::is_han(character))
            .last()
            .map_or(range.start, |(offset, _)| offset);
        let end = range.end
            + text[range.end..]
                .chars()
                .take_while(|&character| han::is_han(character))
                .map(char::len_utf8)
                .sum::<usize>();
        let han_run = &text[start..end];
        let syllables = read_syllables(han_run)?;
        let offsets = han_run
            .char_indices()
            .map(|(offset, _)| start + offset)
            .chain(std::iter::once(end))
            .collect();
        Some(Self { offsets, syllables })
    }

    pub(super) fn covers(&self, range: &Range<usize>) -> bool {
        self.offsets[0] <= range.start && self.offsets[self.syllables.len()] >= range.end
    }

    pub(super) fn matches(&self, range: &Range<usize>, reading: Option<Reading<'_>>) -> bool {
        let (Ok(start), Ok(end)) = (
            self.offsets.binary_search(&range.start),
            self.offsets.binary_search(&range.end),
        ) else {
            return false;
        };
        let prediction = &self.syllables[start..end];
        if prediction.iter().any(Option::is_none) {
            return false;
        }
        reading
            .and_then(|reading| std::str::from_utf8(reading.key).ok())
            .is_some_and(|reading| {
                reading
                    .split('\'')
                    .map(canonical_syllable)
                    .eq(prediction.iter().flatten().map(String::as_str))
            })
    }
}
