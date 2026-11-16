//! Forward maximum matching of written text against a lexicon.

use std::ops::Range;

use si_lexicon::{Lexicon, Word, WordId};

use crate::han;
use crate::pinyin::{canonical_syllable, word_reading};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SegmentKind {
    Word(WordId),
    UserWord(WordId),
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
    user: Option<&'a Lexicon>,
    entries: Vec<(&'a str, SegmentKind)>,
}

impl<'a> Segmenter<'a> {
    pub fn new(lexicon: &'a Lexicon) -> Self {
        Self::with_overlay(lexicon, None)
    }

    pub(crate) fn with_user(lexicon: &'a Lexicon, user: &'a Lexicon) -> Self {
        Self::with_overlay(lexicon, Some(user))
    }

    fn with_overlay(lexicon: &'a Lexicon, user: Option<&'a Lexicon>) -> Self {
        let mut entries: Vec<_> = lexicon
            .words()
            .map(|word| (word.text, SegmentKind::Word(word.id)))
            .collect();
        if let Some(user) = user {
            entries.extend(
                user.words()
                    .filter(|word| is_user_only(lexicon, *word))
                    .map(|word| (word.text, SegmentKind::UserWord(word.id))),
            );
        }
        entries.sort_unstable_by(|left, right| left.0.cmp(right.0));
        Self {
            lexicon,
            user,
            entries,
        }
    }

    /// Match the longest entry at each position and advance past the entire match.
    pub fn segment<'text>(&'text self, text: &'text str) -> impl Iterator<Item = Segment> + 'text {
        let mut position = 0;
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
            let surface = &text[range.clone()];
            let kind = if kind == SegmentKind::Ambiguous && surface.chars().all(han::is_han) {
                self.resolve_han(surface).unwrap_or(kind)
            } else {
                kind
            };
            Some(Segment { range, kind })
        })
    }

    fn resolve_han(&self, surface: &str) -> Option<SegmentKind> {
        let prediction = word_reading(surface)?;
        let base = self
            .lexicon
            .words_for_text(surface)
            .map(|word| (word, SegmentKind::Word(word.id)));
        let user = self
            .user
            .into_iter()
            .flat_map(|lexicon| lexicon.words_for_text(surface))
            .filter(|word| is_user_only(self.lexicon, *word))
            .map(|word| (word, SegmentKind::UserWord(word.id)));
        let mut matches = base.chain(user).filter(|(word, _)| {
            word.reading
                .and_then(|reading| std::str::from_utf8(reading.key).ok())
                .is_some_and(|key| {
                    key.split('\'')
                        .map(canonical_syllable)
                        .eq(prediction.split('\''))
                })
        });
        let (_, kind) = matches.next()?;
        matches.next().is_none().then_some(kind)
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
            let Some(&(word, kind)) = entries.first() else {
                break;
            };
            let splits_run = text.as_bytes().get(end).is_some_and(|next| {
                (character.is_ascii_alphabetic() && next.is_ascii_alphabetic())
                    || (character.is_ascii_digit() && next.is_ascii_digit())
            });
            if word.len() == end && !splits_run {
                let multiple = entries.get(1).is_some_and(|(word, _)| word.len() == end);
                let unresolved = match kind {
                    SegmentKind::Word(id) => self.lexicon.word(id).unwrap().reading.is_none(),
                    _ => false,
                };
                let kind = if multiple || unresolved {
                    SegmentKind::Ambiguous
                } else {
                    kind
                };
                longest = Some((end, kind));
            }
        }
        longest
    }
}

fn is_user_only(base: &Lexicon, word: Word<'_>) -> bool {
    word.reading.is_some_and(|reading| {
        base.find_reading(reading.index, reading.key, word.text)
            .is_none()
    })
}
