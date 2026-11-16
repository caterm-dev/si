use std::io::{self, Write};
use std::path::Path;

use si_lexicon::{IndexId, Lexicon, Reading, Word, WordId};

use super::LexiconImport;
use super::csv_output::{PendingCsv, write_field};
use super::source::{
    bad_line, csv_fields, open_source, parse_count, read_csv_record, strip_bom, without_line_ending,
};

const HEADER: &str = "kind,id,text,weight,index,reading,key_hex";

pub(super) fn export(
    lexicon: &Lexicon,
    destination: &Path,
    index: Option<IndexId>,
) -> io::Result<usize> {
    let header = format!("{HEADER}\n");
    let mut csv = PendingCsv::new(destination, header.as_bytes())?;
    let output = &mut csv.writer;
    let includes = |word: &Word<'_>| {
        index.is_none_or(|index| word.reading.is_some_and(|reading| reading.index == index))
    };
    let mut words = 0;
    for word in lexicon.words().filter(includes) {
        write!(output, "word,{},", word.id.0)?;
        write_field(output, word.text)?;
        write!(output, ",{},", word.count)?;
        write_reading(output, word.reading)?;
        words += 1;
    }
    for (reading, id) in lexicon.lookup_keys() {
        let word = lexicon.word(id).expect("valid lookup word ID");
        if includes(&word) && word.reading != Some(reading) {
            write!(output, "alias,{},,,", id.0)?;
            write_reading(output, Some(reading))?;
        }
    }
    csv.finish()?.publish(destination)?;
    Ok(words)
}

fn write_reading(output: &mut impl Write, reading: Option<Reading<'_>>) -> io::Result<()> {
    let Some(reading) = reading else {
        return output.write_all(b",,\n");
    };
    write!(output, "{},", reading.index.0)?;
    if let Ok(text) = std::str::from_utf8(reading.key)
        && !text.chars().any(char::is_control)
    {
        write_field(output, text)?;
        return output.write_all(b",\n");
    }

    output.write_all(b",")?;
    for byte in reading.key {
        write!(output, "{byte:02x}")?;
    }
    output.write_all(b"\n")
}

struct Key {
    index: IndexId,
    bytes: Vec<u8>,
}

impl Key {
    fn reading(&self) -> Reading<'_> {
        Reading {
            index: self.index,
            key: &self.bytes,
        }
    }
}

struct WordRow {
    line: usize,
    id: WordId,
    text: String,
    count: u64,
    key: Option<Key>,
}

struct AliasRow {
    line: usize,
    id: WordId,
    key: Key,
}

pub(super) fn restore(source: &Path) -> io::Result<(Lexicon, LexiconImport)> {
    let mut reader = open_source(source)?;
    let mut record = String::new();
    let mut line = 0;
    read_csv_record(&mut reader, source, &mut line, &mut record)?;
    let header = csv_fields::<7>(strip_bom(without_line_ending(&record)));
    if !header.is_some_and(|fields| {
        fields
            .iter()
            .map(|field| field.as_ref())
            .eq(HEADER.split(','))
    }) {
        return Err(bad_line(source, 1, "expected lexicon snapshot CSV header"));
    }

    let mut words = Vec::new();
    let mut aliases = Vec::new();
    while let Some(start) = read_csv_record(&mut reader, source, &mut line, &mut record)? {
        let invalid = |message| bad_line(source, start, message);
        let [kind, id, text, weight, index, reading, hex] =
            csv_fields(without_line_ending(&record))
                .ok_or_else(|| invalid("invalid snapshot row"))?;
        let id = WordId(parse_u32(&id).ok_or_else(|| invalid("invalid word ID"))?);
        let key = parse_key(&index, &reading, &hex).map_err(invalid)?;
        match kind.as_ref() {
            "word" if !text.is_empty() => words.push(WordRow {
                line: start,
                id,
                text: text.into_owned(),
                count: parse_count(&weight).ok_or_else(|| invalid("invalid raw count"))?,
                key,
            }),
            "alias" if text.is_empty() && weight.is_empty() => aliases.push(AliasRow {
                line: start,
                id,
                key: key.ok_or_else(|| invalid("alias requires a lookup key"))?,
            }),
            _ => return Err(invalid("expected a word or alias row")),
        }
    }

    words.sort_unstable_by_key(|row| row.id.0);
    let report = LexiconImport {
        rows: words.len() + aliases.len(),
        words: words.len(),
    };
    let mut lexicon = Lexicon::new();
    for row in words {
        lexicon
            .restore_word(
                row.id,
                &row.text,
                row.count,
                row.key.as_ref().map(Key::reading),
            )
            .map_err(|error| bad_line(source, row.line, error))?;
    }
    for alias in aliases {
        let added = lexicon
            .add_key(alias.key.index, &alias.key.bytes, alias.id)
            .map_err(|error| bad_line(source, alias.line, error))?;
        if !added {
            return Err(bad_line(source, alias.line, "duplicate lookup association"));
        }
    }
    Ok((lexicon, report))
}

fn parse_u32(value: &str) -> Option<u32> {
    u32::try_from(parse_count(value)?).ok()
}

fn parse_key(index: &str, reading: &str, hex: &str) -> Result<Option<Key>, &'static str> {
    if index.is_empty() && reading.is_empty() && hex.is_empty() {
        return Ok(None);
    }
    let index = IndexId(parse_u32(index).ok_or("invalid lookup index")?);
    let bytes = match (reading.is_empty(), hex.is_empty()) {
        (false, true) => reading.as_bytes().to_vec(),
        (true, false) => decode_hex(hex).ok_or("invalid hex lookup key")?,
        _ => return Err("provide exactly one of reading and key_hex"),
    };
    Ok(Some(Key { index, bytes }))
}

fn decode_hex(hex: &str) -> Option<Vec<u8>> {
    if !hex.len().is_multiple_of(2) {
        return None;
    }
    hex.as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let high = char::from(pair[0]).to_digit(16)? as u8;
            let low = char::from(pair[1]).to_digit(16)? as u8;
            Some((high << 4) | low)
        })
        .collect()
}
