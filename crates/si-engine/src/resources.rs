//! Resource loading and offline import shared by SI frontends.

mod csv_output;
mod engine_config;
mod learn;
mod learning_config;
mod paragraph;
mod paragraph_review;
mod paragraph_snapshot;
mod progress;
mod review;
mod snapshot_csv;
mod source;
pub mod user;

use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use si_gram::{BigramModel, GramBuilder, GramModel};
use si_lexicon::{IndexId, Lexicon, WordId};

pub use si_gram::{GramOrder, GramSizes};

pub use engine_config::{
    CandidateSearchConfig, EngineConfig, FieldContextConfig, PinyinCorrectionConfig,
    RerankerConfig, SpellingScoringConfig, StatisticalScoringConfig,
};
pub use learning_config::{AppLearningConfig, LearningConfig, SiConfig};
pub use progress::CorpusProgress;
use progress::ProgressReporter;

/// The resources used by a conversion engine.
pub struct EngineResources {
    lexicon: Lexicon,
    grams: Option<GramModel>,
}

impl EngineResources {
    pub fn open(lexicon: &Path, grams: Option<&Path>) -> io::Result<Self> {
        let lexicon = Lexicon::open(lexicon)?;
        let grams = grams
            .map(|path| open_compatible_grams(path, &lexicon))
            .transpose()?;
        Ok(Self { lexicon, grams })
    }

    pub fn lexicon(&self) -> &Lexicon {
        &self.lexicon
    }

    pub fn grams(&self) -> Option<&GramModel> {
        self.grams.as_ref()
    }
}

/// A maintained text,reading,weight CSV or a directory of them, and its key space.
pub struct LexiconSource {
    pub index: IndexId,
    pub path: PathBuf,
}

#[derive(Debug, Eq, PartialEq)]
pub struct LexiconImport {
    pub rows: usize,
    pub words: usize,
}

#[derive(Debug, Eq, PartialEq)]
pub struct CorpusImport {
    pub sentences: usize,
    pub unknown_tokens: usize,
    pub grams: GramSizes,
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct ParagraphImport {
    pub paragraphs: usize,
    pub matched_words: usize,
    /// Preserved for reports recovered from older versions that added English words.
    pub added_english_words: usize,
    pub letter_placeholders: usize,
    pub number_placeholders: usize,
    pub unknown_characters: usize,
    pub ambiguous_words: usize,
    pub grams: GramSizes,
    pub review: Option<LexiconReview>,
    pub english_review: Option<LexiconReview>,
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct LexiconLearning {
    /// Number of words added by order. Learning currently uses only bigrams.
    pub added: [usize; 3],
    pub review: Option<LexiconReview>,
}

#[derive(Debug, Eq, PartialEq)]
pub struct LexiconReview {
    pub path: PathBuf,
    pub rows: usize,
}

/// Build a new dictionary at its own file path.
pub fn build_lexicon(output: &Path, sources: &[LexiconSource]) -> io::Result<LexiconImport> {
    require_sources(sources)?;
    with_destination(output, false, || {
        let mut lexicon = Lexicon::new();
        let rows = read_lexicon_sources(sources, &mut lexicon)?;
        lexicon.save(output)?;
        Ok(LexiconImport {
            rows,
            words: lexicon.len(),
        })
    })
}

/// Append one new primary word identity. An existing identity is never incremented.
pub fn add_lexicon_word(
    path: &Path,
    index: IndexId,
    reading: &[u8],
    text: &str,
    count: u64,
) -> io::Result<WordId> {
    if text.trim().is_empty()
        || text.chars().any(char::is_control)
        || reading.is_empty()
        || !std::str::from_utf8(reading)
            .is_ok_and(|key| !key.trim().is_empty() && !key.chars().any(char::is_control))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid word text or reading",
        ));
    }
    with_destination(path, true, || {
        let mut lexicon = Lexicon::open(path)?;
        if lexicon.find_reading(index, reading, text).is_some() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "word identity already exists in the lexicon",
            ));
        }
        let id = lexicon
            .add_reading(index, reading, text, count)
            .map_err(io::Error::other)?;
        lexicon.save(path)?;
        Ok(id)
    })
}

/// Set an existing primary word identity's absolute count, preserving IDs and aliases.
pub fn update_lexicon_count(
    path: &Path,
    index: IndexId,
    reading: &[u8],
    text: &str,
    count: u64,
) -> io::Result<()> {
    with_destination(path, true, || {
        let mut lexicon = Lexicon::open(path)?;
        let id = lexicon.find_reading(index, reading, text).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "word identity is absent from the lexicon",
            )
        })?;
        if lexicon.word(id).expect("resolved word ID").count != count {
            lexicon.set_count(id, count).map_err(io::Error::other)?;
            lexicon.save(path)?;
        }
        Ok(())
    })
}

