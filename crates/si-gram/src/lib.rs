//! Raw occurrence counts for ordered sequences of two to five words.
//!
//! ```
//! use si_gram::GramBuilder;
//! use si_lexicon::Lexicon;
//!
//! let mut lexicon = Lexicon::new();
//! let a = lexicon.add_word("我", 0)?;
//! let b = lexicon.add_word("喜欢", 0)?;
//! let c = lexicon.add_word("喝", 0)?;
//! let d = lexicon.add_word("茶", 0)?;
//!
//! let mut builder = GramBuilder::new();
//! builder.observe(&[a, b, c, d])?;
//! builder.add(&[a, b, c, d], 6)?;
//! let model = builder.finish()?;
//! assert_eq!(model.count(&[b, c, d]), Some(1));
//! assert_eq!(model.context(&[a, b, c]).count(d), Some(7));
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

mod file;
mod table;

use std::collections::{HashMap, hash_map::Entry};
use std::fmt;
use std::io;
use std::num::NonZeroU64;
use std::path::Path;

use si_lexicon::{Lexicon, Word, WordId};
use table::Table;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BuildError {
    InvalidOrder,
    CountOverflow,
    CapacityExceeded,
}

impl fmt::Display for BuildError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidOrder => "a gram must contain two to five words",
            Self::CountOverflow => "gram count exceeds u64",
            Self::CapacityExceeded => "gram table exceeds the 32-bit row limit",
        })
    }
}

impl std::error::Error for BuildError {}

/// Accumulates occurrences using ordinals from one dictionary file.
#[derive(Default)]
pub struct GramBuilder {
    max_order: GramOrder,
    bigrams: HashMap<[u32; 2], u64>,
    trigrams: HashMap<[u32; 3], u64>,
    fourgrams: HashMap<[u32; 4], u64>,
    fivegrams: HashMap<[u32; 5], u64>,
}

