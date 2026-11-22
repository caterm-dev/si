use std::borrow::Cow;
use std::collections::HashMap;
use std::io;

use si_gram::{GramBuilder, GramOrder};
use si_lexicon::{Lexicon, Reading, WordId};

use super::snapshot::State;
use super::{ENGLISH_INDEX, PINYIN_INDEX, UserImport};
use crate::han;
use crate::pinyin::word_reading;
use crate::segmentation::{SegmentKind, Segmenter};

pub(super) fn observe<S: AsRef<str>>(
    state: &mut State,
    base: &Lexicon,
    sentences: impl IntoIterator<Item = io::Result<S>>,
    max_order: GramOrder,
) -> io::Result<UserImport> {
    let mut words = state.take_grams();
    words.set_max_order(max_order);
    let mut report = UserImport::default();
    let segmenter = Segmenter::with_user(base, &state.lexicon);
    let mut changes = WordChanges::default();
    let mut run = Vec::new();
    for (line, sentence) in sentences.into_iter().enumerate() {
        let sentence = sentence?;
        let text = sentence.as_ref();
        let text = if line == 0 {
            text.trim_start_matches('\u{feff}')
        } else {
            text
        };
        if text.trim().is_empty() {
            continue;
        }
        report.sentences += 1;
        for segment in segmenter.segment_user_ingest(text) {
            let surface = &text[segment.range];
            // Exclude isolated ASCII letters even when an existing lexicon knows them.
            // They break adjacency rather than creating grams across the skipped text.
            if surface.len() == 1 && surface.as_bytes()[0].is_ascii_alphabetic() {
                report.skipped_spans += 1;
                finish_run(&mut run, &mut words)?;
                continue;
            }
            let reading = match segment.kind {
                SegmentKind::Space => continue,
                SegmentKind::UserWord(id) => {
                    changes.increment(id)?;
                    run.push(id);
                    report.matched_words += 1;
                    continue;
                }
                SegmentKind::Word(id) => base.word(id).and_then(|word| word.reading),
                SegmentKind::NewEnglishWord | SegmentKind::WebAddress { .. } => {
                    let surface = match segment.kind {
                        SegmentKind::WebAddress {
                            host_end,
                            user_info_bytes: 0,
                        } => Cow::Borrowed(&surface[..host_end]),
                        SegmentKind::WebAddress {
                            host_end,
                            user_info_bytes,
                        } => {
                            let scheme_end =
                                surface.find("://").expect("user info requires a scheme") + 3;
                            Cow::Owned(
                                [
                                    &surface[..scheme_end],
                                    &surface[scheme_end + user_info_bytes..host_end],
                                ]
                                .concat(),
                            )
                        }
                        _ => Cow::Borrowed(surface),
                    };
                    let spelling = surface.to_ascii_lowercase();
                    run.push(changes.observe(
                        &state.lexicon,
                        &surface,
                        Reading {
                            index: ENGLISH_INDEX,
                            key: spelling.as_bytes(),
                        },
                    )?);
                    report.matched_words += 1;
                    continue;
                }
                SegmentKind::Unknown if han::single(surface).is_some() => {
                    if let Some(spelling) = word_reading(surface) {
                        run.push(changes.observe(
                            &state.lexicon,
                            surface,
                            Reading {
                                index: PINYIN_INDEX,
                                key: spelling.as_bytes(),
                            },
                        )?);
                        report.matched_words += 1;
                        continue;
                    }
                    None
                }
                _ => None,
            };
            if let Some(reading) = reading {
                run.push(changes.observe(&state.lexicon, surface, reading)?);
                report.matched_words += 1;
            } else {
                report.skipped_spans += usize::from(segment.kind != SegmentKind::Boundary);
                finish_run(&mut run, &mut words)?;
            }
        }
        finish_run(&mut run, &mut words)?;
    }
    changes.apply(&mut state.lexicon)?;
    state.grams = words.finish().map_err(io::Error::other)?;
    state.grams.bind_lexicon(&state.lexicon)?;
    report.words = state.lexicon.len();
    report.grams = state.grams.sizes();
    Ok(report)
}

#[derive(Default)]
struct WordChanges {
    existing: HashMap<WordId, u64>,
    added: Lexicon,
}

impl WordChanges {
    fn observe(
        &mut self,
        current: &Lexicon,
        text: &str,
        reading: Reading<'_>,
    ) -> io::Result<WordId> {
        if let Some(id) = current.find_reading(reading.index, reading.key, text) {
            self.increment(id)?;
            return Ok(id);
        }
        let id = self
            .added
            .add_reading(reading.index, reading.key, text, 1)
            .map_err(io::Error::other)?;
        let ordinal = (id.0 as usize)
            .checked_add(current.len())
            .and_then(|ordinal| u32::try_from(ordinal).ok())
            .ok_or_else(|| io::Error::other("user dictionary exceeds the word-ID limit"))?;
        Ok(WordId(ordinal))
    }

    fn increment(&mut self, id: WordId) -> io::Result<()> {
        let count = self.existing.entry(id).or_default();
        *count = count
            .checked_add(1)
            .ok_or_else(|| io::Error::other("user word count exceeds u64"))?;
        Ok(())
    }

    fn apply(self, current: &mut Lexicon) -> io::Result<()> {
        for (id, count) in self.existing {
            current.add_count(id, count).map_err(io::Error::other)?;
        }
        // Append new IDs in the same order as the delta lexicon.
        for word in self.added.words() {
            let reading = word.reading.expect("user observations have lookup keys");
            current
                .add_reading(reading.index, reading.key, word.text, word.count)
                .map_err(io::Error::other)?;
        }
        Ok(())
    }
}

fn finish_run(run: &mut Vec<WordId>, grams: &mut GramBuilder) -> io::Result<()> {
    if run.len() >= 2 {
        grams.observe(run).map_err(io::Error::other)?;
    }
    run.clear();
    Ok(())
}
