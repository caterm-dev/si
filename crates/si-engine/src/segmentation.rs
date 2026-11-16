//! Frequency-scored segmentation of written text against immutable lexicons.

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
    entries: Vec<Entry<'a>>,
    unknown_score: f64,
}

// User observations add at most this many pseudo-counts per written word.
const USER_COUNT_LIMIT: f64 = 32.0;

#[derive(Clone, Copy)]
struct Entry<'a> {
    text: &'a str,
    kind: SegmentKind,
    score: f64,
}

#[derive(Clone, Copy)]
struct Step {
    score: f64,
    previous: usize,
    kind: SegmentKind,
}

impl<'a> Segmenter<'a> {
    pub fn new(lexicon: &'a Lexicon) -> Self {
        Self::with_overlay(lexicon, None)
    }

    pub(crate) fn with_user(lexicon: &'a Lexicon, user: &'a Lexicon) -> Self {
        Self::with_overlay(lexicon, Some(user))
    }

    fn with_overlay(lexicon: &'a Lexicon, user: Option<&'a Lexicon>) -> Self {
        let mut rows: Vec<_> = lexicon
            .words()
            .map(|word| {
                let observed = user.and_then(|user| {
                    let reading = word.reading?;
                    user.find_reading(reading.index, reading.key, word.text)
                        .and_then(|id| user.word(id))
                });
                (
                    word.text,
                    SegmentKind::Word(word.id),
                    word.count as f64,
                    observed.map_or(0.0, |word| word.count as f64),
                )
            })
            .collect();
        if let Some(user) = user {
            rows.extend(
                user.words()
                    .filter(|word| is_user_only(lexicon, *word))
                    .map(|word| {
                        (
                            word.text,
                            SegmentKind::UserWord(word.id),
                            0.0,
                            word.count as f64,
                        )
                    }),
            );
        }
        // Sort counts too, so summation and ties do not depend on word IDs/import order.
        rows.sort_unstable_by(|left, right| {
            left.0
                .cmp(right.0)
                .then_with(|| left.2.total_cmp(&right.2))
                .then_with(|| left.3.total_cmp(&right.3))
        });
        let mut entries = Vec::new();
        let mut position = 0;
        while position < rows.len() {
            let (text, mut kind, _, _) = rows[position];
            let end = position + rows[position..].partition_point(|row| row.0 == text);
            let base_count: f64 = rows[position..end].iter().map(|row| row.2).sum();
            let user_count: f64 = rows[position..end].iter().map(|row| row.3).sum();
            if end - position > 1
                || matches!(kind, SegmentKind::Word(id)
                if lexicon.word(id).unwrap().reading.is_none())
            {
                kind = SegmentKind::Ambiguous;
            }
            entries.push(Entry {
                text,
                kind,
                score: base_count + user_count.min(USER_COUNT_LIMIT) + 1.0,
            });
            position = end;
        }
        // Add-one word smoothing and a half-count unknown outcome. Precompute logs
        // once per immutable index, outside the per-request segmentation path.
        let total = 0.5 + entries.iter().map(|entry| entry.score).sum::<f64>();
        for entry in &mut entries {
            entry.score = (entry.score / total).ln();
        }
        Self {
            lexicon,
            user,
            entries,
            unknown_score: (0.5 / total).ln(),
        }
    }