/// Export all word IDs, counts and lookup keys to a new CSV file.
pub fn export_lexicon(source: &Path, output: &Path) -> io::Result<usize> {
    let lexicon = Lexicon::open(source)?;
    snapshot_csv::export(&lexicon, output, None)
}

/// Export one primary lookup index and its aliases in the snapshot CSV format.
pub fn export_lexicon_index(source: &Path, output: &Path, index: IndexId) -> io::Result<usize> {
    let lexicon = Lexicon::open(source)?;
    snapshot_csv::export(&lexicon, output, Some(index))
}

/// Restore a complete CSV snapshot at a new path without renumbering word IDs.
pub fn restore_lexicon(source: &Path, output: &Path) -> io::Result<LexiconImport> {
    with_destination(output, false, || {
        let (mut lexicon, report) = snapshot_csv::restore(source)?;
        lexicon.save(output)?;
        Ok(report)
    })
}

/// Learn Han words from adjacent tokens and export candidates with unresolved readings.
pub fn learn_lexicon(
    path: &Path,
    grams: &Path,
    config: &LearningConfig,
) -> io::Result<LexiconLearning> {
    with_destination(path, true, || {
        let mut lexicon = Lexicon::open(path)?;
        let model = BigramModel::open(grams)?;
        let characters;
        let surface_tokens = if model.uses_surface_tokens() {
            characters = source::han_lexicon(&lexicon)?;
            model.check_lexicon(&characters)?;
            Some(&characters)
        } else {
            model.check_lexicon(&lexicon)?;
            None
        };
        let mut review = review::ReviewCsv::new(path);
        let added = learn::add_words(&mut lexicon, &model, surface_tokens, config, &mut review)?;
        let review = review.finish()?;
        if added != 0 {
            lexicon.save(path)?;
        }
        Ok(LexiconLearning {
            added: [added, 0, 0],
            review,
        })
    })
}

/// Build a new gram model from pre-tokenized UTF-8 corpus files.
pub fn build_corpus(
    lexicon: &Path,
    output: &Path,
    sources: &[PathBuf],
) -> io::Result<CorpusImport> {
    count_corpus_with_progress(lexicon, output, sources, CorpusCountMode::Build, |_| {})
}

/// Add observations to an existing gram model.
pub fn add_corpus(lexicon: &Path, output: &Path, sources: &[PathBuf]) -> io::Result<CorpusImport> {
    count_corpus_with_progress(lexicon, output, sources, CorpusCountMode::Add, |_| {})
}

/// Atomically prune one order from an existing corpus snapshot using its paired lexicon.
pub fn prune_corpus(
    lexicon: &Path,
    grams: &Path,
    order: GramOrder,
    min_count: u64,
) -> io::Result<usize> {
    with_destination(grams, true, || {
        let lexicon = Lexicon::open(lexicon)?;
        let mut model = GramModel::open(grams)?;
        let tokens = if model.uses_surface_tokens() {
            source::han_lexicon(&lexicon)?
        } else {
            lexicon
        };
        let removed = model.prune(&tokens, order, min_count)?;
        if removed > 0 {
            model.save(grams)?;
        }
        Ok(removed)
    })
}

/// Segment raw paragraphs and create or update the paired lexicon and gram files.
pub fn ingest_corpus(
    lexicon: &Path,
    grams: &Path,
    sources: &[PathBuf],
) -> io::Result<ParagraphImport> {
    ingest_corpus_with_progress(lexicon, grams, sources, |_| {})
}

/// Import raw paragraphs with progress updates during reading and publication.
pub fn ingest_corpus_with_progress(
    lexicon: &Path,
    grams: &Path,
    sources: &[PathBuf],
    notify: impl FnMut(CorpusProgress),
) -> io::Result<ParagraphImport> {
    ingest_corpus_with_order(
        lexicon,
        grams,
        sources,
        SiConfig::default().base_max_order,
        notify,
    )
}

/// Import raw paragraphs with a maximum word-gram order for this batch.
pub fn ingest_corpus_with_order(
    lexicon: &Path,
    grams: &Path,
    sources: &[PathBuf],
    max_order: GramOrder,
    mut notify: impl FnMut(CorpusProgress),
) -> io::Result<ParagraphImport> {
    require_sources(sources)?;
    let paths = paragraph_snapshot::Paths::new(lexicon, grams)?;
    let _locks = paths.lock_destinations()?;
    paths.check_destinations()?;
    if let Some(report) = paths.recover(sources)? {
        return Ok(report);
    }
    let mut progress = ProgressReporter::new(sources.len(), &mut notify);
    paragraph::ingest(&paths, sources, max_order, &mut progress)
}

/// Delete the gram snapshot under the same locks used by paragraph imports.
/// Returns false when there is no gram snapshot at the requested path.
pub fn clear_corpus_grams(lexicon: &Path, grams: &Path) -> io::Result<bool> {
    paragraph_snapshot::Paths::new(lexicon, grams)?.clear_grams()
}

