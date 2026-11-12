use std::borrow::Cow;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader};
use std::path::Path;

use si_gram::GramBuilder;
use si_lexicon::{IndexId, Lexicon, WordId};

use super::LexiconSource;
use super::paragraph_review;
use super::progress::{ProgressCounts, ProgressReporter};
use crate::han;

pub(super) fn read_lexicon(input: &LexiconSource, lexicon: &mut Lexicon) -> io::Result<usize> {
    if !input.path.is_dir() {
        return read_lexicon_csv(&input.path, input.index, lexicon);
    }
    let mut files = Vec::new();
    for entry in fs::read_dir(&input.path)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().is_some_and(|extension| extension == "csv")
            && entry.file_type()?.is_file()
        {
            files.push(path);
        }
    }
    if files.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{}: no CSV files found", input.path.display()),
        ));
    }
    files.sort_unstable();
    let mut rows = 0;
    for path in files {
        rows += read_lexicon_csv(&path, input.index, lexicon)?;
    }
    Ok(rows)
}

fn read_lexicon_csv(path: &Path, index: IndexId, lexicon: &mut Lexicon) -> io::Result<usize> {
    let mut reader = open_source(path)?;
    let mut buffer = String::new();
    let mut line = 0;
    read_csv_record(&mut reader, path, &mut line, &mut buffer)?;
    let header = strip_bom(without_line_ending(&buffer));
    let is_review = csv_fields::<7>(header).is_some_and(|fields| {
        fields
            .iter()
            .map(|field| field.as_ref())
            .eq(paragraph_review::HEADER.split(','))
    });
    if !is_review
        && !csv_fields(header).is_some_and(|[text, reading, weight]| {
            text == "text" && reading == "reading" && weight == "weight"
        })
    {
        return Err(bad_line(
            path,
            1,
            "expected text,reading,weight or an ingest review CSV with a final reading column",
        ));
    }

    let mut rows = 0;
    while let Some(start) = read_csv_record(&mut reader, path, &mut line, &mut buffer)? {
        let row = without_line_ending(&buffer);
        let (text, key, count) = if is_review {
            let [_, text, count, _, _, _, key] = csv_fields(row)
                .ok_or_else(|| bad_line(path, start, "expected seven valid review CSV fields"))?;
            if key.trim().is_empty() {
                continue;
            }
            (text, key, count)
        } else {
            let [text, key, count] = csv_fields(row)
                .ok_or_else(|| bad_line(path, start, "expected three valid CSV fields"))?;
            (text, key, count)
        };
        let key = if is_review { key.trim() } else { key.as_ref() };
        if text.trim().is_empty() || text.chars().any(char::is_control) {
            return Err(bad_line(path, start, "invalid word text"));
        }
        if key.trim().is_empty() {
            return Err(bad_line(path, start, "missing reading"));
        }
        if key.chars().any(char::is_control) {
            return Err(bad_line(path, start, "invalid reading"));
        }
        let count =
            parse_count(&count).ok_or_else(|| bad_line(path, start, "invalid raw count"))?;
        lexicon
            .add_reading(index, key.as_bytes(), &text, count)
            .map_err(|error| bad_line(path, start, error))?;
        rows += 1;
    }
    Ok(rows)
}

pub(super) enum CorpusLookup<'a> {
    Words(&'a Lexicon),
    Han(HashMap<char, WordId>),
}

pub(super) fn han_lexicon(lexicon: &Lexicon) -> io::Result<Lexicon> {
    // Use one surface token per character for discovery. These IDs never
    // identify a pronunciation in the dictionary.
    let mut characters = Lexicon::new();
    for word in lexicon
        .words()
        .filter(|word| han::single(word.text).is_some())
    {
        characters
            .add_word(word.text, 0)
            .map_err(io::Error::other)?;
    }
    Ok(characters)
}

impl CorpusLookup<'_> {
    pub(super) fn han(lexicon: &Lexicon) -> Self {
        Self::Han(
            lexicon
                .words()
                .filter_map(|word| Some((han::single(word.text)?, word.id)))
                .collect(),
        )
    }
}

pub(super) fn read_corpus(
    path: &Path,
    lookup: &CorpusLookup<'_>,
    builder: &mut GramBuilder,
    counts: &mut ProgressCounts,
    progress: &mut ProgressReporter<'_>,
) -> io::Result<()> {
    let mut segment = Vec::new();
    read_corpus_lines(path, progress, *counts, |_, text| {
        match lookup {
            CorpusLookup::Words(lexicon) => {
                let tokens = text
                    .split_whitespace()
                    .map(|word| resolve_word(lexicon, word));
                observe_tokens(tokens, builder, &mut segment, counts)
            }
            CorpusLookup::Han(words) => {
                let tokens = text.chars().map(|character| {
                    Ok(if let Some(&id) = words.get(&character) {
                        Token::Word(id)
                    } else if han::is_han(character) {
                        Token::Unknown
                    } else {
                        Token::Boundary
                    })
                });
                observe_tokens(tokens, builder, &mut segment, counts)
            }
        }?;
        counts.records += 1;
        Ok(*counts)
    })
}

