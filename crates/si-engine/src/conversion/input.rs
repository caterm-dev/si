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

    pub(super) fn source_span(&self, start: usize, end: usize) -> &'a str {
        &self.source[self.ends[start]..self.ends[end]]
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
}

pub(super) fn english_key_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-')
}
