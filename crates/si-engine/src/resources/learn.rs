use std::collections::HashMap;
use std::io;

use si_gram::BigramModel;
use si_lexicon::{IndexId, Lexicon, WordId};

use super::LearningConfig;
use super::review::ReviewCsv;
use crate::han;
use crate::pinyin::word_reading;

pub(super) fn add_words(
    lexicon: &mut Lexicon,
    model: &BigramModel,
    surface_tokens: Option<&Lexicon>,
    config: &LearningConfig,
    review: &mut ReviewCsv,
) -> io::Result<usize> {
    let index = config.pinyin_index;
    let mut characters = HashMap::new();
    for (key, word) in lexicon.prefix(index, b"") {
        if !key.iter().all(u8::is_ascii_lowercase)
            || word
                .reading
                .is_some_and(|reading| reading.index != index || reading.key != key)
        {
            continue;
        }
        if let Some(character) = han::single(word.text) {
            let id = match surface_tokens {
                Some(tokens) => tokens
                    .find_word(word.text)
                    .expect("known Han surface token"),
                None => word.id,
            };
            characters.insert(id, character);
        }
    }
    if characters.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Pinyin index contains no single-character readings",
        ));
    }

    let mut learner = Learner {
        lexicon,
        characters,
        index,
        review,
    };
    learner.add_bigrams(model, config)
}

struct Learner<'a> {
    lexicon: &'a mut Lexicon,
    characters: HashMap<WordId, char>,
    index: IndexId,
    review: &'a mut ReviewCsv,
}

impl Learner<'_> {
    fn add_bigrams(&mut self, model: &BigramModel, config: &LearningConfig) -> io::Result<usize> {
        let candidates = qualifying_bigrams(model.bigrams(), config, |words| {
            words.iter().all(|word| self.characters.contains_key(word))
        });
        let mut added = 0;
        let mut text = String::new();
        for (words, count) in candidates {
            if self.add_candidate(&words, count, &mut text)? {
                added += 1;
            }
        }
        Ok(added)
    }

    fn add_candidate(
        &mut self,
        words: &[WordId],
        count: u64,
        text: &mut String,
    ) -> io::Result<bool> {
        text.clear();
        for word in words {
            let Some(&character) = self.characters.get(word) else {
                return Ok(false);
            };
            text.push(character);
        }
        if self.lexicon.words_for_text(text).any(|word| {
            word.reading
                .is_none_or(|reading| reading.index == self.index)
        }) {
            return Ok(false);
        }
        let Some(key) = word_reading(text) else {
            self.review.write(text, count)?;
            return Ok(false);
        };
        self.lexicon
            .add_reading(self.index, key.as_bytes(), text, count)
            .map_err(io::Error::other)?;
        Ok(true)
    }
}

pub(super) fn qualifying_bigrams(
    bigrams: impl Iterator<Item = ([WordId; 2], u64)> + Clone,
    config: &LearningConfig,
    eligible: impl Fn([WordId; 2]) -> bool,
) -> Vec<([WordId; 2], u64)> {
    let mut candidates = Vec::new();
    let mut left_counts = HashMap::new();
    let mut right_counts = HashMap::new();
    let mut total = 0;
    for (words, count) in bigrams.clone() {
        total += u128::from(count);
        if count >= config.min_count && eligible(words) {
            candidates.push((words, count));
            left_counts.entry(words[0]).or_insert(0);
            right_counts.entry(words[1]).or_insert(0);
        }
    }
    if !candidates.is_empty() {
        // Include low-frequency rows and other tokens in each marginal.
        for ([left, right], count) in bigrams {
            if let Some(total) = left_counts.get_mut(&left) {
                *total += u128::from(count);
            }
            if let Some(total) = right_counts.get_mut(&right) {
                *total += u128::from(count);
            }
        }
        candidates.retain(|&([left, right], count)| {
            config.qualifies(count, left_counts[&left], right_counts[&right], total)
        });
    }
    candidates
}
