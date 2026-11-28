use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::num::NonZeroU64;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::{BigramModel, GramModel, GramSizes, MAX_ORDER, Table};

const MAGIC_V4: &[u8; 8] = b"SIGRAM\x04\0";
const SURFACE_MAGIC_V4: &[u8; 8] = b"SIGRAM\x04\x01";
const MAGIC_V3: &[u8; 8] = b"SIGRAM\x03\0";
const SURFACE_MAGIC_V3: &[u8; 8] = b"SIGRAM\x03\x01";
const MAGIC_V2: &[u8; 8] = b"SIGRAM\x02\0";
const MAGIC_V1: &[u8; 8] = b"SIGRAM\x01\0";
const PREFIX_BYTES: u64 = 16;
const LEGACY_MAX_ORDER: usize = 4;
static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

pub(crate) fn open(path: &Path) -> io::Result<GramModel> {
    let (mut reader, header) = open_header(path)?;
    let [two, three, four, five] = header.sizes;
    Ok(GramModel {
        word_order: header.word_order,
        legacy_word_order: header.legacy_word_order,
        surface_tokens: header.surface_tokens,
        bigrams: read_table(&mut reader, two)?,
        trigrams: read_table(&mut reader, three)?,
        fourgrams: read_table(&mut reader, four)?,
        fivegrams: read_table(&mut reader, five)?,
    })
}

pub(crate) fn open_bigrams(path: &Path) -> io::Result<BigramModel> {
    let (mut reader, header) = open_header(path)?;
    Ok(BigramModel {
        word_order: header.word_order,
        legacy_word_order: header.legacy_word_order,
        surface_tokens: header.surface_tokens,
        bigrams: read_table(&mut reader, header.sizes[0])?,
    })
}

struct Header {
    word_order: Option<NonZeroU64>,
    legacy_word_order: bool,
    surface_tokens: bool,
    sizes: GramSizes,
}

fn open_header(path: &Path) -> io::Result<(BufReader<File>, Header)> {
    let file = File::open(path)?;
    let size = file.metadata()?.len();
    let mut reader = BufReader::new(file);
    if size < PREFIX_BYTES {
        return Err(invalid("unsupported gram file header"));
    }
    let magic = read_array(&mut reader)?;
    let word_order = match &magic {
        MAGIC_V3 | SURFACE_MAGIC_V3 | MAGIC_V2 | MAGIC_V4 | SURFACE_MAGIC_V4 => {
            NonZeroU64::new(u64::from_le_bytes(read_array(&mut reader)?))
        }
        MAGIC_V1 => {
            // Version 1 stored a caller-assigned dictionary number here.
            let _: [u8; 8] = read_array(&mut reader)?;
            None
        }
        _ => return Err(invalid("unsupported gram file header")),
    };
    let (header_prefix, highest) = if matches!(&magic, MAGIC_V4 | SURFACE_MAGIC_V4) {
        let highest = u32::from_le_bytes(read_array(&mut reader)?) as usize;
        if !(2..=MAX_ORDER).contains(&highest) {
            return Err(invalid("unsupported gram order"));
        }
        (PREFIX_BYTES + 4, highest)
    } else {
        (PREFIX_BYTES, LEGACY_MAX_ORDER)
    };
    let mut expected = header_prefix + 4 * (highest - 1) as u64;
    if size < expected {
        return Err(invalid("truncated gram header"));
    }
    let mut sizes = GramSizes::default();
    for (order, slot) in (2..=highest).zip(&mut sizes) {
        let len = u32::from_le_bytes(read_array(&mut reader)?);
        *slot = len as usize;
        expected += (4 * order + 8) as u64 * u64::from(len);
    }
    if size != expected {
        return Err(invalid("gram row counts do not match file size"));
    }

    Ok((
        reader,
        Header {
            word_order,
            legacy_word_order: &magic == MAGIC_V2,
            surface_tokens: matches!(&magic, SURFACE_MAGIC_V3 | SURFACE_MAGIC_V4),
            sizes,
        },
    ))
}

fn read_table<const N: usize>(reader: &mut impl Read, len: usize) -> io::Result<Table<N>> {
    let mut keys = Vec::new();
    keys.try_reserve_exact(len).map_err(io::Error::other)?;
    for _ in 0..len {
        let mut key = [0; N];
        for ordinal in &mut key {
            *ordinal = u32::from_le_bytes(read_array(reader)?);
        }
        if keys.last().is_some_and(|previous| *previous >= key) {
            return Err(invalid("gram keys are unsorted or repeated"));
        }
        keys.push(key);
    }

    let mut counts = Vec::new();
    counts.try_reserve_exact(len).map_err(io::Error::other)?;
    for _ in 0..len {
        let count = u64::from_le_bytes(read_array(reader)?);
        if count == 0 {
            return Err(invalid("stored gram counts must be positive"));
        }
        counts.push(count);
    }
    Ok(Table::from_sorted(keys, counts))
}

fn read_array<const N: usize>(reader: &mut impl Read) -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    reader.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn highest_order(sizes: GramSizes) -> usize {
    sizes
        .iter()
        .rposition(|&size| size != 0)
        .map_or(LEGACY_MAX_ORDER, |index| (index + 2).max(LEGACY_MAX_ORDER))
}

pub(super) fn serialized_size(model: &GramModel) -> u64 {
    let sizes = model.sizes();
    let highest = highest_order(sizes);
    PREFIX_BYTES
        + if highest > LEGACY_MAX_ORDER { 4 } else { 0 }
        + 4 * (highest - 1) as u64
        + sizes
            .iter()
            .enumerate()
            .map(|(index, &size)| (4 * (index + 2) + 8) as u64 * size as u64)
            .sum::<u64>()
}

pub(crate) fn save(model: &GramModel, path: &Path) -> io::Result<()> {
    let (temporary, file) = create_temporary(path)?;
    let result = (|| {
        let mut writer = BufWriter::new(file);
        let sizes = model.sizes();
        let highest = highest_order(sizes);
        let extended = highest > LEGACY_MAX_ORDER;
        let magic = match (extended, model.surface_tokens, model.legacy_word_order) {
            (true, true, _) => SURFACE_MAGIC_V4,
            (true, false, _) => MAGIC_V4,
            (false, true, _) => SURFACE_MAGIC_V3,
            (false, false, true) => MAGIC_V2,
            _ => MAGIC_V3,
        };
        writer.write_all(magic)?;
        let word_order = model.word_order.map_or(0, NonZeroU64::get);
        writer.write_all(&word_order.to_le_bytes())?;
        if extended {
            writer.write_all(&(highest as u32).to_le_bytes())?;
        }
        for len in sizes.into_iter().take(highest - 1) {
            writer.write_all(&(len as u32).to_le_bytes())?;
        }
        write_table(&mut writer, &model.bigrams)?;
        write_table(&mut writer, &model.trigrams)?;
        write_table(&mut writer, &model.fourgrams)?;
        write_table(&mut writer, &model.fivegrams)?;
        writer.flush()?;
        writer.get_ref().sync_all()?;
        drop(writer);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

fn write_table<const N: usize>(writer: &mut impl Write, table: &Table<N>) -> io::Result<()> {
    for key in &table.keys {
        for ordinal in key {
            writer.write_all(&ordinal.to_le_bytes())?;
        }
    }
    for count in &table.counts {
        writer.write_all(&count.to_le_bytes())?;
    }
    Ok(())
}

fn create_temporary(path: &Path) -> io::Result<(PathBuf, File)> {
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing gram filename"))?;
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
