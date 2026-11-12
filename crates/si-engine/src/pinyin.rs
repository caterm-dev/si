use std::borrow::Cow;

use pinyin_pro::options::SurnameMode;
use pinyin_pro::pinyin::get_pinyin;
use pinyin_pro::pinyin_utils::strip_tone;

/// Return the normalized syllables aligned to the original characters.
/// A missing syllable remains unresolved so callers can select their own span.
pub(crate) fn read_syllables(text: &str) -> Option<Vec<Option<String>>> {
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
