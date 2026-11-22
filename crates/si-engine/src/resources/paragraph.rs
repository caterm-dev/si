use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};

use si_gram::{GramBuilder, GramOrder};
use si_lexicon::{Lexicon, WordId};

use super::paragraph_review::ParagraphReview;
use super::paragraph_snapshot::Paths;
use super::progress::{ProgressCounts, ProgressReporter};
use super::source::read_corpus_lines;
use super::{CorpusProgress, ParagraphImport, open_compatible_grams};
use crate::segmentation::{SegmentKind, Segmenter};

const LETTER_TOKEN: &str = "<char>";
const NUMBER_TOKEN: &str = "<num>";

pub(super) fn ingest(
    paths: &Paths,
    sources: &[PathBuf],
    max_order: GramOrder,
    progress: &mut ProgressReporter<'_>,
) -> io::Result<ParagraphImport> {
    let (mut lexicon, new_lexicon) = match Lexicon::open(&paths.lexicon) {
        Ok(lexicon) => (lexicon, false),
        Err(error) if error.kind() == io::ErrorKind::NotFound => (Lexicon::new(), true),
        Err(error) => return Err(error),
    };
    let mut builder = match open_compatible_grams(&paths.grams, &lexicon) {
        Ok(model) => model.into_builder(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => GramBuilder::new(),
        Err(error) if new_lexicon && error.kind() == io::ErrorKind::InvalidData => {
            return Err(io::Error::new(
                error.kind(),
                format!("cannot use existing grams without a compatible lexicon: {error}"),
            ));
        }
        Err(error) => return Err(error),
    };
    builder.set_max_order(max_order);
    let mut counts = Observations::new(&lexicon);
    {
        let segmenter = Segmenter::new(&lexicon);
        for path in sources {
            counts.read(path, &segmenter, &mut builder, progress)?;
        }
    }
    progress.phase(CorpusProgress::BuildingGrams);
    let mut new_placeholders: Vec<_> = counts.new_placeholders.into_iter().collect();
    new_placeholders.sort_unstable_by_key(|(_, id)| id.0);
    for (text, expected_id) in new_placeholders {
        let id = lexicon.add_word(text, 0).map_err(io::Error::other)?;
        if id != expected_id {
            return Err(io::Error::other(
                "new corpus token ID changed during import",
            ));
        }
    }
    for (id, count) in counts.words {
        lexicon.add_count(id, count).map_err(io::Error::other)?;
    }
    let mut model = builder.finish().map_err(io::Error::other)?;
    model.bind_lexicon(&lexicon)?;
    counts.report.grams = model.sizes();

    progress.phase(CorpusProgress::Saving);
    paths.save(&mut lexicon, &model, counts.review, counts.report, sources)
}

#[derive(Default)]
struct Observations {
    words: HashMap<WordId, u64>,
    new_placeholders: HashMap<&'static str, WordId>,
    placeholders: HashMap<&'static str, WordId>,
    existing_words: usize,
    report: ParagraphImport,
    review: ParagraphReview,
}

impl Observations {
    fn new(lexicon: &Lexicon) -> Self {
        let placeholders = [LETTER_TOKEN, NUMBER_TOKEN]
            .into_iter()
            .filter_map(|token| {
                lexicon
                    .words_for_text(token)
                    .find(|word| word.reading.is_none())
                    .map(|word| (token, word.id))
            })
            .collect();
        Self {
            placeholders,
            existing_words: lexicon.len(),
            ..Self::default()
        }
    }

    fn read(
        &mut self,
        path: &Path,
        segmenter: &Segmenter<'_>,
        builder: &mut GramBuilder,
        progress: &mut ProgressReporter<'_>,
    ) -> io::Result<()> {
        let mut run = Vec::new();
        read_corpus_lines(path, progress, self.progress_counts(), |line, text| {
            self.report.paragraphs += 1;
            for segment in segmenter.segment(text) {
                let id = match segment.kind {
                    SegmentKind::Word(id) => id,
                    SegmentKind::UserWord(_) | SegmentKind::WebAddress { .. } => {
                        unreachable!("base-only segmenter")
                    }
                    SegmentKind::NewEnglishWord => {
                        self.review.record_english(&text[segment.range])?;
                        Self::finish_run(&mut run, builder).map_err(io::Error::other)?;
                        continue;
                    }
                    SegmentKind::Letter | SegmentKind::Number => {
                        let token = if segment.kind == SegmentKind::Letter {
                            self.report.letter_placeholders += 1;
                            LETTER_TOKEN
                        } else {
                            self.report.number_placeholders += 1;
                            NUMBER_TOKEN
                        };
                        let id = match self.placeholders.get(token) {
                            Some(&id) => id,
                            None => self.pending_id(token)?,
                        };
                        run.push(id);
                        continue;
                    }
                    SegmentKind::Space => continue,
                    SegmentKind::Ambiguous | SegmentKind::Unknown | SegmentKind::Boundary => {
                        if segment.kind != SegmentKind::Boundary {
                            self.review.record(
                                &text[segment.range],
                                segment.kind == SegmentKind::Ambiguous,
                                path,
                                line,
                            );
                        }
                        self.report.ambiguous_words +=
                            usize::from(segment.kind == SegmentKind::Ambiguous);
                        self.report.unknown_characters +=
                            usize::from(segment.kind == SegmentKind::Unknown);
                        Self::finish_run(&mut run, builder).map_err(io::Error::other)?;
                        continue;
                    }
                };
                let count = self.words.entry(id).or_default();
                *count = count
                    .checked_add(1)
                    .ok_or_else(|| io::Error::other("word occurrence count exceeds u64"))?;
                self.report.matched_words += 1;
                run.push(id);
            }
            Self::finish_run(&mut run, builder).map_err(io::Error::other)?;
            Ok(self.progress_counts())
        })
    }

    fn progress_counts(&self) -> ProgressCounts {
        ProgressCounts {
            records: self.report.paragraphs,
            matched_tokens: self.report.matched_words,
            unknown_tokens: self.report.unknown_characters,
            unresolved_matches: self.report.ambiguous_words,
        }
    }

    fn pending_id(&mut self, text: &'static str) -> io::Result<WordId> {
        if let Some(&id) = self.new_placeholders.get(text) {
            return Ok(id);
        }
        let ordinal = self
            .existing_words
            .checked_add(self.new_placeholders.len())
            .and_then(|ordinal| u32::try_from(ordinal).ok())
            .ok_or_else(|| io::Error::other("new corpus token ID exceeds the lexicon limit"))?;
        let id = WordId(ordinal);
        self.new_placeholders.insert(text, id);
        Ok(id)
    }

    fn finish_run(
        run: &mut Vec<WordId>,
        builder: &mut GramBuilder,
    ) -> Result<(), si_gram::BuildError> {
        if run.len() >= 2 {
            builder.observe(run)?;
        }
        run.clear();
        Ok(())
    }
}