    /// Choose the highest-scoring complete path, preserving exact source byte ranges.
    /// ASCII runs keep their existing whole-run/known-spelling rules.
    pub fn segment(&self, text: &str) -> std::vec::IntoIter<Segment> {
        let mut steps = vec![None; text.len() + 1];
        steps[0] = Some(Step {
            score: 0.0,
            previous: 0,
            kind: SegmentKind::Boundary,
        });
        for (start, first) in text.char_indices() {
            let Some(previous) = steps[start] else {
                continue;
            };
            let mut offer = |length: usize, kind: SegmentKind, score: f64| {
                let next = Step {
                    score: previous.score + score,
                    previous: start,
                    kind,
                };
                let slot = &mut steps[start + length];
                // Equal scores prefer the longer final edge. Traversal and ties are
                // independent of lexicon word-ID allocation.
                if slot.is_none_or(|old: Step| {
                    next.score > old.score
                        || (next.score == old.score && next.previous < old.previous)
                }) {
                    *slot = Some(next);
                }
            };
            let remaining = &text[start..];
            if first.is_ascii_alphanumeric() {
                let (length, kind, score) = self.ascii(remaining, first);
                offer(length, kind, score);
            } else if first.is_alphanumeric() {
                self.matches(remaining, |length, entry| {
                    offer(length, entry.kind, entry.score)
                });
                // A single unknown scalar remains available even when a longer word
                // matches, so a poor match cannot hide a better following word.
                offer(first.len_utf8(), SegmentKind::Unknown, self.unknown_score);
            } else {
                let kind = match first {
                    '\r' | '\n' | '\u{2028}' | '\u{2029}' => SegmentKind::Boundary,
                    character if character.is_whitespace() => SegmentKind::Space,
                    _ => SegmentKind::Boundary,
                };
                offer(first.len_utf8(), kind, 0.0);
            }
        }
        let mut segments = Vec::new();
        let mut end = text.len();
        while end != 0 {
            let step = steps[end].expect("every source scalar has a fallback");
            let range = step.previous..end;
            let surface = &text[range.clone()];
            let kind = if step.kind == SegmentKind::Ambiguous && surface.chars().all(han::is_han) {
                self.resolve_han(surface).unwrap_or(step.kind)
            } else {
                step.kind
            };
            segments.push(Segment { range, kind });
            end = step.previous;
        }
        segments.reverse();
        segments.into_iter()
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

    fn ascii(&self, text: &str, first: char) -> (usize, SegmentKind, f64) {
        let mut longest = None;
        self.matches(text, |length, entry| {
            longest = Some((length, entry.kind, entry.score))
        });
        if first.is_ascii_digit() {
            let digits = text.bytes().take_while(u8::is_ascii_digit).count();
            return longest
                .filter(|(length, _, _)| *length > digits)
                .unwrap_or((digits, SegmentKind::Number, self.unknown_score));
        }
        if first.is_ascii_alphabetic() {
            if let Some(matched) = longest.filter(|(length, _, _)| *length > 1) {
                return matched;
            }
            let letters = text.bytes().take_while(u8::is_ascii_alphabetic).count();
            return if letters == 1 {
                (1, SegmentKind::Letter, self.unknown_score)
            } else {
                (letters, SegmentKind::NewEnglishWord, self.unknown_score)
            };
        }
        unreachable!("ASCII alphanumeric input")
    }

    fn matches(&self, text: &str, mut visit: impl FnMut(usize, Entry<'a>)) {
        let mut entries = self.entries.as_slice();
        for (offset, character) in text.char_indices() {
            if matches!(character, '\r' | '\n' | '\u{2028}' | '\u{2029}') {
                break;
            }
            let end = offset + character.len_utf8();
            let unit = &text[offset..end];
            // Every entry in this range already matches the preceding UTF-8 bytes.
            let start = entries.partition_point(|entry| &entry.text[offset..] < unit);
            entries = &entries[start..];
            let end_of_range =
                entries.partition_point(|entry| entry.text[offset..].starts_with(unit));
            entries = &entries[..end_of_range];
            let Some(&entry) = entries.first() else {
                break;
            };
            let splits_run = text.as_bytes().get(end).is_some_and(|next| {
                (character.is_ascii_alphabetic() && next.is_ascii_alphabetic())
                    || (character.is_ascii_digit() && next.is_ascii_digit())
            });
            if entry.text.len() == end && !splits_run {
                visit(end, entry);
            }
        }
    }
}

fn is_user_only(base: &Lexicon, word: Word<'_>) -> bool {
    word.reading.is_some_and(|reading| {
        base.find_reading(reading.index, reading.key, word.text)
            .is_none()
    })
}