impl GramBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the highest order for future observations. Existing counts are retained.
    pub fn set_max_order(&mut self, order: GramOrder) {
        self.max_order = order;
    }

    /// Add a pre-counted gram. A zero count leaves the table unchanged.
    pub fn add(&mut self, words: &[WordId], count: u64) -> Result<(), BuildError> {
        if !(2..=MAX_ORDER).contains(&words.len()) {
            return Err(BuildError::InvalidOrder);
        }
        if count > 0 {
            self.increment(words, count)?;
        }
        Ok(())
    }

    /// Count all overlapping windows within one pre-tokenized sequence.
    /// Call separately at each boundary that grams must not cross.
    /// If any count overflows, leave all counts as they were before the call.
    pub fn observe(&mut self, words: &[WordId]) -> Result<(), BuildError> {
        for order in 2..=self.max_order as usize {
            for (offset, gram) in words.windows(order).enumerate() {
                if let Err(error) = self.increment(gram, 1) {
                    for previous_order in 2..=order {
                        let completed = if previous_order == order {
                            offset
                        } else {
                            words.len()
                        };
                        for previous in words.windows(previous_order).take(completed) {
                            self.undo_observation(previous);
                        }
                    }
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    /// Build immutable, compact query tables.
    pub fn finish(self) -> Result<GramModel, BuildError> {
        Ok(GramModel {
            word_order: None,
            legacy_word_order: false,
            surface_tokens: false,
            bigrams: Table::from_counts(self.bigrams)?,
            trigrams: Table::from_counts(self.trigrams)?,
            fourgrams: Table::from_counts(self.fourgrams)?,
            fivegrams: Table::from_counts(self.fivegrams)?,
        })
    }

    fn increment(&mut self, words: &[WordId], count: u64) -> Result<(), BuildError> {
        match words {
            [a, b] => increment(&mut self.bigrams, ordinals([a, b]), count),
            [a, b, c] => increment(&mut self.trigrams, ordinals([a, b, c]), count),
            [a, b, c, d] => increment(&mut self.fourgrams, ordinals([a, b, c, d]), count),
            [a, b, c, d, e] => increment(&mut self.fivegrams, ordinals([a, b, c, d, e]), count),
            _ => unreachable!("only supported gram orders reach increment"),
        }
    }

    fn undo_observation(&mut self, words: &[WordId]) {
        match words {
            [a, b] => decrement(&mut self.bigrams, ordinals([a, b])),
            [a, b, c] => decrement(&mut self.trigrams, ordinals([a, b, c])),
            [a, b, c, d] => decrement(&mut self.fourgrams, ordinals([a, b, c, d])),
            [a, b, c, d, e] => decrement(&mut self.fivegrams, ordinals([a, b, c, d, e])),
            _ => unreachable!("only supported gram orders reach undo_observation"),
        }
    }
}

fn ordinals<const N: usize>(words: [&WordId; N]) -> [u32; N] {
    words.map(|word| word.0)
}

fn increment<const N: usize>(
    counts: &mut HashMap<[u32; N], u64>,
    key: [u32; N],
    count: u64,
) -> Result<(), BuildError> {
    let total = counts.entry(key).or_default();
    *total = total.checked_add(count).ok_or(BuildError::CountOverflow)?;
    Ok(())
}

fn decrement<const N: usize>(counts: &mut HashMap<[u32; N], u64>, key: [u32; N]) {
    let Entry::Occupied(mut entry) = counts.entry(key) else {
        unreachable!("the observation must exist before rollback");
    };
    if *entry.get() == 1 {
        entry.remove();
    } else {
        *entry.get_mut() -= 1;
    }
}

/// A supported length of a word sequence.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum GramOrder {
    Bigram = 2,
    Trigram = 3,
    #[default]
    Fourgram = 4,
    Fivegram = 5,
}

impl TryFrom<u64> for GramOrder {
    type Error = BuildError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        match value {
            2 => Ok(Self::Bigram),
            3 => Ok(Self::Trigram),
            4 => Ok(Self::Fourgram),
            5 => Ok(Self::Fivegram),
            _ => Err(BuildError::InvalidOrder),
        }
    }
}

pub const MAX_ORDER: usize = GramOrder::Fivegram as usize;

/// Distinct row counts in ascending order, starting with bigrams.
pub type GramSizes = [usize; MAX_ORDER - 1];

/// The bigram portion of a saved gram model.
pub struct BigramModel {
    word_order: Option<NonZeroU64>,
    legacy_word_order: bool,
    surface_tokens: bool,
    bigrams: Table<2>,
}

impl BigramModel {
    /// Read the header and bigram table from a saved model.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        file::open_bigrams(path.as_ref())
    }

    pub fn uses_surface_tokens(&self) -> bool {
        self.surface_tokens
    }

    pub fn bigrams(&self) -> impl ExactSizeIterator<Item = ([WordId; 2], u64)> + Clone + '_ {
        entries(&self.bigrams)
    }

    /// Validate the referenced IDs and the saved word-order checksum.
    pub fn check_lexicon(&self, lexicon: &Lexicon) -> io::Result<()> {
        let required = required_words(self.bigrams.max_word_ordinal())?;
        check_word_bounds(lexicon, required)?;
        if let Some(saved) = self.word_order {
            // The checksum may include IDs used only by a higher-order table.
            // Look for the recorded prefix without reading those tables.
            let prefixes = lexicon.words().scan(WORD_ORDER_HASH_OFFSET, |hash, word| {
                *hash = hash_word(*hash, word, self.legacy_word_order);
                Some(*hash)
            });
            if !std::iter::once(WORD_ORDER_HASH_OFFSET)
                .chain(prefixes)
                .skip(required)
                .any(|hash| nonzero_hash(hash) == saved)
            {
                return Err(word_order_mismatch());
            }
        }
        Ok(())
    }
}

/// Compact counts tied to the lexicon that assigned the word ordinals.
pub struct GramModel {
    word_order: Option<NonZeroU64>,
    legacy_word_order: bool,
    surface_tokens: bool,
    bigrams: Table<2>,
    trigrams: Table<3>,
    fourgrams: Table<4>,
    fivegrams: Table<5>,
}

impl GramModel {
    /// Exact byte length when saved in the current file format, without file I/O.
    pub fn serialized_size(&self) -> u64 {
        file::serialized_size(self)
    }

    /// Number of distinct grams at each supported order, starting with bigrams.
    pub fn sizes(&self) -> GramSizes {
        [
            self.bigrams.keys.len(),
            self.trigrams.keys.len(),
            self.fourgrams.keys.len(),
            self.fivegrams.keys.len(),
        ]
    }

    /// Remove rows with counts below `min_count` from one order and return the number removed.
    /// `lexicon` must assign the model's token IDs, including for surface-token models.
    pub fn prune(
        &mut self,
        lexicon: &Lexicon,
        order: GramOrder,
        min_count: u64,
    ) -> io::Result<usize> {
        let previous_words = self.validate_word_order(lexicon)?;
        let removed = match order {
            GramOrder::Bigram => self.bigrams.prune(min_count),
            GramOrder::Trigram => self.trigrams.prune(min_count),
            GramOrder::Fourgram => self.fourgrams.prune(min_count),
            GramOrder::Fivegram => self.fivegrams.prune(min_count),
        };
        if removed > 0 {
            // Removing the highest ordinal can shorten the checksummed prefix.
            let words = self.required_words()?;
            if words != previous_words || self.word_order.is_none() {
                self.word_order = Some(word_order_checksum(lexicon, words, self.legacy_word_order));
            }
        }
        Ok(removed)
    }

