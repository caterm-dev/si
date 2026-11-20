use si_lexicon::{IndexId, Lexicon};
use unicode_segmentation::UnicodeSegmentation;

use super::Language;

pub(super) struct Input<'a> {
    source: &'a str,
    spellings: [Vec<u8>; 2],
    ends: Vec<usize>,
    separators: Vec<usize>,
}

impl<'a> Input<'a> {
    pub(super) fn new(source: &'a str) -> Self {
        let mut input = Self {
            source,
            spellings: Default::default(),
            ends: vec![0],
            separators: Vec::new(),
        };
        let mut clusters = source.grapheme_indices(true).peekable();
        while let Some((offset, cluster)) = clusters.next() {
            let end = offset + cluster.len();
            let pinyin = &input.spellings[Language::Chinese as usize];
            if cluster == "'"
                && pinyin.last().is_some_and(u8::is_ascii_lowercase)
                && input.separators.last() != Some(&pinyin.len())
            {
                input.separators.push(pinyin.len());
                *input.ends.last_mut().unwrap() = end;
                continue;
            }
            if matches!(cluster, "ü" | "Ü" | "u\u{0308}" | "U\u{0308}") {
                input.push(b'v', 0, end);
                continue;
            }
            let [byte] = cluster.as_bytes() else {
                input.push(0, 0, end);
                continue;
            };
            let lower = byte.to_ascii_lowercase();
            if lower == b'u' && clusters.peek().is_some_and(|&(_, next)| next == ":") {
                let (offset, colon) = clusters.next().unwrap();
                input.push(b'v', 0, offset + colon.len());
                continue;
            }
            let pinyin = if lower.is_ascii_lowercase() { lower } else { 0 };
            let english = if english_key_byte(lower) { lower } else { 0 };
            input.push(pinyin, english, end);
        }
        // j/q/x/y always begin a syllable, and their written umlaut is u.
        let pinyin = &mut input.spellings[Language::Chinese as usize];
        for offset in 1..pinyin.len() {
            if input.separators.binary_search(&offset).is_ok() {
                continue;
            }
            if pinyin[offset] == b'v' && matches!(pinyin[offset - 1], b'j' | b'q' | b'x' | b'y') {
                pinyin[offset] = b'u';
            }
        }
        input
    }

    fn push(&mut self, pinyin: u8, english: u8, end: usize) {
        self.spellings[Language::Chinese as usize].push(pinyin);
        self.spellings[Language::English as usize].push(english);
        self.ends.push(end);
    }

    pub(super) fn spelling(&self, language: Language) -> &[u8] {
        &self.spellings[language as usize]
    }

    pub(super) fn len(&self) -> usize {
        self.ends.len() - 1
    }

    pub(super) fn source_end(&self, position: usize) -> usize {
        self.ends[position]
    }

    pub(super) fn position(&self, source_bytes: usize) -> Option<usize> {
        self.ends.binary_search(&source_bytes).ok()
    }

    pub(super) fn source_span(&self, start: usize, end: usize) -> &'a str {
        &self.source[self.ends[start]..self.ends[end]]
    }

    pub(super) fn single_letter_key(&self, position: usize) -> Option<u8> {
        match self.source_span(position, position + 1).as_bytes() {
            [key @ b'a'..=b'z'] | [key @ b'a'..=b'z', b'\''] => Some(*key),
            _ => None,
        }
    }

    pub(super) fn separators(
        &self,
        start: usize,
        end: usize,
    ) -> impl Iterator<Item = usize> + Clone + '_ {
        let first = self
            .separators
            .partition_point(|&position| position <= start);
        self.separators[first..]
            .iter()
            .copied()
            .take_while(move |&position| position <= end)
            .map(move |position| position - start)
    }

    pub(super) fn pinyin_paths(&self, lexicon: &Lexicon) -> Vec<String> {
        const MAX_PATHS: usize = 3;
        const MAX_SYLLABLE_BYTES: usize = 6;
        let spelling = self.spelling(Language::Chinese);
        let end = spelling.len();
        if !spelling.iter().all(u8::is_ascii_lowercase) {
            return Vec::new();
        }
        // Keep the three best suffixes at each boundary. Prefer fewer syllables
        // and break ties by the longest earlier syllable.
        let mut suffixes = vec![Vec::<Vec<usize>>::new(); end + 1];
        suffixes[end].push(Vec::new());
        for start in (0..end).rev() {
            let boundary = start + self.separators(start, end).next().unwrap_or(end - start);
            let mut paths = Vec::new();
            for next in (start + 1..=boundary.min(start + MAX_SYLLABLE_BYTES)).rev() {
                if suffixes[next].is_empty()
                    || lexicon
                        .exact(IndexId(0), &spelling[start..next])
                        .next()
                        .is_none()
                {
                    continue;
                }
                paths.extend(suffixes[next].iter().map(|rest| {
                    std::iter::once(next)
                        .chain(rest.iter().copied())
                        .collect::<Vec<_>>()
                }));
            }
            paths.sort_by(|a, b| a.len().cmp(&b.len()).then_with(|| b.cmp(a)));
            paths.truncate(MAX_PATHS);
            suffixes[start] = paths;
        }
        let spelling = std::str::from_utf8(spelling).expect("validated ASCII spelling");
        suffixes[0]
            .iter()
            .map(|path| {
                let mut start = 0;
                path.iter()
                    .map(|&next| {
                        let syllable = &spelling[start..next];
                        start = next;
                        syllable
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .collect()
    }
}

pub(super) fn english_key_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-')
}
