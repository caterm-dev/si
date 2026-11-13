use std::borrow::Cow;
use std::collections::HashMap;

use si_lexicon::{Lexicon, WordId};

use super::input::{Input, english_key_byte};
use super::{CandidateLanguage, Language, PersonalPhrase, WordIds};
use crate::pinyin::canonical_syllable;

const MAX_UNTYPED_LETTERS: usize = 8;
const ABBREVIATION_ROWS: usize = 32;

#[derive(Clone, Copy)]
pub(super) struct Lexeme<'a> {
    pub(super) text: &'a str,
    pub(super) ids: WordIds,
    pub(super) language: Language,
    pub(super) personal: Option<bool>,
    pub(super) verbatim: bool,
    count: u64,
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
    reading: &'a str,
    abbreviated: bool,
}

impl Match<'_> {
    pub(super) fn verbatim(text: &str, end: usize) -> Match<'_> {
        Match {
            end,
            word: Lexeme {
                text,
                ids: WordIds::default(),
                language: Language::English,
                personal: None,
                verbatim: true,
                count: 0,
            },
            missing: 0,
            reading: "",
            abbreviated: false,
        }
    }

    pub(super) fn cuts(self, start: usize, input: &Input<'_>) -> Vec<usize> {
        let mut cuts = Vec::new();
        if self.word.language == Language::Chinese && !self.abbreviated {
            let mut position = start;
            for syllable in self.reading.split('\'') {
                position += lookup_syllable(syllable).len();
                if position >= self.end {
                    break;
                }
                cuts.push(input.source_end(position));
            }
        }
        cuts.push(input.source_end(self.end));
        cuts
    }

    pub(super) fn is_abbreviated(self) -> bool {
        self.abbreviated
    }
}