    /// Visit bigrams and their raw counts in word-ordinal order.
    pub fn bigrams(&self) -> impl ExactSizeIterator<Item = ([WordId; 2], u64)> + Clone + '_ {
        entries(&self.bigrams)
    }

    /// Visit trigrams and their raw counts in word-ordinal order.
    pub fn trigrams(&self) -> impl ExactSizeIterator<Item = ([WordId; 3], u64)> + Clone + '_ {
        entries(&self.trigrams)
    }

    /// Visit four-grams and their raw counts in word-ordinal order.
    pub fn fourgrams(&self) -> impl ExactSizeIterator<Item = ([WordId; 4], u64)> + Clone + '_ {
        entries(&self.fourgrams)
    }

    /// Visit five-grams and their raw counts in word-ordinal order.
    pub fn fivegrams(&self) -> impl ExactSizeIterator<Item = ([WordId; 5], u64)> + Clone + '_ {
        entries(&self.fivegrams)
    }

    /// Largest word ordinal referenced anywhere in the model.
    pub fn max_word_ordinal(&self) -> Option<u32> {
        [
            self.bigrams.max_word_ordinal(),
            self.trigrams.max_word_ordinal(),
            self.fourgrams.max_word_ordinal(),
            self.fivegrams.max_word_ordinal(),
        ]
        .into_iter()
        .flatten()
        .max()
    }

    /// Record the ordered word text needed to check future file pairings.
    /// Words appended beyond the model's last referenced ordinal remain compatible.
    pub fn bind_lexicon(&mut self, lexicon: &Lexicon) -> io::Result<()> {
        let words = self.validate_word_order(lexicon)?;
        self.word_order = Some(word_order_checksum(lexicon, words, false));
        self.legacy_word_order = false;
        Ok(())
    }

    /// Bind a model whose token IDs represent written surfaces for discovery.
    pub fn bind_surface_lexicon(&mut self, lexicon: &Lexicon) -> io::Result<()> {
        self.bind_lexicon(lexicon)?;
        self.surface_tokens = true;
        Ok(())
    }

    pub fn uses_surface_tokens(&self) -> bool {
        self.surface_tokens
    }

    /// Check ordinal bounds and any recorded word-order checksum.
    pub fn check_lexicon(&self, lexicon: &Lexicon) -> io::Result<()> {
        self.validate_word_order(lexicon).map(|_| ())
    }

    fn validate_word_order(&self, lexicon: &Lexicon) -> io::Result<usize> {
        let words = self.required_words()?;
        check_word_bounds(lexicon, words)?;
        if self.word_order.is_some_and(|saved| {
            saved != word_order_checksum(lexicon, words, self.legacy_word_order)
        }) {
            return Err(word_order_mismatch());
        }
        Ok(words)
    }

    fn required_words(&self) -> io::Result<usize> {
        required_words(self.max_word_ordinal())
    }

    /// Move existing raw counts back into a builder for incremental imports.
    pub fn into_builder(self) -> GramBuilder {
        GramBuilder {
            max_order: GramOrder::default(),
            bigrams: self.bigrams.into_counts(),
            trigrams: self.trigrams.into_counts(),
            fourgrams: self.fourgrams.into_counts(),
            fivegrams: self.fivegrams.into_counts(),
        }
    }

    /// Return the raw count for an exact sequence of dictionary-local word IDs.
    pub fn count(&self, words: &[WordId]) -> Option<u64> {
        match words {
            [a, b] => self.bigrams.count(ordinals([a, b])),
            [a, b, c] => self.trigrams.count(ordinals([a, b, c])),
            [a, b, c, d] => self.fourgrams.count(ordinals([a, b, c, d])),
            [a, b, c, d, e] => self.fivegrams.count(ordinals([a, b, c, d, e])),
            _ => None,
        }
    }

    /// Prepare the observed continuations of a one- to four-word history.
    /// A prepared context can score several candidates with the same history.
    pub fn context(&self, history: &[WordId]) -> Context<'_> {
        let (keys, counts) = match history {
            [a] => {
                let (keys, counts) = self.bigrams.prefix(ordinals([a]));
                (ContextKeys::Bigram(keys), counts)
            }
            [a, b] => {
                let (keys, counts) = self.trigrams.prefix(ordinals([a, b]));
                (ContextKeys::Trigram(keys), counts)
            }
            [a, b, c] => {
                let (keys, counts) = self.fourgrams.prefix(ordinals([a, b, c]));
                (ContextKeys::Fourgram(keys), counts)
            }
            [a, b, c, d] => {
                let (keys, counts) = self.fivegrams.prefix(ordinals([a, b, c, d]));
                (ContextKeys::Fivegram(keys), counts)
            }
            _ => (ContextKeys::Bigram(&[]), &[][..]),
        };
        Context { keys, counts }
    }

    /// Open and validate a saved model.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        file::open(path.as_ref())
    }

    /// Write a snapshot and replace the destination after it has been synced.
    pub fn save(&self, path: impl AsRef<Path>) -> io::Result<()> {
        file::save(self, path.as_ref())
    }
}

