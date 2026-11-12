use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::num::NonZeroU64;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::{GramModel, Table};

const MAGIC: &[u8; 8] = b"SIGRAM\x03\0";
const SURFACE_MAGIC: &[u8; 8] = b"SIGRAM\x03\x01";
const MAGIC_V2: &[u8; 8] = b"SIGRAM\x02\0";
const MAGIC_V1: &[u8; 8] = b"SIGRAM\x01\0";
const HEADER_BYTES: u64 = 28;
static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

pub(crate) fn open(path: &Path) -> io::Result<GramModel> {
    let file = File::open(path)?;
    let size = file.metadata()?.len();
    let mut reader = BufReader::new(file);
    if size < HEADER_BYTES {
        return Err(invalid("unsupported gram file header"));
    }
    let magic = read_array(&mut reader)?;
    let word_order = match &magic {
        MAGIC | SURFACE_MAGIC | MAGIC_V2 => {
            NonZeroU64::new(u64::from_le_bytes(read_array(&mut reader)?))
        }
        MAGIC_V1 => {
            // Version 1 stored a caller-assigned dictionary number here.
            let _: [u8; 8] = read_array(&mut reader)?;
            None
        }
        _ => return Err(invalid("unsupported gram file header")),
    };
    let two = u32::from_le_bytes(read_array(&mut reader)?);
    let three = u32::from_le_bytes(read_array(&mut reader)?);
    let four = u32::from_le_bytes(read_array(&mut reader)?);
    let expected =
        HEADER_BYTES + 16 * u64::from(two) + 20 * u64::from(three) + 24 * u64::from(four);
    if size != expected {
        return Err(invalid("gram row counts do not match file size"));
    }

    Ok(GramModel {
        word_order,
        legacy_word_order: &magic == MAGIC_V2,
        surface_tokens: &magic == SURFACE_MAGIC,
        bigrams: read_table(&mut reader, two as usize)?,
        trigrams: read_table(&mut reader, three as usize)?,
        fourgrams: read_table(&mut reader, four as usize)?,
    })
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

pub(crate) fn save(model: &GramModel, path: &Path) -> io::Result<()> {
    let (temporary, file) = create_temporary(path)?;
    let result = (|| {
        let mut writer = BufWriter::new(file);
        let magic = match (model.surface_tokens, model.legacy_word_order) {
            (true, _) => SURFACE_MAGIC,
            (_, true) => MAGIC_V2,
            _ => MAGIC,
        };
        writer.write_all(magic)?;
        let word_order = model.word_order.map_or(0, NonZeroU64::get);
        writer.write_all(&word_order.to_le_bytes())?;
        for len in model.sizes() {
            writer.write_all(&(len as u32).to_le_bytes())?;
        }
        write_table(&mut writer, &model.bigrams)?;
        write_table(&mut writer, &model.trigrams)?;
        write_table(&mut writer, &model.fourgrams)?;
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
