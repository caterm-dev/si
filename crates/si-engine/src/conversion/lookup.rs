use std::borrow::Cow;
use std::collections::HashMap;

use si_lexicon::{Lexicon, WordId};

use super::input::{Input, english_key_byte};
use super::{Language, WordIds};
use crate::pinyin::canonical_syllable;

const MAX_UNTYPED_LETTERS: usize = 8;

#[derive(Clone, Copy)]
pub(super) struct Lexeme<'a> {
    pub(super) text: &'a str,
    pub(super) ids: WordIds,
    pub(super) language: Language,
}

struct Entry<'a> {
    spelling: Cow<'a, [u8]>,
    reading: &'a str,
    word: Lexeme<'a>,
}

#[derive(Clone, Copy)]
pub(super) struct Match<'a> {
    pub(super) end: usize,
    pub(super) word: Lexeme<'a>,
    pub(super) missing: usize,
}

pub(super) struct Lookup<'a> {
    entries: [Vec<Entry<'a>>; 2],
    paired: HashMap<WordId, WordId>,
}

impl<'a> Lookup<'a> {
    pub(super) fn new(base: &'a Lexicon, user: Option<&'a Lexicon>) -> Self {
        let paired: HashMap<_, _> = user
            .into_iter()
            .flat_map(Lexicon::words)
            .filter_map(|word| {
                let reading = word.reading?;
                Language::from_index(reading.index)?;
                let base_id = base.find_reading(reading.index, reading.key, word.text)?;
                Some((word.id, base_id))
            })
            .collect();
        let user_by_base: HashMap<_, _> = paired
            .iter()
            .map(|(&user_id, &base_id)| (base_id, user_id))
            .collect();
        let mut entries: [Vec<_>; 2] = Default::default();
        for (lexicon, is_user) in
            std::iter::once((base, false)).chain(user.map(|lexicon| (lexicon, true)))
        {
            for (key, id) in lexicon.lookup_keys() {
                let Some(language) = Language::from_index(key.index) else {
                    continue;
                };
                let word = lexicon.word(id).expect("valid lookup word ID");
                if word
                    .reading
                    .is_none_or(|reading| reading.index != key.index)
                {
                    continue;
                }
                let Ok(reading) = std::str::from_utf8(key.key) else {
                    continue;
                };
                let Some(spelling) = lookup_spelling(language, reading) else {
                    continue;
                };
                let ids = if is_user {
                    let base_id = paired.get(&id).copied();
                    // Most shared user lexemes use their base lookup keys.
                    if base_id.is_some_and(|base_id| {
                        base.exact(key.index, key.key)
                            .any(|word| word.id == base_id)
                    }) {
                        continue;
                    }
                    WordIds {
                        base: base_id,
                        user: Some(id),
                    }
                } else {
                    WordIds {
                        base: Some(id),
                        user: user_by_base.get(&id).copied(),
                    }
                };
                entries[language as usize].push(Entry {
                    spelling,
                    reading,
                    word: Lexeme {
                        text: word.text,
                        ids,
                        language,
                    },
                });
            }
        }
        for lane in &mut entries {
            lane.sort_unstable_by(|left, right| {
                left.spelling
                    .cmp(&right.spelling)
                    .then_with(|| left.word.text.cmp(right.word.text))
                    .then_with(|| left.reading.cmp(right.reading))
                    .then_with(|| {
                        left.word
                            .ids
                            .base
                            .map(|id| id.0)
                            .cmp(&right.word.ids.base.map(|id| id.0))
                    })
                    .then_with(|| {
                        left.word
                            .ids
                            .user
                            .map(|id| id.0)
                            .cmp(&right.word.ids.user.map(|id| id.0))
                    })
            });
        }
        Self { entries, paired }
    }

    pub(super) fn paired(&self, user_id: WordId) -> bool {
        self.paired.contains_key(&user_id)
    }

    /// Visit exact lexical spans, then eligible completions at the input end.
    pub(super) fn visit(
        &self,
        language: Language,
        input: &Input<'_>,
        start: usize,
        limit: usize,
        mut emit: impl FnMut(Match<'a>),
    ) {
        let mut rows = self.entries[language as usize].as_slice();
        for (depth, &byte) in input.spelling(language)[start..limit].iter().enumerate() {
            if byte == 0 {
                break;
            }
            let lower =
                rows.partition_point(|row| row.spelling.get(depth).is_none_or(|&key| key < byte));
            rows = &rows[lower..];
            let upper = rows.partition_point(|row| row.spelling.get(depth) == Some(&byte));
            rows = &rows[..upper];
            if rows.is_empty() {
                break;
            }
            let length = depth + 1;
            let end = start + length;
            let exact = rows.partition_point(|row| row.spelling.len() == length);
            let eligible = if end == input.len() {
                rows
            } else {
                &rows[..exact]
            };
            let mut separators = input.separators(start, end).peekable();
            for row in eligible {
                let missing = row.spelling.len() - length;
                if missing <= MAX_UNTYPED_LETTERS
                    && (language == Language::English
                        || separators.peek().is_none()
                        || matches_separators(row.reading, separators.clone()))
                {
                    emit(Match {
                        end,
                        word: row.word,
                        missing,
                    });
                }
            }
            rows = &rows[exact..];
        }
    }
}

fn lookup_spelling(language: Language, reading: &str) -> Option<Cow<'_, [u8]>> {
    if language == Language::English {
        return (!reading.is_empty()
            && reading.bytes().all(english_key_byte)
            && reading.bytes().any(|byte| byte.is_ascii_alphanumeric()))
        .then(|| {
            if reading.bytes().any(|byte| byte.is_ascii_uppercase()) {
                Cow::Owned(reading.as_bytes().to_ascii_lowercase())
            } else {
                Cow::Borrowed(reading.as_bytes())
            }
        });
    }

    if reading.bytes().all(|byte| byte.is_ascii_lowercase()) && !reading.is_empty() {
        let canonical = lookup_syllable(reading);
        return Some(match canonical {
            Cow::Borrowed(value) => Cow::Borrowed(value.as_bytes()),
            Cow::Owned(value) => Cow::Owned(value.into_bytes()),
        });
    }
    let mut flattened = Vec::with_capacity(reading.len());
    for syllable in reading.split('\'') {
        let syllable = lookup_syllable(syllable);
        if syllable.is_empty() || !syllable.bytes().all(|byte| byte.is_ascii_lowercase()) {
            return None;
        }
        flattened.extend_from_slice(syllable.as_bytes());
    }
    Some(Cow::Owned(flattened))
}

fn matches_separators(reading: &str, separators: impl Iterator<Item = usize>) -> bool {
    let mut ends = reading.split('\'').scan(0, |end, syllable| {
        *end += lookup_syllable(syllable).len();
        Some(*end)
    });
    for separator in separators {
        if ends.find(|&end| end >= separator) != Some(separator) {
            return false;
        }
    }
    true
}

fn lookup_syllable(syllable: &str) -> Cow<'_, str> {
    let lower = if syllable.contains(|character: char| character.is_uppercase()) {
        Cow::Owned(syllable.to_lowercase())
    } else {
        Cow::Borrowed(syllable)
    };
    let canonical = match lower.as_ref() {
        "lue" | "nue" => Cow::Borrowed(lower.as_ref()),
        spelling => canonical_syllable(spelling),
    };
    match canonical {
        Cow::Owned(value) => Cow::Owned(value),
        Cow::Borrowed(value) => match &lower {
            Cow::Borrowed(original) if value == *original => Cow::Borrowed(original),
            _ => Cow::Owned(value.to_owned()),
        },
    }
}
