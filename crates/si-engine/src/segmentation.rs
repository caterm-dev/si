//! Forward maximum matching of written text against a lexicon.

mod pinyin;

use std::ops::Range;

use si_lexicon::{Lexicon, WordId};

use self::pinyin::ContextualPinyin;
use crate::han;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SegmentKind {
    Word(WordId),
    NewEnglishWord,
    Letter,
    Number,
    Ambiguous,
    Unknown,
    Space,
    Boundary,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Segment {
    /// UTF-8 byte range into the original text.
    pub range: Range<usize>,
    pub kind: SegmentKind,
}

/// An index over exact output spellings, shared by all paragraphs in one import.
pub struct Segmenter<'a> {
    lexicon: &'a Lexicon,
    entries: Vec<(&'a str, WordId)>,
}

impl<'a> Segmenter<'a> {
    pub fn new(lexicon: &'a Lexicon) -> Self {
        let mut entries: Vec<_> = lexicon.words().map(|word| (word.text, word.id)).collect();
        entries.sort_unstable_by(|left, right| left.0.cmp(right.0));
        Self { lexicon, entries }
    }

    /// Match the longest entry at each position and advance past the entire match.
    pub fn segment<'text>(&'text self, text: &'text str) -> impl Iterator<Item = Segment> + 'text {
        let mut position = 0;
        let mut contextual_pinyin: Option<ContextualPinyin> = None;
        std::iter::from_fn(move || {
            let remaining = &text[position..];
            let first = remaining.chars().next()?;
            let fallback = match first {
                '\r' | '\n' | '\u{2028}' | '\u{2029}' => SegmentKind::Boundary,
                character if character.is_whitespace() => SegmentKind::Space,
                character if character.is_alphanumeric() => SegmentKind::Unknown,
                _ => SegmentKind::Boundary,
            };
            let (length, kind) = if fallback == SegmentKind::Unknown {
                self.alphanumeric(remaining, first)
            } else {
                (first.len_utf8(), fallback)
            };
            let start = position;
            position += length;
            let range = start..position;
            let kind =
                if kind == SegmentKind::Ambiguous && text[range.clone()].chars().all(han::is_han) {
                    if contextual_pinyin
                        .as_ref()
                        .is_none_or(|context| !context.covers(&range))
                    {
                        contextual_pinyin = ContextualPinyin::new(text, &range);
                    }
                    contextual_pinyin
                        .as_ref()
                        .and_then(|pinyin| pinyin.resolve(self.lexicon, text, range.clone()))
                        .map_or(kind, SegmentKind::Word)
                } else {
                    kind
                };
            Some(Segment { range, kind })
        })
    }

    fn alphanumeric(&self, text: &str, first: char) -> (usize, SegmentKind) {
        let longest = self.longest(text);
        if first.is_ascii_digit() {
            let digits = text.bytes().take_while(u8::is_ascii_digit).count();
            return longest
                .filter(|(length, _)| *length > digits)
                .unwrap_or((digits, SegmentKind::Number));
        }
        if first.is_ascii_alphabetic() {
            if let Some(matched) = longest.filter(|(length, _)| *length > 1) {
                return matched;
            }
            let letters = text.bytes().take_while(u8::is_ascii_alphabetic).count();
            return if letters == 1 {
                (1, SegmentKind::Letter)
            } else {
                (letters, SegmentKind::NewEnglishWord)
            };
        }
        longest.unwrap_or((first.len_utf8(), SegmentKind::Unknown))
    }

    fn longest(&self, text: &str) -> Option<(usize, SegmentKind)> {
        let mut entries = self.entries.as_slice();
        let mut longest = None;
        for (offset, character) in text.char_indices() {
            if matches!(character, '\r' | '\n' | '\u{2028}' | '\u{2029}') {
                break;
            }
            let end = offset + character.len_utf8();
            let unit = &text[offset..end];
            // Every entry in this range already matches the preceding UTF-8 bytes.
            let start = entries.partition_point(|(word, _)| &word[offset..] < unit);
            entries = &entries[start..];
            let end_of_range =
                entries.partition_point(|(word, _)| word[offset..].starts_with(unit));
            entries = &entries[..end_of_range];
            let Some(&(word, id)) = entries.first() else {
                break;
            };
            let splits_run = text.as_bytes().get(end).is_some_and(|next| {
                (character.is_ascii_alphabetic() && next.is_ascii_alphabetic())
                    || (character.is_ascii_digit() && next.is_ascii_digit())
            });
            if word.len() == end && !splits_run {
                let multiple = entries.get(1).is_some_and(|(word, _)| word.len() == end);
                let kind = if multiple || self.lexicon.word(id).unwrap().reading.is_none() {
                    SegmentKind::Ambiguous
                } else {
                    SegmentKind::Word(id)
                };
                longest = Some((end, kind));
            }
        }
        longest
    }
}
