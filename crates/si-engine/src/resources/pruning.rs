//! Capacity policy for a paired lexicon and word-gram model. No file I/O.
use std::cmp::Reverse;
use std::io;

use si_gram::{GramBuilder, GramModel};
use si_lexicon::Lexicon;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ModelPruning {
    pub removed_words: usize,
    pub removed_grams: usize,
    pub bytes: u64,
}

/// Fit the pair into `max_bytes`, excluding any caller-owned metadata.
/// Remove lowest-count grams first (ties: higher order, then original row order), then
/// lowest-count words if the dictionary alone is too large. Surviving counts/readings/aliases
/// are preserved; lexicon pruning changes IDs only after all grams have been removed.
/// Callers publish the resulting pair together, under their existing storage transaction.
pub fn prune_model_to_bytes(
    lexicon: &mut Lexicon,
    grams: &mut GramModel,
    max_bytes: u64,
) -> io::Result<ModelPruning> {
    grams.check_lexicon(lexicon)?;
    let empty_grams = GramBuilder::new().finish().map_err(io::Error::other)?;
    let minimum =
        Lexicon::new().serialized_size().map_err(io::Error::other)? + empty_grams.serialized_size();
    if max_bytes < minimum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "model capacity is smaller than empty file headers",
        ));
    }
    let words_before = lexicon.len();
    let grams_before: usize = grams.sizes().iter().sum();
    let lexicon_bytes = lexicon.serialized_size().map_err(io::Error::other)?;
    let mut bytes = lexicon_bytes + grams.serialized_size();
    if bytes > max_bytes && grams_before != 0 {
        // Keep only compact sort keys; do not duplicate token arrays for every candidate row.
        let mut order = Vec::with_capacity(grams_before);
        macro_rules! candidates {
            ($rows:expr, $n:expr) => {
                order.extend(
                    $rows
                        .enumerate()
                        .map(|(index, (_, count))| (count, Reverse($n), index)),
                );
            };
        }
        candidates!(grams.bigrams(), 2usize);
        candidates!(grams.trigrams(), 3usize);
        candidates!(grams.fourgrams(), 4usize);
        candidates!(grams.fivegrams(), 5usize);
        order.sort_unstable();
        let mut cutoff = None;
        for key in order {
            if bytes <= max_bytes {
                break;
            }
            bytes -= (4 * key.1.0 + 8) as u64;
            cutoff = Some(key);
        }
        let mut builder = GramBuilder::new();
        macro_rules! keep {
            ($rows:expr, $n:expr) => {
                for (index, (ids, count)) in $rows.enumerate() {
                    if cutoff.is_none_or(|cutoff| (count, Reverse($n), index) > cutoff) {
                        builder.add(&ids, count).map_err(io::Error::other)?;
                    }
                }
            };
        }
        keep!(grams.bigrams(), 2usize);
        keep!(grams.trigrams(), 3usize);
        keep!(grams.fourgrams(), 4usize);
        keep!(grams.fivegrams(), 5usize);
        let mut next = builder.finish().map_err(io::Error::other)?;
        if grams.uses_surface_tokens() {
            next.bind_surface_lexicon(lexicon)?;
        } else {
            next.bind_lexicon(lexicon)?;
        }
        *grams = next;
    }
    if lexicon_bytes + grams.serialized_size() > max_bytes {
        // The gram pass exhausted all rows. There are no live references to remap.
        lexicon
            .prune_to_bytes(max_bytes - grams.serialized_size())
            .map_err(io::Error::other)?;
        grams.bind_lexicon(lexicon)?;
    }
    bytes = lexicon.serialized_size().map_err(io::Error::other)? + grams.serialized_size();
    Ok(ModelPruning {
        removed_words: words_before - lexicon.len(),
        removed_grams: grams_before - grams.sizes().iter().sum::<usize>(),
        bytes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use si_lexicon::IndexId;

    fn fixture(surface: bool) -> (Lexicon, GramModel) {
        let mut lexicon = Lexicon::new();
        let mut ids = Vec::new();
        for (text, count) in [
            ("low", 1),
            ("high", 100),
            ("middle", 5),
            ("last", 10),
            ("fifth", 20),
        ] {
            ids.push(
                lexicon
                    .add_reading(IndexId(1), text.as_bytes(), text, count)
                    .unwrap(),
            );
        }
        let mut builder = GramBuilder::new();
        builder.add(&ids[..2], 100).unwrap();
        builder.add(&ids[1..3], 1).unwrap();
        builder.add(&ids[..3], 1).unwrap();
        builder.add(&ids[..4], 1).unwrap();
        builder.add(&ids, 1).unwrap();
        let mut grams = builder.finish().unwrap();
        if surface {
            grams.bind_surface_lexicon(&lexicon).unwrap();
        } else {
            grams.bind_lexicon(&lexicon).unwrap();
        }
        (lexicon, grams)
    }

    #[test]
    fn gram_pruning_prefers_frequency_then_higher_order_and_preserves_words_and_counts() {
        let (mut lexicon, mut grams) = fixture(false);
        let size = lexicon.serialized_size().unwrap() + grams.serialized_size();
        let report = prune_model_to_bytes(&mut lexicon, &mut grams, size - 1).unwrap();
        assert_eq!(report.removed_grams, 1);
        assert_eq!(report.removed_words, 0);
        assert_eq!(grams.sizes(), [2, 1, 1, 0]);
        let low = lexicon.find_word("low").unwrap();
        let high = lexicon.find_word("high").unwrap();
        assert_eq!(grams.count(&[low, high]), Some(100));
        assert_eq!(lexicon.word(high).unwrap().count, 100);
        grams.check_lexicon(&lexicon).unwrap();
    }

    #[test]
    fn every_byte_budget_produces_a_valid_bounded_pair_and_preserves_surface_semantics() {
        let (mut lexicon, grams) = fixture(true);
        let maximum = lexicon.serialized_size().unwrap() + grams.serialized_size();
        let minimum = Lexicon::new().serialized_size().unwrap()
            + GramBuilder::new().finish().unwrap().serialized_size();
        for budget in minimum..=maximum {
            let (mut lexicon, mut grams) = fixture(true);
            let report = prune_model_to_bytes(&mut lexicon, &mut grams, budget).unwrap();
            assert!(report.bytes <= budget);
            assert_eq!(
                report.bytes,
                lexicon.serialized_size().unwrap() + grams.serialized_size()
            );
            grams.check_lexicon(&lexicon).unwrap();
            assert!(grams.uses_surface_tokens());
            if report.removed_words != 0 {
                assert_eq!(grams.sizes(), [0; 4]);
                if !lexicon.is_empty() {
                    assert_eq!(
                        lexicon
                            .word(lexicon.find_word("high").unwrap())
                            .unwrap()
                            .count,
                        100
                    );
                }
            }
        }
    }

    #[test]
    fn mismatched_pairs_and_impossible_caps_are_rejected_before_deletion() {
        let (mut lexicon, mut grams) = fixture(false);
        let size = lexicon.serialized_size().unwrap() + grams.serialized_size();
        assert!(prune_model_to_bytes(&mut lexicon, &mut grams, 0).is_err());
        assert_eq!(
            lexicon.serialized_size().unwrap() + grams.serialized_size(),
            size
        );
        let mut wrong = Lexicon::new();
        for word in ["one", "two", "three", "four", "five"] {
            wrong.add_word(word, 1).unwrap();
        }
        assert!(prune_model_to_bytes(&mut wrong, &mut grams, size).is_err());
        assert_eq!(grams.sizes(), [2, 1, 1, 1]);
        assert_eq!(wrong.len(), 5);
    }
}
