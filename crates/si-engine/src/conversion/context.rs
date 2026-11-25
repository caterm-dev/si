use std::sync::{Arc, Mutex};

use si_lexicon::{IndexId, Lexicon, Word};

use super::scoring::{History, Scoring};
use super::{Language, WordIds};
use crate::resources::FieldContextConfig;
use crate::segmentation::{Segment, SegmentKind, Segmenter};
use crate::text_boundaries::{Part, is_fragment_start, last_fragment, parts};

const MAX_CACHE_BYTES: usize = 4_096;

/// One transient preceding-text cache per client/session. Queries may share it
/// concurrently; it never retains composition spelling or candidate results.
#[derive(Default)]
pub struct PrecedingTextCache(Mutex<Option<Cached>>);

struct Cached {
    owner: Arc<()>,
    fragment: String,
    field: Arc<FieldContext>,
}

#[derive(Debug, Default, PartialEq)]
pub(super) struct FieldContext {
    pub(super) start: History,
    pub(super) base: Vec<WeightedHistory>,
    pub(super) user: Vec<WeightedHistory>,
}

#[derive(Debug, PartialEq)]
pub(super) struct WeightedHistory {
    pub(super) history: History,
    pub(super) weight: f64,
}

#[cfg(test)]
mod tests;

pub(super) struct Context<'a> {
    base_segmenter: Segmenter<'a>,
    user_segmenter: Option<Segmenter<'a>>,
    base: &'a Lexicon,
    user: Option<&'a Lexicon>,
    config: FieldContextConfig,
    // Keeping the identity alive in a cache prevents allocator-address reuse.
    identity: Arc<()>,
}

impl<'a> Context<'a> {
    pub(super) fn new(
        base: &'a Lexicon,
        user: Option<&'a Lexicon>,
        config: FieldContextConfig,
    ) -> Self {
        Self {
            base_segmenter: Segmenter::new(base),
            user_segmenter: user.map(|user| Segmenter::with_user(base, user)),
            base,
            user,
            config,
            identity: Arc::new(()),
        }
    }

    pub(super) fn history(
        &self,
        preceding_text: Option<&str>,
        scoring: &Scoring<'_>,
        cache: Option<&PrecedingTextCache>,
    ) -> Arc<FieldContext> {
        let Some(preceding_text) = preceding_text else {
            return Arc::default();
        };
        let fragment = last_fragment(preceding_text);
        let cache = cache.filter(|_| fragment.len() <= MAX_CACHE_BYTES);
        if let Some(cache) = cache
            && let Ok(cached) = cache.0.try_lock()
            && let Some(cached) = cached.as_ref()
            && Arc::ptr_eq(&cached.owner, &self.identity)
            && cached.fragment == fragment
        {
            return Arc::clone(&cached.field);
        }
        let field = Arc::new(if is_fragment_start(fragment) {
            FieldContext {
                start: scoring.sentence_start(),
                ..FieldContext::default()
            }
        } else {
            FieldContext {
                base: self.segment_histories(fragment, &self.base_segmenter, false, scoring),
                user: self
                    .user_segmenter
                    .as_ref()
                    .map_or_else(Vec::new, |segmenter| {
                        self.segment_histories(fragment, segmenter, true, scoring)
                    }),
                ..FieldContext::default()
            }
        });
        // Compute outside the lock. A stale query may evict a newer cache entry,
        // but full key/owner checks prevent it from supplying the wrong history.
        if let Some(cache) = cache
            && let Ok(mut cached) = cache.0.try_lock()
        {
            *cached = Some(Cached {
                owner: Arc::clone(&self.identity),
                fragment: fragment.to_owned(),
                field: Arc::clone(&field),
            });
        }
        field
    }

    fn segment_histories(
        &self,
        text: &str,
        segmenter: &Segmenter<'_>,
        user: bool,
        scoring: &Scoring<'_>,
    ) -> Vec<WeightedHistory> {
        let single = || {
            vec![WeightedHistory {
                history: scoring
                    .field_history(self.segment_history(text, segmenter, scoring), user),
                weight: 1.0,
            }]
        };
        if self.config.segmentation_history_limit == 1 {
            return single();
        }
        let Some(mut rows) = segmenter.histories(text, History::default(), |history, segment| {
            scoring.field_history(self.advance(history, text, segment, scoring), user)
        }) else {
            return single();
        };
        // An unrecognized terminal span supplies no word context. Do not revive
        // weaker hypothetical suffixes or spend K slots on all-unknown alternatives.
        if rows.first().is_none_or(|(_, history)| history.is_empty()) {
            return single();
        }
        rows.retain(|(_, history)| !history.is_empty());
        rows.truncate(self.config.segmentation_history_limit);
        let best = rows[0].0;
        let weights: Vec<_> = rows
            .iter()
            .map(|(score, _)| ((score - best) / self.config.segmentation_temperature).exp())
            .collect();
        let mass: f64 = weights.iter().sum();
        rows.into_iter()
            .zip(weights)
            .map(|((_, history), weight)| WeightedHistory {
                history,
                weight: weight / mass,
            })
            .collect()
    }

    fn segment_history(
        &self,
        text: &str,
        segmenter: &Segmenter<'_>,
        scoring: &Scoring<'_>,
    ) -> History {
        let mut history = History::default();
        for part in parts(text) {
            let text = match part {
                Part::Text(text) => text,
                Part::Wrapper => continue,
                Part::SentenceBoundary | Part::Gap => {
                    history = History::default();
                    continue;
                }
            };
            for segment in segmenter.segment(text) {
                history = self.advance(history, text, &segment, scoring);
            }
        }
        history
    }

    fn advance(
        &self,
        previous: History,
        text: &str,
        segment: &Segment,
        scoring: &Scoring<'_>,
    ) -> History {
        let (word, from_user) = match segment.kind {
            SegmentKind::Word(id) => (self.base.word(id), false),
            SegmentKind::UserWord(id) => (self.user.and_then(|user| user.word(id)), true),
            SegmentKind::Letter | SegmentKind::NewEnglishWord => {
                self.english_word(&text[segment.range.clone()], self.user)
            }
            SegmentKind::Space => return previous,
            _ => (None, false),
        };
        word.and_then(|word| {
            let reading = word.reading?;
            let language = Language::from_index(reading.index)?;
            let paired =
                |lexicon: &Lexicon| lexicon.find_reading(reading.index, reading.key, word.text);
            let ids = if from_user {
                WordIds {
                    base: paired(self.base),
                    user: Some(word.id),
                }
            } else {
                WordIds {
                    base: Some(word.id),
                    user: self.user.and_then(paired),
                }
            };
            Some(scoring.extend_history(previous, language, ids))
        })
        .unwrap_or_default()
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
