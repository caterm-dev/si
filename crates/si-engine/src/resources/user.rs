//! Local user-model updates from explicitly supplied sentences.

mod edit;
pub use edit::UserEntry;
mod ingest;
mod snapshot;

use std::io;
use std::path::PathBuf;

use si_lexicon::{IndexId, Lexicon};

use super::{EngineResources, GramOrder, GramSizes, SiConfig, learn};
use crate::pinyin::word_reading;

pub use super::learning_config::UserLearningConfig;

const PINYIN_INDEX: IndexId = IndexId(0);
const ENGLISH_INDEX: IndexId = IndexId(1);

#[derive(Debug, Default, Eq, PartialEq)]
pub struct UserImport {
    pub already_applied: bool,
    pub sentences: usize,
    pub matched_words: usize,
    pub skipped_spans: usize,
    pub words: usize,
    pub grams: GramSizes,
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct UserLearning {
    pub added_words: usize,
    pub unresolved_readings: usize,
}

/// A private user profile. Pass base resources by reference to ingest or learn.
/// Opening a profile never opens or updates the base resources.
pub struct UserModelStore {
    directory: PathBuf,
}

impl UserModelStore {
    /// Select a dedicated profile directory ending in `.si-user`.
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
        }
    }

    /// Read a consistent user dictionary and word-gram pair, with user-local IDs.
    pub fn load(&self) -> io::Result<Option<EngineResources>> {
        let Some(profile) = snapshot::Profile::open(&self.directory, false)? else {
            return Ok(None);
        };
        let Some(active) = profile.active()? else {
            return Ok(None);
        };
        let directory = profile.slot(active);
        let resources = EngineResources::open(
            &directory.join(snapshot::LEXICON),
            Some(&directory.join(snapshot::GRAMS)),
        )?;
        profile.remove_legacy_sidecars(active)?;
        Ok(Some(resources))
    }

    /// Add each supplied sentence once for a caller-generated opaque batch ID.
    /// A retry with the same ID returns `already_applied` without consuming the
    /// iterator. Distinct IDs can record repeated sentences.
    pub fn ingest<S: AsRef<str>>(
        &self,
        base: &Lexicon,
        batch_id: &str,
        sentences: impl IntoIterator<Item = io::Result<S>>,
    ) -> io::Result<UserImport> {
        self.ingest_with_order(
            base,
            batch_id,
            sentences,
            SiConfig::default().user_max_order,
        )
    }

    /// Use the supplied highest word-gram order for new observations in this batch.
    pub fn ingest_with_order<S: AsRef<str>>(
        &self,
        base: &Lexicon,
        batch_id: &str,
        sentences: impl IntoIterator<Item = io::Result<S>>,
        max_order: GramOrder,
    ) -> io::Result<UserImport> {
        if !snapshot::valid_batch_id(batch_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "batch ID must be 1 to 128 ASCII letters, digits, hyphens, or underscores",
            ));
        }
        let profile = snapshot::Profile::open(&self.directory, true)?.expect("profile was created");
        let active = profile.active()?;
        profile.clean_inactive(active)?;
        let mut state = profile.read(active)?;
        if state.batches.contains(batch_id) {
            return Ok(UserImport {
                already_applied: true,
                words: state.lexicon.len(),
                grams: state.grams.sizes(),
                ..UserImport::default()
            });
        }
        let report = ingest::observe(&mut state, base, sentences, max_order)?;
        if report.sentences != 0 {
            state.batches.insert(batch_id.to_owned());
            profile.publish(active, &mut state)?;
        }
        Ok(report)
    }

    /// Discover compounds from adjacent Pinyin words in this user's word model.
    pub fn learn(&self, base: &Lexicon, config: &UserLearningConfig) -> io::Result<UserLearning> {
        let Some(profile) = snapshot::Profile::open(&self.directory, false)? else {
            return Ok(UserLearning::default());
        };
        let active = profile.active()?;
        profile.clean_inactive(active)?;
        let Some(active) = active else {
            return Ok(UserLearning::default());
        };
        let mut state = profile.read(Some(active))?;
        let candidates = learn::qualifying_bigrams(state.grams.bigrams(), &config.0, |words| {
            words.into_iter().all(|id| {
                let word = state.lexicon.word(id).expect("validated gram word ID");
                word.reading.is_some_and(|reading| {
                    reading.index == PINYIN_INDEX
                        && learn::has_full_han_reading(word.text, reading.key)
                })
            })
        });
        let mut report = UserLearning::default();
        for ([left, right], count) in candidates {
            let left = state.lexicon.word(left).expect("validated gram word ID");
            let right = state.lexicon.word(right).expect("validated gram word ID");
            let mut text = String::from(left.text);
            text.push_str(right.text);
            if [base, &state.lexicon].into_iter().any(|lexicon| {
                lexicon.words_for_text(&text).any(|word| {
                    word.reading
                        .is_some_and(|reading| reading.index == PINYIN_INDEX)
                })
            }) {
                continue;
            }
            let Some(reading) = word_reading(&text) else {
                report.unresolved_readings += 1;
                continue;
            };
            state
                .lexicon
                .add_reading(PINYIN_INDEX, reading.as_bytes(), &text, count)
                .map_err(io::Error::other)?;
            report.added_words += 1;
        }
        if report.added_words != 0 {
            profile.publish(Some(active), &mut state)?;
        }
        Ok(report)
    }

    /// Delete all user vocabulary, gram counts and batch IDs from this profile.
    pub fn clear(&self) -> io::Result<()> {
        if let Some(profile) = snapshot::Profile::open(&self.directory, false)? {
            profile.clear()?;
        }
        Ok(())
    }
}