pub(super) fn read_corpus_lines(
    path: &Path,
    progress: &mut ProgressReporter<'_>,
    mut counts: ProgressCounts,
    mut observe: impl FnMut(usize, &str) -> io::Result<ProgressCounts>,
) -> io::Result<()> {
    let mut reader = open_source(path)?;
    let total = reader
        .get_ref()
        .metadata()
        .ok()
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len());
    progress.start_file(total, counts);
    let mut buffer = String::new();
    let mut bytes = 0;
    for line in 1.. {
        buffer.clear();
        let read = reader
            .read_line(&mut buffer)
            .map_err(|error| bad_line(path, line, error))?;
        if read == 0 {
            break;
        }
        bytes += read as u64;
        let text = without_line_ending(&buffer);
        let text = if line == 1 { strip_bom(text) } else { text };
        if !text.trim().is_empty() {
            counts = observe(line, text).map_err(|error| bad_line(path, line, error))?;
        }
        progress.after_line(line, bytes, counts);
    }
    progress.finish_file(bytes, counts);
    Ok(())
}

enum Token {
    Word(WordId),
    Unknown,
    Boundary,
}

fn resolve_word(lexicon: &Lexicon, token: &str) -> io::Result<Token> {
    let mut entries = lexicon.words_for_text(token);
    if let Some(word) = entries.next() {
        if entries.next().is_some() {
            return Err(invalid_token(
                "ambiguous corpus token; specify text|index|reading",
            ));
        }
        if word.reading.is_none() {
            return Err(invalid_token("corpus token has no resolved reading"));
        }
        return Ok(Token::Word(word.id));
    }
    if let Some((head, reading)) = token.rsplit_once('|')
        && let Some((text, index)) = head.rsplit_once('|')
    {
        if reading.is_empty() {
            return Err(invalid_token("missing corpus token reading"));
        }
        let index = index
            .parse()
            .map_err(|_| invalid_token("invalid corpus lookup index"))?;
        let id = lexicon
            .find_reading(IndexId(index), reading.as_bytes(), text)
            .ok_or_else(|| invalid_token("corpus token reading is absent from the lexicon"))?;
        return Ok(Token::Word(id));
    }
    Ok(Token::Unknown)
}

fn invalid_token(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn observe_tokens(
    tokens: impl Iterator<Item = io::Result<Token>>,
    builder: &mut GramBuilder,
    segment: &mut Vec<WordId>,
    counts: &mut ProgressCounts,
) -> io::Result<()> {
    for token in tokens.chain(std::iter::once(Ok(Token::Boundary))) {
        let token = token?;
        match token {
            Token::Word(id) => segment.push(id),
            Token::Unknown | Token::Boundary => {
                if matches!(token, Token::Unknown) {
                    counts.unknown_tokens += 1;
                }
                if !segment.is_empty() {
                    builder.observe(segment).map_err(io::Error::other)?;
                    counts.matched_tokens += segment.len();
                    segment.clear();
                }
            }
        }
    }
    Ok(())
}

pub(super) fn open_source(path: &Path) -> io::Result<BufReader<File>> {
    File::open(path)
        .map(BufReader::new)
        .map_err(|error| io::Error::new(error.kind(), format!("{}: {error}", path.display())))
}

pub(super) fn bad_line(path: &Path, line: usize, error: impl std::fmt::Display) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{}:{line}: {error}", path.display()),
    )
}

pub(super) fn without_line_ending(line: &str) -> &str {
    let Some(line) = line.strip_suffix('\n') else {
        return line;
    };
    line.strip_suffix('\r').unwrap_or(line)
}

pub(super) fn strip_bom(text: &str) -> &str {
    text.strip_prefix('\u{feff}').unwrap_or(text)
}

pub(super) fn parse_count(count: &str) -> Option<u64> {
    count
        .bytes()
        .all(|byte| byte.is_ascii_digit())
        .then(|| count.parse().ok())
        .flatten()
}

pub(super) fn read_csv_record(
    reader: &mut impl BufRead,
    source: &Path,
    line: &mut usize,
    record: &mut String,
) -> io::Result<Option<usize>> {
    record.clear();
    let start = *line + 1;
    let mut quoted = false;
    loop {
        let offset = record.len();
        if reader
            .read_line(record)
            .map_err(|error| bad_line(source, *line + 1, error))?
            == 0
        {
            if quoted {
                return Err(bad_line(source, start, "unterminated quoted CSV field"));
            }
            return Ok(None);
        }
        *line += 1;
        // Escaped quote pairs have no effect on whether the record spans lines.
        let quotes = record.as_bytes()[offset..]
            .iter()
            .filter(|&&byte| byte == b'"')
            .count();
        quoted ^= !quotes.is_multiple_of(2);
        if !quoted {
            return Ok(Some(start));
        }
    }
}

pub(super) fn csv_fields<const N: usize>(row: &str) -> Option<[Cow<'_, str>; N]> {
    let mut fields = [const { Cow::Borrowed("") }; N];
    let mut remaining = Some(row);
    for field in &mut fields {
        (*field, remaining) = csv_field(remaining?)?;
    }
    remaining.is_none().then_some(fields)
}

fn csv_field(row: &str) -> Option<(Cow<'_, str>, Option<&str>)> {
    let Some(quoted) = row.strip_prefix('"') else {
        let (field, remaining) = row
            .split_once(',')
            .map_or((row, None), |(field, rest)| (field, Some(rest)));
        return (!field.contains('"')).then_some((Cow::Borrowed(field), remaining));
    };
    let mut cursor = 0;
    let mut escaped = false;
    loop {
        let quote = cursor + quoted[cursor..].find('"')?;
        let tail = &quoted[quote + 1..];
        if tail.starts_with('"') {
            escaped = true;
            cursor = quote + 2;
            continue;
        }
        let remaining = if tail.is_empty() {
            None
        } else {
            Some(tail.strip_prefix(',')?)
        };
        let field = &quoted[..quote];
        let value = if escaped {
            Cow::Owned(field.replace("\"\"", "\""))
        } else {
            Cow::Borrowed(field)
        };
        return Some((value, remaining));
    }
}
