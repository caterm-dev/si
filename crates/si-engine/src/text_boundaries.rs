//! Shared written-text boundaries for base ingestion and field context.

pub(crate) const START_TOKEN: &str = "<s>";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Part<'a> {
    Text(&'a str),
    Wrapper,
    SentenceBoundary,
    Gap,
}

fn is_wrapper(character: char) -> bool {
    matches!(
        character,
        '《' | '》'
            | '〈'
            | '〉'
            | '“'
            | '”'
            | '‘'
            | '’'
            | '「'
            | '」'
            | '『'
            | '』'
            | '（'
            | '）'
            | '('
            | ')'
            | '【'
            | '】'
            | '['
            | ']'
            | '"'
            | '\''
    )
}

fn separator(text: &str, offset: usize, character: char) -> Option<Part<'_>> {
    if is_wrapper(character) {
        return Some(Part::Wrapper);
    }
    if matches!(
        character,
        '，' | ','
            | '。'
            | '！'
            | '!'
            | '？'
            | '?'
            | '；'
            | ';'
            | '：'
            | ':'
            | '…'
            | '\r'
            | '\n'
            | '\u{2028}'
            | '\u{2029}'
    ) {
        return Some(Part::SentenceBoundary);
    }
    if character == '.' {
        // Keep ASCII word/number interiors, including domains and decimals.
        let internal = offset > 0
            && text.as_bytes()[offset - 1].is_ascii_alphanumeric()
            && text
                .as_bytes()
                .get(offset + 1)
                .is_some_and(u8::is_ascii_alphanumeric);
        return (!internal).then_some(Part::SentenceBoundary);
    }
    (!character.is_alphanumeric() && !character.is_whitespace()).then_some(Part::Gap)
}

/// Borrow exact source slices. Wrappers split lexical matching without breaking adjacency.
pub(crate) fn parts(text: &str) -> impl Iterator<Item = Part<'_>> {
    let mut characters = text.char_indices();
    let mut start = 0;
    let mut pending = None;
    std::iter::from_fn(move || {
        if let Some(part) = pending.take() {
            return Some(part);
        }
        for (offset, character) in characters.by_ref() {
            if let Some(part) = separator(text, offset, character) {
                let previous = start;
                start = offset + character.len_utf8();
                if previous < offset {
                    pending = Some(part);
                    return Some(Part::Text(&text[previous..offset]));
                }
                return Some(part);
            }
        }
        if start < text.len() {
            let remaining = &text[start..];
            start = text.len();
            Some(Part::Text(remaining))
        } else {
            None
        }
    })
}

pub fn last_fragment(text: &str) -> &str {
    let start = text
        .char_indices()
        .filter_map(|(offset, character)| {
            (separator(text, offset, character) == Some(Part::SentenceBoundary))
                .then_some(offset + character.len_utf8())
        })
        .next_back()
        .unwrap_or_default();
    &text[start..]
}

pub(crate) fn is_fragment_start(text: &str) -> bool {
    text.chars()
        .all(|character| character.is_whitespace() || is_wrapper(character))
}
