use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::index::{KeyIndex, KeyRecord};
use crate::{IndexId, Lexicon, ReadingRecord};

const MAGIC: &[u8; 8] = b"SILEX\0\x03\0";
const MAGIC_V2: &[u8; 8] = b"SILEX\0\x02\0";
const MAGIC_V1: &[u8; 8] = b"SILEX\0\x01\0";
const HEADER_SIZE: u64 = 32;
static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

pub(crate) fn open(path: &Path) -> io::Result<Lexicon> {
    let file = File::open(path)?;
    let size = file.metadata()?.len();
    decode(BufReader::new(file), size)
}

fn decode(mut input: impl Read, size: u64) -> io::Result<Lexicon> {
    if size < 28 {
        return Err(invalid("unsupported dictionary file header"));
    }
    let (header_size, has_readings) = match &read_array(&mut input)? {
        MAGIC if size >= HEADER_SIZE => (HEADER_SIZE, true),
        MAGIC_V2 => (28, false),
        MAGIC_V1 if size >= 36 => {
            // Version 1 included a caller-assigned dictionary number.
            read_u64(&mut input)?;
            (36, false)
        }
        _ => return Err(invalid("unsupported dictionary file header")),
    };
    let word_count = read_u32(&mut input)? as usize;
    let text_size = read_u32(&mut input)? as usize;
    let key_count = read_u32(&mut input)? as usize;
    let key_size = read_u32(&mut input)? as usize;
    let posting_count = read_u32(&mut input)? as usize;
    let reading_size = if has_readings {
        read_u32(&mut input)? as usize
    } else {
        0
    };
    // Word sections contain a u32 end, u64 count and u32 text-order entry per word.
    // Each key record contains three u32 fields. Postings are u32 word ordinals.
    let expected = 16 * word_count as u64
        + text_size as u64
        + 12 * key_count as u64
        + key_size as u64
        + 4 * posting_count as u64
        + if has_readings {
            8 * word_count as u64 + reading_size as u64
        } else {
            0
        };
    if expected != size - header_size {
        return Err(invalid("dictionary sections do not match file size"));
    }

    let ends = read_items(word_count, || read_u32(&mut input))?;
    let counts = read_items(word_count, || read_u64(&mut input))?;
    let text_order = read_items(word_count, || read_u32(&mut input))?;
    let text = String::from_utf8(read_bytes(&mut input, text_size)?)
        .map_err(|_| invalid("invalid UTF-8 word data"))?;
    validate_ends(ends.iter().copied(), text.len())?;
    if ends.iter().any(|&end| !text.is_char_boundary(end as usize)) {
        return Err(invalid("word end is inside a UTF-8 character"));
    }
    if text_order.iter().any(|&id| id as usize >= word_count) {
        return Err(invalid("invalid word text index"));
    }
    let stored_readings = if has_readings {
        let readings = read_items(word_count, || {
            Ok(ReadingRecord {
                index: read_u32(&mut input)?,
                end: read_u32(&mut input)?,
            })
        })?;
        let mut previous = 0;
        for row in &readings {
            if row.end < previous || (row.end == previous && row.index != 0) {
                return Err(invalid("invalid word reading span"));
            }
            previous = row.end;
        }
        if previous as usize != reading_size {
            return Err(invalid("invalid word reading size"));
        }
        Some((readings, read_bytes(&mut input, reading_size)?))
    } else {
        None
    };

    let records = read_items(key_count, || {
        Ok(KeyRecord {
            index: IndexId(read_u32(&mut input)?),
            key_end: read_u32(&mut input)?,
            postings_end: read_u32(&mut input)?,
        })
    })?;
    validate_ends(records.iter().map(|row| row.key_end), key_size)?;
    validate_ends(records.iter().map(|row| row.postings_end), posting_count)?;
    let keys = read_bytes(&mut input, key_size)?;
    let postings = read_items(posting_count, || read_u32(&mut input))?;
    let index = KeyIndex {
        keys,
        records,
        postings,
    };
    let mut previous = None;
    for (key, ids) in index.iter() {
        if previous.is_some_and(|previous| previous >= key)
            || ids.last().is_some_and(|&id| id as usize >= word_count)
            || ids.windows(2).any(|pair| pair[0] >= pair[1])
        {
            return Err(invalid("invalid lookup key index"));
        }
        previous = Some(key);
    }

    let (readings, reading_bytes) = match stored_readings {
        Some(stored) => stored,
        None => legacy_readings(&index, word_count)?,
    };
    let lexicon = Lexicon {
        text,
        ends,
        counts,
        readings,
        reading_bytes,
        text_order,
        index,
        ..Lexicon::new()
    };
    if lexicon
        .text_order
        .windows(2)
        .any(|ids| lexicon.identity(ids[0]) >= lexicon.identity(ids[1]))
    {
        return Err(invalid("invalid word text index"));
    }
    if has_readings {
        let mut matched = vec![false; word_count];
        for ((index, key), ids) in lexicon.index.iter() {
            for &id in ids {
                if lexicon
                    .reading(id)
                    .is_some_and(|reading| reading.index == index && reading.key == key)
                {
                    matched[id as usize] = true;
                }
            }
        }
        if matched
            .iter()
            .enumerate()
            .any(|(i, found)| !found && lexicon.reading(i as u32).is_some())
        {
            return Err(invalid("word reading is missing its lookup key"));
        }
    }
    Ok(lexicon)
}