pub(super) struct Lookup<'a> {
    entries: [Vec<Entry<'a>>; 2],
    paired: HashMap<WordId, WordId>,
    abbreviated: HashMap<Vec<u8>, Vec<Entry<'a>>>,
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
        let mut abbreviated: HashMap<Vec<u8>, Vec<Entry<'a>>> = HashMap::new();
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
                let row = Lexeme {
                    text: word.text,
                    ids,
                    language,
                    personal: None,
                    verbatim: false,
                    count: word.count,
                };
                if language == Language::Chinese
                    && word.reading.is_some_and(|primary| primary.key == key.key)
                {
                    add_abbreviations(&mut abbreviated, reading, row);
                }
                entries[language as usize].push(Entry {
                    spelling,
                    reading,
                    word: row,
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
        for rows in abbreviated.values_mut() {
            rows.sort_unstable_by(abbreviation_order);
            rows.truncate(ABBREVIATION_ROWS);
        }
        Self {
            entries,
            paired,
            abbreviated,
        }
    }

    pub(super) fn paired(&self, user_id: WordId) -> bool {
        self.paired.contains_key(&user_id)
    }

    pub(super) fn personal(phrases: &[PersonalPhrase<'a>]) -> Self {
        let mut entries: [Vec<_>; 2] = Default::default();
        for phrase in phrases.iter().take(1_000) {
            let language = match phrase.language {
                CandidateLanguage::Chinese => Language::Chinese,
                CandidateLanguage::English => Language::English,
                _ => continue,
            };
            if phrase.spelling.len() > 64 || phrase.text.is_empty() || phrase.text.len() > 1_024 {
                continue;
            }
            let spelling = if language == Language::English && phrase.spelling.contains('\'') {
                let key: Vec<_> = phrase
                    .spelling
                    .bytes()
                    .filter(|&byte| byte != b'\'')
                    .collect();
                (!key.is_empty() && key.iter().copied().all(english_key_byte))
                    .then_some(Cow::Owned(key))
            } else {
                lookup_spelling(language, phrase.spelling)
            };
            let Some(spelling) = spelling else {
                continue;
            };
            entries[language as usize].push(Entry {
                spelling,
                reading: phrase.spelling,
                word: Lexeme {
                    text: phrase.text,
                    ids: WordIds::default(),
                    language,
                    personal: Some(phrase.pinned),
                    verbatim: false,
                    count: 0,
                },
            });
        }
        for lane in &mut entries {
            lane.sort_unstable_by(|a, b| {
                a.spelling
                    .cmp(&b.spelling)
                    .then_with(|| b.word.personal.cmp(&a.word.personal))
                    .then_with(|| a.word.text.cmp(b.word.text))
                    .then_with(|| a.reading.cmp(b.reading))
            });
        }
        Self {
            entries,
            paired: HashMap::new(),
            abbreviated: HashMap::new(),
        }
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
            let first_separator = separators.peek().copied();
            let english = language == Language::English;
            if english
                && first_separator.is_some_and(|cut| cut < length)
                && rows[0].word.personal.is_none()
            {
                break;
            }
            for row in eligible {
                let missing = row.spelling.len() - length;
                let permits_separators = if row.word.personal.is_some() {
                    let required = row
                        .reading
                        .split('\'')
                        .scan(0, |end, part| {
                            *end += if english {
                                part.len()
                            } else {
                                lookup_syllable(part).len()
                            };
                            Some(*end)
                        })
                        .filter(|&cut| cut < row.spelling.len() && cut <= length);
                    required.eq(separators
                        .clone()
                        .filter(|&cut| cut < length || missing != 0))
                } else if english {
                    first_separator.is_none_or(|cut| cut == length && missing == 0)
                } else {
                    separators.peek().is_none()
                        || matches_separators(row.reading, separators.clone())
                };
                if permits_separators
                    && (missing <= MAX_UNTYPED_LETTERS || row.word.personal.is_some())
                {
                    emit(Match {
                        end,
                        word: row.word,
                        missing,
                        reading: row.reading,
                        abbreviated: false,
                    });
                }
            }
            rows = &rows[exact..];
        }
        if language == Language::Chinese {
            for end in (start + 2)..=limit.min(start + 7) {
                let key = &input.spelling(language)[start..end];
                if key.contains(&0) {
                    break;
                }
                let Some(rows) = self.abbreviated.get(key) else {
                    continue;
                };
                let separators = input.separators(start, end);
                for row in rows {
                    if separators
                        .clone()
                        .all(|cut| cut == key.len() - 1 || cut == key.len())
                    {
                        emit(Match {
                            end,
                            word: row.word,
                            missing: 0,
                            reading: row.reading,
                            abbreviated: true,
                        });
                    }
                }
            }
        }
    }
}

fn add_abbreviations<'a>(
    index: &mut HashMap<Vec<u8>, Vec<Entry<'a>>>,
    reading: &'a str,
    word: Lexeme<'a>,
) {
    let mut syllables = reading.split('\'');
    let Some(first) = syllables.next().filter(|s| s.len() > 1) else {
        return;
    };
    let Some(second) = syllables.next().filter(|s| s.len() > 1) else {
        return;
    };
    if syllables.next().is_some()
        || !first
            .bytes()
            .chain(second.bytes())
            .all(|byte| byte.is_ascii_lowercase())
    {
        return;
    }
    for key in [
        vec![first.as_bytes()[0], second.as_bytes()[0]],
        [first.as_bytes(), &second.as_bytes()[..1]].concat(),
    ] {
        let rows = index.entry(key).or_default();
        rows.push(Entry {
            spelling: Cow::Borrowed(&[]),
            reading,
            word,
        });
        if rows.len() == ABBREVIATION_ROWS * 2 {
            rows.sort_unstable_by(abbreviation_order);
            rows.truncate(ABBREVIATION_ROWS);
        }
    }
}

fn abbreviation_order(left: &Entry<'_>, right: &Entry<'_>) -> std::cmp::Ordering {
    right
        .word
        .count
        .cmp(&left.word.count)
        .then_with(|| left.word.text.cmp(right.word.text))
        .then_with(|| left.reading.cmp(right.reading))
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
