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
    let mut eligible = vec![false; surface_tokens.unwrap_or(lexicon).len()];
    for (key, word) in lexicon.prefix(index, b"") {
        if word
            .reading
            .is_some_and(|reading| reading.index != index || reading.key != key)
            || !has_full_han_reading(word.text, key)
        {
            continue;
        }
        let token = match surface_tokens {
            Some(tokens) => tokens.find_word(word.text),
            None => Some(word.id),
        };
        if let Some(id) = token {
            eligible[id.0 as usize] = true;
        }
    }
    if !eligible.contains(&true) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Pinyin index contains no eligible Han readings",
        ));
    }

    let candidates = qualifying_bigrams(model.bigrams(), config, |words| {
        words.iter().all(|id| eligible[id.0 as usize])
    });
    let mut added = 0;
    let mut text = String::new();
    for (words, count) in candidates {
        text.clear();
        let tokens = surface_tokens.unwrap_or(lexicon);
        for id in words {
            text.push_str(tokens.word(id).expect("validated gram word ID").text);
        }
        if add_candidate(lexicon, index, review, &text, count)? {
            added += 1;
        }
    }
    Ok(added)
}

pub(super) fn has_full_han_reading(text: &str, key: &[u8]) -> bool {
    let mut syllables = key.split(|&byte| byte == b'\'');
    !text.is_empty()
        && text.chars().all(|character| {
            han::is_han(character)
                && syllables.next().is_some_and(|syllable| {
                    !syllable.is_empty() && syllable.iter().all(u8::is_ascii_lowercase)
                })
        })
        && syllables.next().is_none()
}

fn add_candidate(
    lexicon: &mut Lexicon,
    index: IndexId,
    review: &mut ReviewCsv,
    text: &str,
    count: u64,
) -> io::Result<bool> {
    if lexicon
        .words_for_text(text)
        .any(|word| word.reading.is_none_or(|reading| reading.index == index))
    {
        return Ok(false);
    }
    let Some(key) = word_reading(text) else {
        review.write(text, count)?;
        return Ok(false);
    };
    lexicon
        .add_reading(index, key.as_bytes(), text, count)
        .map_err(io::Error::other)?;
    Ok(true)
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