fn legacy_readings(
    index: &KeyIndex,
    word_count: usize,
) -> io::Result<(Vec<ReadingRecord>, Vec<u8>)> {
    let mut keys = vec![None; word_count];
    for (position, (_, ids)) in index.iter().enumerate() {
        for &id in ids {
            let key = &mut keys[id as usize];
            *key = Some(if key.is_none() { position } else { usize::MAX });
        }
    }
    let mut bytes = Vec::new();
    let mut readings = Vec::with_capacity(word_count);
    for key in keys {
        let mut space = 0;
        if let Some(position) = key.filter(|&i| i != usize::MAX) {
            let (index, key) = index.key(position);
            crate::section_end(bytes.len(), key.len()).map_err(io::Error::other)?;
            bytes.extend_from_slice(key);
            space = index.0;
        }
        readings.push(ReadingRecord {
            index: space,
            end: bytes.len() as u32,
        });
    }
    Ok((readings, bytes))
}

fn validate_ends(ends: impl Iterator<Item = u32>, size: usize) -> io::Result<()> {
    let mut previous = 0;
    for end in ends {
        if end <= previous {
            return Err(invalid("empty or out-of-order dictionary section span"));
        }
        previous = end;
    }
    if previous as usize != size {
        return Err(invalid("dictionary section ends at the wrong offset"));
    }
    Ok(())
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn read_array<const N: usize>(input: &mut impl Read) -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    input.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn read_u32(input: &mut impl Read) -> io::Result<u32> {
    Ok(u32::from_le_bytes(read_array(input)?))
}

fn read_u64(input: &mut impl Read) -> io::Result<u64> {
    Ok(u64::from_le_bytes(read_array(input)?))
}

fn read_items<T>(count: usize, mut read: impl FnMut() -> io::Result<T>) -> io::Result<Vec<T>> {
    let mut items = Vec::new();
    items.try_reserve_exact(count).map_err(io::Error::other)?;
    for _ in 0..count {
        items.push(read()?);
    }
    Ok(items)
}

fn read_bytes(input: &mut impl Read, count: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(count).map_err(io::Error::other)?;
    bytes.resize(count, 0);
    input.read_exact(&mut bytes)?;
    Ok(bytes)
}

pub(crate) fn save(lexicon: &Lexicon, path: &Path) -> io::Result<()> {
    let (temporary, file) = create_temporary(path)?;
    let result = (|| {
        let mut output = BufWriter::new(file);
        encode(lexicon, &mut output)?;
        output.flush()?;
        output.get_ref().sync_all()?;
        drop(output);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

fn create_temporary(path: &Path) -> io::Result<(PathBuf, File)> {
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "missing dictionary filename")
    })?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    loop {
        let sequence = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
        let mut filename = OsString::from(".");
        filename.push(name);
        filename.push(format!(".{}.{sequence}.tmp", std::process::id()));
        let temporary = path.with_file_name(filename);
        match options.open(&temporary) {
            Ok(file) => return Ok((temporary, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
}

fn encode(lexicon: &Lexicon, mut output: impl Write) -> io::Result<()> {
    output.write_all(MAGIC)?;
    for length in [
        lexicon.len(),
        lexicon.text.len(),
        lexicon.index.records.len(),
        lexicon.index.keys.len(),
        lexicon.index.postings.len(),
        lexicon.reading_bytes.len(),
    ] {
        output.write_all(&(length as u32).to_le_bytes())?;
    }
    for end in &lexicon.ends {
        output.write_all(&end.to_le_bytes())?;
    }
    for count in &lexicon.counts {
        output.write_all(&count.to_le_bytes())?;
    }
    for id in &lexicon.text_order {
        output.write_all(&id.to_le_bytes())?;
    }
    output.write_all(lexicon.text.as_bytes())?;
    for reading in &lexicon.readings {
        output.write_all(&reading.index.to_le_bytes())?;
        output.write_all(&reading.end.to_le_bytes())?;
    }
    output.write_all(&lexicon.reading_bytes)?;
    for record in &lexicon.index.records {
        output.write_all(&record.index.0.to_le_bytes())?;
        output.write_all(&record.key_end.to_le_bytes())?;
        output.write_all(&record.postings_end.to_le_bytes())?;
    }
    output.write_all(&lexicon.index.keys)?;
    for id in &lexicon.index.postings {
        output.write_all(&id.to_le_bytes())?;
    }
    Ok(())
}