/// Build a new gram model from contiguous runs of known Han characters.
pub fn build_han_corpus(
    lexicon: &Path,
    output: &Path,
    sources: &[PathBuf],
) -> io::Result<CorpusImport> {
    count_corpus_with_progress(lexicon, output, sources, CorpusCountMode::BuildHan, |_| {})
}

/// Add Han-character observations to an existing character gram model.
pub fn add_han_corpus(
    lexicon: &Path,
    output: &Path,
    sources: &[PathBuf],
) -> io::Result<CorpusImport> {
    count_corpus_with_progress(lexicon, output, sources, CorpusCountMode::AddHan, |_| {})
}

fn read_lexicon_sources(sources: &[LexiconSource], lexicon: &mut Lexicon) -> io::Result<usize> {
    let mut rows = 0;
    for input in sources {
        rows += source::read_lexicon(input, lexicon)?;
    }
    Ok(rows)
}

pub enum CorpusCountMode {
    Build,
    Add,
    BuildHan,
    AddHan,
}

/// Count corpus grams and report progress without changing the final summary.
pub fn count_corpus_with_progress(
    lexicon: &Path,
    output: &Path,
    sources: &[PathBuf],
    mode: CorpusCountMode,
    notify: impl FnMut(CorpusProgress),
) -> io::Result<CorpusImport> {
    count_corpus_with_order(
        lexicon,
        output,
        sources,
        mode,
        SiConfig::default().base_max_order,
        notify,
    )
}

/// Count new corpus observations through the selected order and retain saved counts.
pub fn count_corpus_with_order(
    lexicon: &Path,
    output: &Path,
    sources: &[PathBuf],
    mode: CorpusCountMode,
    max_order: GramOrder,
    mut notify: impl FnMut(CorpusProgress),
) -> io::Result<CorpusImport> {
    require_sources(sources)?;
    let update = matches!(mode, CorpusCountMode::Add | CorpusCountMode::AddHan);
    let use_surfaces = matches!(mode, CorpusCountMode::BuildHan | CorpusCountMode::AddHan);
    let mut progress = ProgressReporter::new(sources.len(), &mut notify);
    with_destination(output, update, || {
        let lexicon = Lexicon::open(lexicon)?;
        let characters;
        let (tokens, lookup) = if use_surfaces {
            characters = source::han_lexicon(&lexicon)?;
            (&characters, source::CorpusLookup::han(&characters))
        } else {
            (&lexicon, source::CorpusLookup::Words(&lexicon))
        };
        let mut builder = if update {
            let model = GramModel::open(output)?;
            if model.uses_surface_tokens() != use_surfaces {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "gram tokenization differs; rebuild the model with the requested corpus mode",
                ));
            }
            model.check_lexicon(tokens)?;
            model.into_builder()
        } else {
            GramBuilder::new()
        };
        builder.set_max_order(max_order);
        let mut counts = progress::ProgressCounts::default();
        for input in sources {
            source::read_corpus(input, &lookup, &mut builder, &mut counts, &mut progress)?;
        }
        progress.phase(CorpusProgress::BuildingGrams);
        let mut model = builder.finish().map_err(io::Error::other)?;
        if use_surfaces {
            model.bind_surface_lexicon(tokens)?;
        } else {
            model.bind_lexicon(tokens)?;
        }
        progress.phase(CorpusProgress::Saving);
        model.save(output)?;
        Ok(CorpusImport {
            sentences: counts.records,
            unknown_tokens: counts.unknown_tokens,
            grams: model.sizes(),
        })
    })
}

fn open_compatible_grams(path: &Path, lexicon: &Lexicon) -> io::Result<GramModel> {
    let model = GramModel::open(path)?;
    if model.uses_surface_tokens() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "surface character grams are for vocabulary discovery; load a word gram model",
        ));
    }
    model.check_lexicon(lexicon)?;
    Ok(model)
}

fn require_sources<T>(sources: &[T]) -> io::Result<()> {
    if sources.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "at least one source file is required",
        ));
    }
    Ok(())
}

fn with_destination<T>(
    path: &Path,
    update: bool,
    import: impl FnOnce() -> io::Result<T>,
) -> io::Result<T> {
    let _lock = lock_destination(path, !update)?;
    paragraph_snapshot::check_no_pending_ingest(path)?;
    check_destination(path, update)?;
    import()
}

fn lock_destination(path: &Path, create_parents: bool) -> io::Result<fs::File> {
    let mut lock_name =
        OsString::from(path.file_name().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "missing output filename")
        })?);
    lock_name.push(".lock");
    if create_parents && let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    // Hold a stable sidecar lock through read, import and atomic replacement.
    let lock = options.open(path.with_file_name(lock_name))?;
    lock.lock()?;
    Ok(lock)
}

fn check_destination(path: &Path, update: bool) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if update && metadata.is_file() => Ok(()),
        Ok(_) if update => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "update requires a regular snapshot file",
        )),
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "destination already exists; choose a new output path",
        )),
        Err(error) if !update && error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}
