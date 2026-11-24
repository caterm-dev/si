use std::borrow::Cow;
use std::collections::HashSet;
use std::sync::LazyLock;

use pinyin_pro::data::DICT1_ENTRIES;
use pinyin_pro::options::SurnameMode;
use pinyin_pro::pinyin::get_pinyin;
use pinyin_pro::pinyin_utils::strip_tone;

/// Whether a whole ASCII letter run can be segmented into complete Pinyin syllables.
/// This is a spelling check, without abbreviations, completion or typo correction.
pub(crate) fn is_full_spelling(text: &str) -> bool {
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_alphabetic()) {
        return false;
    }
    // Reuse the pinned reading dictionary independently of base lexicon coverage.
    // Initialization happens during ingestion, outside the keystroke path.
    static SYLLABLES: LazyLock<(HashSet<String>, usize)> = LazyLock::new(|| {
        let syllables: HashSet<_> = DICT1_ENTRIES
            .iter()
            .flat_map(|(_, readings)| readings.split_whitespace())
            .map(|reading| canonical_syllable(&strip_tone(reading)).into_owned())
            .filter(|reading| {
                !reading.is_empty() && reading.bytes().all(|byte| byte.is_ascii_lowercase())
            })
            .collect();
        let longest = syllables.iter().map(String::len).max().unwrap_or(0);
        (syllables, longest)
    });
    let (syllables, longest) = &*SYLLABLES;
    let spelling = text.to_ascii_lowercase();
    let mut reachable = vec![false; spelling.len() + 1];
    reachable[0] = true;
    for end in 1..=spelling.len() {
        reachable[end] = (end.saturating_sub(*longest)..end).any(|start| {
            reachable[start]
                && syllables.contains(canonical_syllable(&spelling[start..end]).as_ref())
        });
    }
    reachable[spelling.len()]
}

/// Return the normalized syllables aligned to the original characters.
fn read_syllables(text: &str) -> Option<Vec<Option<String>>> {
    let characters: Vec<_> = text.chars().collect();
    let (pinyin, _) = get_pinyin(&characters, SurnameMode::Off, false);
    if pinyin.len() != characters.len() {
        return None;
    }
    pinyin
        .into_iter()
        .zip(characters)
        .map(|(item, character)| {
            if !item.origin.chars().eq(std::iter::once(character)) {
                return None;
            }
            let syllable = item
                .is_zh
                .then(|| canonical_syllable(&strip_tone(&item.result)).into_owned())
                .filter(|syllable| {
                    !syllable.is_empty() && syllable.bytes().all(|byte| byte.is_ascii_lowercase())
                });
            Some(syllable)
        })
        .collect()
}

/// Read a complete word as one Pinyin context and build its full lookup key.
pub(crate) fn word_reading(text: &str) -> Option<String> {
    let mut key = String::new();
    for syllable in read_syllables(text)? {
        if !key.is_empty() {
            key.push('\'');
        }
        key.push_str(&syllable?);
    }
    (!key.is_empty()).then_some(key)
}

pub(crate) fn canonical_syllable(syllable: &str) -> Cow<'_, str> {
    let normalized = if syllable.contains('ü') || syllable.contains("u:") {
        Cow::Owned(syllable.replace("u:", "v").replace('ü', "v"))
    } else {
        Cow::Borrowed(syllable)
    };
    // Match the Pinyin aliases already used by SI's Chinese syllable parser.
    match normalized.as_ref() {
        "lue" => Cow::Borrowed("lve"),
        "nue" => Cow::Borrowed("nve"),
        "jv" => Cow::Borrowed("ju"),
        "jve" => Cow::Borrowed("jue"),
        "qv" => Cow::Borrowed("qu"),
        "qve" => Cow::Borrowed("que"),
        "xv" => Cow::Borrowed("xu"),
        "xve" => Cow::Borrowed("xue"),
        "yv" => Cow::Borrowed("yu"),
        "yve" => Cow::Borrowed("yue"),
        _ => normalized,
    }
}

#[cfg(test)]
mod tests {
    use super::is_full_spelling;

    #[test]
    fn full_spelling_requires_complete_syllables_across_the_entire_run() {
        for spelling in [
            "wobuzhidao",
            "WOBUZHIDAO",
            "nihao",
            "an",
            "he",
            "woman",
            "banana",
            "langui",
            "lvse",
            "lve",
            "jv",
        ] {
            assert!(is_full_spelling(spelling), "{spelling}");
        }
        for spelling in [
            "",
            "hello",
            "cloud",
            "wobuzhidaox",
            "zh",
            "nh",
            "ni3hao3",
            "ni hao",
            "ni'hao",
            "你好",
        ] {
            assert!(!is_full_spelling(spelling), "{spelling}");
        }
    }
}
