//! Language-independent word storage and byte-key lookup.
//!
//! ```
//! use si_lexicon::{IndexId, Lexicon};
//!
//! let mut lexicon = Lexicon::new();
//! let full = IndexId(0);
//! let initials = IndexId(1);
//! let word = lexicon.add_reading(full, b"chong'qing", "重庆", 42)?;
//! lexicon.add_key(initials, b"cq", word)?;
//! lexicon.compact()?;
//! assert_eq!(lexicon.exact(initials, b"cq").next().unwrap().id, word);
//! assert_eq!(lexicon.word(word).unwrap().count, 42);
//! # Ok::<(), si_lexicon::EditError>(())
//! ```

mod file;
mod index;

use std::collections::HashMap;
use std::fmt;
use std::io;
use std::path::Path;

use index::{KeyIndex, PendingIndex, Postings, merge_keys};

/// A stable word ordinal within one dictionary file and its subsequent snapshots.
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct WordId(pub u32);

/// Identifies a key space, such as a full-spelling index or an initials index.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct IndexId(pub u32);

/// The primary lookup index and reading that identify a lexeme.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Reading<'a> {
    pub index: IndexId,
    pub key: &'a [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Word<'a> {
    pub id: WordId,
    pub text: &'a str,
    pub count: u64,
    pub reading: Option<Reading<'a>>,
}

#[derive(Clone, Copy, Default)]
struct ReadingRecord {
    index: u32,
    end: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EditError {
    EmptyText,
    EmptyKey,
    UnknownWord,
    CountOverflow,
    CapacityExceeded,
    UnresolvedReading,
    InvalidRestoreId,
    DuplicateEntry,
}

impl fmt::Display for EditError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::EmptyText => "word text is empty",
            Self::EmptyKey => "lookup key is empty",
            Self::UnknownWord => "word ID is out of range for this dictionary",
            Self::CountOverflow => "word count exceeds u64",
            Self::CapacityExceeded => "dictionary section exceeds the format's 32-bit limit",
            Self::UnresolvedReading => {
                "existing entry has an unresolved reading; rebuild from the original CSV"
            }
            Self::InvalidRestoreId => "word IDs must be consecutive and start at zero",
            Self::DuplicateEntry => "the same word and primary reading already have an ID",
        })
    }
}

impl std::error::Error for EditError {}

/// One independently editable dictionary. A saved file contains a single snapshot.
#[derive(Default)]
pub struct Lexicon {
    text: String,
    ends: Vec<u32>,
    counts: Vec<u64>,
    readings: Vec<ReadingRecord>,
    reading_bytes: Vec<u8>,
    text_order: Vec<u32>,
    pending_words: HashMap<Box<str>, u32>,
    pending_variants: HashMap<u32, Vec<u32>>,
    index: KeyIndex,
    pending_keys: PendingIndex,
}

