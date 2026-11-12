//! Resource loading and offline import shared by SI frontends.

mod csv_output;
mod learn;
mod learning_config;
mod paragraph;
mod paragraph_review;
mod paragraph_snapshot;
mod progress;
mod review;
mod snapshot_csv;
mod source;

use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use si_gram::{GramBuilder, GramModel};
use si_lexicon::{IndexId, Lexicon};

pub use learning_config::LearningConfig;
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
    pub grams: [usize; 3],
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct ParagraphImport {
    pub paragraphs: usize,
    pub matched_words: usize,
    pub added_english_words: usize,
    pub letter_placeholders: usize,
    pub number_placeholders: usize,
    pub unknown_characters: usize,
    pub ambiguous_words: usize,
    pub grams: [usize; 3],
    pub review: Option<LexiconReview>,
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct LexiconLearning {
    /// Number of words added from each order, starting with bigrams.
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
    import_lexicon(output, sources, false)
}

/// Apply additional word counts and lookup keys to a saved dictionary.
pub fn add_lexicon(output: &Path, sources: &[LexiconSource]) -> io::Result<LexiconImport> {
    import_lexicon(output, sources, true)
}

/// Export all word IDs, counts and lookup keys to a new CSV file.
pub fn export_lexicon(source: &Path, output: &Path) -> io::Result<usize> {
    let lexicon = Lexicon::open(source)?;
    snapshot_csv::export(&lexicon, output)?;
    Ok(lexicon.len())
}

/// Restore a complete CSV snapshot at a new path without renumbering word IDs.
pub fn restore_lexicon(source: &Path, output: &Path) -> io::Result<LexiconImport> {
    with_destination(output, false, || {
        let (mut lexicon, report) = snapshot_csv::restore(source)?;
        lexicon.save(output)?;
        Ok(report)
    })
}

/// Learn Han words with complete Pinyin readings and export unresolved candidates.
pub fn learn_lexicon(
    path: &Path,
    grams: &Path,
    config: &LearningConfig,
) -> io::Result<LexiconLearning> {
    with_destination(path, true, || {
        let mut lexicon = Lexicon::open(path)?;
        let model = GramModel::open(grams)?;
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
        if added != [0; 3] {
            lexicon.save(path)?;
        }
        Ok(LexiconLearning { added, review })
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
    mut notify: impl FnMut(CorpusProgress),
) -> io::Result<ParagraphImport> {
    require_sources(sources)?;
    let paths = paragraph_snapshot::Paths::new(lexicon, grams)?;
    let mut destinations = [&paths.lexicon, &paths.grams];
    destinations.sort_unstable();
    let _first_lock = lock_destination(destinations[0], false)?;
    let _second_lock = lock_destination(destinations[1], false)?;
    paths.check_destinations()?;
    if let Some(report) = paths.recover(sources)? {
        return Ok(report);
    }
    let mut progress = ProgressReporter::new(sources.len(), &mut notify);
    paragraph::ingest(&paths, sources, &mut progress)
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

fn import_lexicon(
    output: &Path,
    sources: &[LexiconSource],
    update: bool,
) -> io::Result<LexiconImport> {
    require_sources(sources)?;
    with_destination(output, update, || {
        let mut lexicon = if update {
            Lexicon::open(output)?
        } else {
            Lexicon::new()
        };
        let mut rows = 0;
        for input in sources {
            rows += source::read_lexicon(input, &mut lexicon)?;
        }
        lexicon.save(output)?;
        Ok(LexiconImport {
            rows,
            words: lexicon.len(),
        })
    })
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