fn required_words(maximum: Option<u32>) -> io::Result<usize> {
    maximum.map_or(Ok(0), |ordinal| {
        (ordinal as usize).checked_add(1).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "gram word ordinal is out of range",
            )
        })
    })
}

fn check_word_bounds(lexicon: &Lexicon, required: usize) -> io::Result<()> {
    if required > lexicon.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "gram model references words missing from the lexicon snapshot",
        ));
    }
    Ok(())
}

fn word_order_mismatch() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "gram model word order does not match the lexicon snapshot",
    )
}

const WORD_ORDER_HASH_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

fn word_order_checksum(lexicon: &Lexicon, words: usize, legacy: bool) -> NonZeroU64 {
    nonzero_hash(
        lexicon
            .words()
            .take(words)
            .fold(WORD_ORDER_HASH_OFFSET, |hash, word| {
                hash_word(hash, word, legacy)
            }),
    )
}

fn hash_word(mut hash: u64, word: Word<'_>, legacy: bool) -> u64 {
    // FNV-1a over exact text and the primary reading in ordinal order.
    hash = hash_bytes(hash, word.text.as_bytes());
    hash = hash_bytes(hash, &[0xff]); // Not a UTF-8 byte.
    if !legacy {
        hash = hash_bytes(hash, &[u8::from(word.reading.is_some())]);
        if let Some(reading) = word.reading {
            hash = hash_bytes(hash, &reading.index.0.to_le_bytes());
            hash = hash_bytes(hash, &(reading.key.len() as u32).to_le_bytes());
            hash = hash_bytes(hash, reading.key);
        }
    }
    hash
}

fn nonzero_hash(hash: u64) -> NonZeroU64 {
    NonZeroU64::new(hash).unwrap_or(NonZeroU64::MIN)
}

fn hash_bytes(mut hash: u64, bytes: &[u8]) -> u64 {
    for &byte in bytes {
        hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

fn entries<const N: usize>(
    table: &Table<N>,
) -> impl ExactSizeIterator<Item = ([WordId; N], u64)> + Clone + '_ {
    table
        .keys
        .iter()
        .zip(&table.counts)
        .map(|(&key, &count)| (key.map(WordId), count))
}

enum ContextKeys<'a> {
    Bigram(&'a [[u32; 2]]),
    Trigram(&'a [[u32; 3]]),
    Fourgram(&'a [[u32; 4]]),
    Fivegram(&'a [[u32; 5]]),
}

/// A borrowed range of observed continuations for one history.
pub struct Context<'a> {
    keys: ContextKeys<'a>,
    counts: &'a [u64],
}

impl Context<'_> {
    pub fn count(&self, next: WordId) -> Option<u64> {
        let index = match self.keys {
            ContextKeys::Bigram(keys) => keys.binary_search_by_key(&next.0, |key| key[1]),
            ContextKeys::Trigram(keys) => keys.binary_search_by_key(&next.0, |key| key[2]),
            ContextKeys::Fourgram(keys) => keys.binary_search_by_key(&next.0, |key| key[3]),
            ContextKeys::Fivegram(keys) => keys.binary_search_by_key(&next.0, |key| key[4]),
        };
        index.ok().map(|index| self.counts[index])
    }

    /// Visit the observed next words in ascending ordinal order.
    pub fn continuations(&self) -> impl ExactSizeIterator<Item = (WordId, u64)> + '_ {
        self.counts.iter().enumerate().map(|(index, &count)| {
            let ordinal = match self.keys {
                ContextKeys::Bigram(keys) => keys[index][1],
                ContextKeys::Trigram(keys) => keys[index][2],
                ContextKeys::Fourgram(keys) => keys[index][3],
                ContextKeys::Fivegram(keys) => keys[index][4],
            };
            (WordId(ordinal), count)
        })
    }
}
