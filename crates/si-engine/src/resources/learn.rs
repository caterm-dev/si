use std::collections::HashMap;
use std::io;

use si_gram::GramModel;
use si_lexicon::{IndexId, Lexicon, WordId};

use super::LearningConfig;
use super::learning_config::OrderThreshold;
use super::review::ReviewCsv;
use crate::han;
use crate::pinyin::word_reading;

pub(super) fn add_words(
    lexicon: &mut Lexicon,
    model: &GramModel,
    surface_tokens: Option<&Lexicon>,
    config: &LearningConfig,
    review: &mut ReviewCsv,
) -> io::Result<[usize; 3]> {
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
    Ok([
        learner.add_order(model.bigrams(), config.orders[0])?,
        learner.add_order(model.trigrams(), config.orders[1])?,
        learner.add_order(model.fourgrams(), config.orders[2])?,
    ])
}

struct Learner<'a> {
    lexicon: &'a mut Lexicon,
    characters: HashMap<WordId, char>,
    index: IndexId,
    review: &'a mut ReviewCsv,
}

impl Learner<'_> {
    fn add_order<const N: usize>(
        &mut self,
        grams: impl Iterator<Item = ([WordId; N], u64)> + Clone,
        threshold: OrderThreshold,
    ) -> io::Result<usize> {
        let mut added = 0;
        let mut text = String::new();
        let mut grams = grams.peekable();
        while let Some((first, _)) = grams.peek().copied() {
            let same_prefix = |(words, _): &([WordId; N], u64)| words[..N - 1] == first[..N - 1];
            // Sorted gram rows place every continuation of this prefix together.
            // Count even the rows that do not qualify as dictionary candidates.
            let prefix_total = grams
                .clone()
                .take_while(same_prefix)
                .map(|(_, count)| u128::from(count))
                .sum();
            while let Some((words, count)) = grams.next_if(same_prefix) {
                if threshold.qualifies(count, prefix_total)
                    && self.add_candidate(&words, count, &mut text)?
                {
                    added += 1;
                }
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