impl Lexicon {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.counts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.counts.is_empty()
    }

    /// Add a surface-only token, for example to a character table.
    pub fn add_word(&mut self, text: &str, count: u64) -> Result<WordId, EditError> {
        self.add_entry(text, None, count)
    }

    /// Add or increment one exact spelling and primary reading.
    /// An alternative lookup key can be attached to the returned ID with add_key.
    pub fn add_reading(
        &mut self,
        index: IndexId,
        key: &[u8],
        text: &str,
        count: u64,
    ) -> Result<WordId, EditError> {
        if key.is_empty() {
            return Err(EditError::EmptyKey);
        }
        if self.find_entry(text, None).is_some() {
            return Err(EditError::UnresolvedReading);
        }
        let id = self.add_entry(text, Some(Reading { index, key }), count)?;
        self.add_key(index, key, id)?;
        Ok(id)
    }

    fn add_entry(
        &mut self,
        text: &str,
        reading: Option<Reading<'_>>,
        count: u64,
    ) -> Result<WordId, EditError> {
        if text.is_empty() {
            return Err(EditError::EmptyText);
        }
        if let Some(id) = self.find_entry(text, reading) {
            self.add_count(id, count)?;
            return Ok(id);
        }

        self.insert_entry(text, reading, count)
    }

    /// Restore one word at its original ID, in ascending ID order.
    /// The optional primary reading is also registered as a lookup key.
    pub fn restore_word(
        &mut self,
        id: WordId,
        text: &str,
        count: u64,
        reading: Option<Reading<'_>>,
    ) -> Result<(), EditError> {
        if id.0 as usize != self.len() {
            return Err(EditError::InvalidRestoreId);
        }
        if text.is_empty() {
            return Err(EditError::EmptyText);
        }
        if reading.is_some_and(|reading| reading.key.is_empty()) {
            return Err(EditError::EmptyKey);
        }
        if self.find_entry(text, reading).is_some() {
            return Err(EditError::DuplicateEntry);
        }
        self.insert_entry(text, reading, count)?;
        if let Some(reading) = reading {
            self.add_key(reading.index, reading.key, id)?;
        }
        Ok(())
    }

    fn insert_entry(
        &mut self,
        text: &str,
        reading: Option<Reading<'_>>,
        count: u64,
    ) -> Result<WordId, EditError> {
        let ordinal = section_end(self.len(), 1)? - 1;
        let end = section_end(self.text.len(), text.len())?;
        let key = reading.map_or(&[][..], |reading| reading.key);
        let reading_end = section_end(self.reading_bytes.len(), key.len())?;
        self.text.push_str(text);
        self.ends.push(end);
        self.counts.push(count);
        self.readings.push(ReadingRecord {
            index: reading.map_or(0, |reading| reading.index.0),
            end: reading_end,
        });
        self.reading_bytes.extend_from_slice(key);
        if let Some(&first) = self.pending_words.get(text) {
            self.pending_variants
                .entry(first)
                .or_default()
                .push(ordinal);
        } else {
            self.pending_words.insert(text.into(), ordinal);
        }
        Ok(WordId(ordinal))
    }

    /// Associate an opaque key with an existing word without changing its count.
    /// Returns false if the association already exists.
    pub fn add_key(&mut self, index: IndexId, key: &[u8], word: WordId) -> Result<bool, EditError> {
        if key.is_empty() {
            return Err(EditError::EmptyKey);
        }
        if word.0 as usize >= self.len() {
            return Err(EditError::UnknownWord);
        }
        section_end(0, key.len())?;
        let key = (index, key);
        if self.index.get(key).binary_search(&word.0).is_ok() {
            return Ok(false);
        }
        Ok(self.pending_keys.insert(key, word.0))
    }

    /// Resolve a spelling only when it has a single entry.
    pub fn find_word(&self, text: &str) -> Option<WordId> {
        let mut entries = self.words_for_text(text);
        let id = entries.next()?.id;
        entries.next().is_none().then_some(id)
    }

    /// Find an exact entry by its primary reading, independent of aliases.
    pub fn find_reading(&self, index: IndexId, key: &[u8], text: &str) -> Option<WordId> {
        self.find_entry(text, Some(Reading { index, key }))
    }

    fn find_entry(&self, text: &str, reading: Option<Reading<'_>>) -> Option<WordId> {
        self.words_for_text(text)
            .find(|word| word.reading == reading)
            .map(|word| word.id)
    }

    /// Visit all lexemes with the exact output text.
    pub fn words_for_text<'a>(&'a self, text: &'a str) -> impl Iterator<Item = Word<'a>> + 'a {
        let start = self
            .text_order
            .partition_point(|&id| self.word_text(id) < text);
        let pending = self.pending_words.get(text).copied();
        let variants = pending.and_then(|id| self.pending_variants.get(&id));
        self.text_order[start..]
            .iter()
            .copied()
            .take_while(move |&id| self.word_text(id) == text)
            .chain(pending)
            .chain(variants.into_iter().flatten().copied())
            .map(|id| self.entry(id))
    }

    pub fn word(&self, id: WordId) -> Option<Word<'_>> {
        ((id.0 as usize) < self.len()).then(|| self.entry(id.0))
    }

    /// Add observations to an existing entry without changing its identity or keys.
    pub fn add_count(&mut self, id: WordId, count: u64) -> Result<(), EditError> {
        let current = self
            .counts
            .get_mut(id.0 as usize)
            .ok_or(EditError::UnknownWord)?;
        *current = current.checked_add(count).ok_or(EditError::CountOverflow)?;
        Ok(())
    }

    /// Replace the raw count without changing the word's identity or lookup keys.
    pub fn set_count(&mut self, id: WordId, count: u64) -> Result<(), EditError> {
        *self
            .counts
            .get_mut(id.0 as usize)
            .ok_or(EditError::UnknownWord)? = count;
        Ok(())
    }

    /// Visit words in ascending ID order, including words without lookup keys.
    pub fn words(&self) -> impl ExactSizeIterator<Item = Word<'_>> {
        (0..self.len()).map(|ordinal| self.entry(ordinal as u32))
    }

    /// Visit all lookup associations in index, key and word-ID order.
    pub fn lookup_keys(&self) -> impl Iterator<Item = (Reading<'_>, WordId)> {
        merge_keys(self.index.iter(), self.pending_keys.iter())
            .flat_map(|((index, key), ids)| ids.map(move |id| (Reading { index, key }, WordId(id))))
    }

    /// Exact key lookup in ascending word-ID order.
    pub fn exact(&self, index: IndexId, key: &[u8]) -> impl Iterator<Item = Word<'_>> {
        let key = (index, key);
        Postings::new(self.index.get(key), self.pending_keys.get(key))
            .map(|ordinal| self.entry(ordinal))
    }

    /// Visit keys starting with prefix in byte order, then words by ID.
    /// A word assigned to multiple matching keys appears once for each key.
    pub fn prefix<'a>(
        &'a self,
        index: IndexId,
        prefix: &'a [u8],
    ) -> impl Iterator<Item = (&'a [u8], Word<'a>)> + 'a {
        let key = (index, prefix);
        let packed = self
            .index
            .from(key)
            .take_while(move |&((space, key), _)| space == index && key.starts_with(prefix));
        let pending = self
            .pending_keys
            .from(key)
            .take_while(move |&((space, key), _)| space == index && key.starts_with(prefix));
        merge_keys(packed, pending)
            .flat_map(move |((_, key), ids)| ids.map(move |id| (key, self.entry(id))))
    }

    /// Merge edits into the packed arrays. Existing IDs and query order are preserved.
    pub fn compact(&mut self) -> Result<(), EditError> {
        if !self.pending_keys.is_empty() {
            let mut packed = KeyIndex::default();
            for (key, words) in merge_keys(self.index.iter(), self.pending_keys.iter()) {
                packed.push(key, words)?;
            }
            self.index = packed;
            self.pending_keys = PendingIndex::default();
        }
        if !self.pending_words.is_empty() {
            let mut order = std::mem::take(&mut self.text_order);
            order.extend(self.pending_words.values().copied());
            order.extend(self.pending_variants.values().flatten().copied());
            order.sort_unstable_by(|&left, &right| self.identity(left).cmp(&self.identity(right)));
            self.text_order = order;
            self.pending_words = HashMap::new();
            self.pending_variants = HashMap::new();
        }
        Ok(())
    }

    /// Open and validate a dictionary snapshot.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        file::open(path.as_ref())
    }

    /// Compact and atomically replace the given file with the current snapshot.
    pub fn save(&mut self, path: impl AsRef<Path>) -> io::Result<()> {
        self.compact()
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        file::save(self, path.as_ref())
    }

    fn word_text(&self, ordinal: u32) -> &str {
        &self.text[span(&self.ends, ordinal as usize)]
    }

    fn reading(&self, ordinal: u32) -> Option<Reading<'_>> {
        let position = ordinal as usize;
        let row = self.readings[position];
        let start = position.checked_sub(1).map_or(0, |i| self.readings[i].end);
        (start != row.end).then(|| Reading {
            index: IndexId(row.index),
            key: &self.reading_bytes[start as usize..row.end as usize],
        })
    }

    fn identity(&self, ordinal: u32) -> (&str, Option<Reading<'_>>) {
        (self.word_text(ordinal), self.reading(ordinal))
    }

    fn entry(&self, ordinal: u32) -> Word<'_> {
        let (text, reading) = self.identity(ordinal);
        Word {
            id: WordId(ordinal),
            text,
            count: self.counts[ordinal as usize],
            reading,
        }
    }
}

fn section_end(start: usize, length: usize) -> Result<u32, EditError> {
    start
        .checked_add(length)
        .and_then(|end| u32::try_from(end).ok())
        .ok_or(EditError::CapacityExceeded)
}

fn span(ends: &[u32], position: usize) -> std::ops::Range<usize> {
    let start = position.checked_sub(1).map_or(0, |previous| ends[previous]);
    start as usize..ends[position] as usize
}
