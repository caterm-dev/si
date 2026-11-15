use si_lexicon::{IndexId, Lexicon, Word};

use super::scoring::{History, Scoring};
use super::{Language, WordIds};
use crate::segmentation::{SegmentKind, Segmenter};

pub(super) struct Context<'a> {
    segmenter: Segmenter<'a>,
    base: &'a Lexicon,
    user: Option<&'a Lexicon>,
}

impl<'a> Context<'a> {
    pub(super) fn new(base: &'a Lexicon, user: Option<&'a Lexicon>) -> Self {
        let segmenter = user.map_or_else(
            || Segmenter::new(base),
            |user| Segmenter::with_user(base, user),
        );
        Self {
            segmenter,
            base,
            user,
        }
    }

    pub(super) fn history(&self, preceding_text: &str, scoring: &Scoring<'_>) -> History {
        let sentence = last_sentence(preceding_text);
        let mut history = History::default();
        for segment in self.segmenter.segment(sentence) {
            let (word, from_user) = match segment.kind {
                SegmentKind::Word(id) => (self.base.word(id), false),
                SegmentKind::UserWord(id) => (self.user.and_then(|user| user.word(id)), true),
                SegmentKind::Letter | SegmentKind::NewEnglishWord => {
                    self.english_word(&sentence[segment.range])
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
                            user: self.user.and_then(paired),
                        }
                    };
                    Some(scoring.extend_history(history, language, ids))
                })
                .unwrap_or_default();
        }
        history
    }

    fn english_word(&self, surface: &str) -> (Option<Word<'_>>, bool) {
        let lower = surface.to_ascii_lowercase();
        let find = |lexicon: &'a Lexicon| {
            lexicon
                .find_reading(IndexId(1), lower.as_bytes(), &lower)
                .and_then(|id| lexicon.word(id))
        };
        match find(self.base) {
            Some(word) => (Some(word), false),
            None => (self.user.and_then(find), true),
        }
    }
}

fn last_sentence(text: &str) -> &str {
    fn terminates(character: char) -> bool {
        matches!(
            character,
            '.' | '?' | '!' | '。' | '？' | '！' | '…' | '\r' | '\n' | '\u{2028}' | '\u{2029}'
        )
    }
    let text = text.trim_end_matches(|character: char| {
        character.is_whitespace()
            || terminates(character)
            || matches!(
                character,
                '"' | '\''
                    | '”'
                    | '’'
                    | '」'
                    | '』'
                    | ')'
                    | '）'
                    | '】'
                    | '》'
                    | ','
                    | '，'
                    | '、'
                    | ':'
                    | '：'
                    | ';'
                    | '；'
            )
    });
    for (index, character) in text.char_indices().rev() {
        if !terminates(character) {
            continue;
        }
        // Keep a period inside a word or decimal, such as `Node.js` or `3.14`.
        if character == '.'
            && index > 0
            && text.as_bytes()[index - 1].is_ascii_alphanumeric()
            && text
                .as_bytes()
                .get(index + 1)
                .is_some_and(u8::is_ascii_alphanumeric)
        {
            continue;
        }
        return &text[index + character.len_utf8()..];
    }
    text
}
