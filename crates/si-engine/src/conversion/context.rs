use si_lexicon::{IndexId, Lexicon, Word};

use super::scoring::{History, Scoring};
use super::{Language, WordIds};
use crate::segmentation::{SegmentKind, Segmenter};
use crate::text_boundaries::{Part, is_fragment_start, last_fragment, parts};

pub(super) struct Context<'a> {
    base_segmenter: Segmenter<'a>,
    user_segmenter: Option<Segmenter<'a>>,
    base: &'a Lexicon,
    user: Option<&'a Lexicon>,
}

impl<'a> Context<'a> {
    pub(super) fn new(base: &'a Lexicon, user: Option<&'a Lexicon>) -> Self {
        Self {
            base_segmenter: Segmenter::new(base),
            user_segmenter: user.map(|user| Segmenter::with_user(base, user)),
            base,
            user,
        }
    }

    pub(super) fn history(&self, preceding_text: Option<&str>, scoring: &Scoring<'_>) -> History {
        let Some(preceding_text) = preceding_text else {
            return History::default();
        };
        let sentence = last_fragment(preceding_text);
        if is_fragment_start(sentence) {
            return scoring.sentence_start();
        }
        let base = self.segment_history(sentence, &self.base_segmenter, None, scoring);
        let user = self
            .user_segmenter
            .as_ref()
            .map_or_else(History::default, |segmenter| {
                self.segment_history(sentence, segmenter, self.user, scoring)
            });
        History::from_field(base, user)
    }

    fn segment_history(
        &self,
        sentence: &str,
        segmenter: &Segmenter<'_>,
        user: Option<&'a Lexicon>,
        scoring: &Scoring<'_>,
    ) -> History {
        let mut history = History::default();
        for part in parts(sentence) {
            let text = match part {
                Part::Text(text) => text,
                Part::Wrapper => continue,
                Part::SentenceBoundary | Part::Gap => {
                    history = History::default();
                    continue;
                }
            };
            for segment in segmenter.segment(text) {
                let (word, from_user) = match segment.kind {
                    SegmentKind::Word(id) => (self.base.word(id), false),
                    SegmentKind::UserWord(id) => (user.and_then(|user| user.word(id)), true),
                    SegmentKind::Letter | SegmentKind::NewEnglishWord => {
                        self.english_word(&text[segment.range], user)
                    }
                    SegmentKind::Space => continue,
                    _ => (None, false),
                };
                history = word
                    .and_then(|word| {
                        let reading = word.reading?;
                        let language = Language::from_index(reading.index)?;
                        let paired = |lexicon: &Lexicon| {
                            lexicon.find_reading(reading.index, reading.key, word.text)
                        };
                        let ids = if from_user {
                            WordIds {
                                base: paired(self.base),
                                user: Some(word.id),
                            }
                        } else {
                            WordIds {
                                base: Some(word.id),
                                user: user.and_then(paired),
                            }
                        };
                        Some(scoring.extend_history(history, language, ids))
                    })
                    .unwrap_or_default();
            }
        }
        history
    }

    fn english_word(&self, surface: &str, user: Option<&'a Lexicon>) -> (Option<Word<'_>>, bool) {
        let lower = surface.to_ascii_lowercase();
        let find = |lexicon: &'a Lexicon| {
            lexicon
                .find_reading(IndexId(1), lower.as_bytes(), &lower)
                .and_then(|id| lexicon.word(id))
        };
        match find(self.base) {
            Some(word) => (Some(word), false),
            None => (user.and_then(find), true),
        }
    }
}
