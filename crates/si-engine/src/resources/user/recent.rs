use std::fs;
use std::io::{self, BufWriter, Write};
use std::path::Path;

use super::snapshot::private_file;

const FILE: &str = "recent-samples-v1";
const LIMIT: usize = 10;

pub(super) fn append(samples: &mut Vec<String>, fields: &[&str]) {
    let latest: Vec<_> = fields
        .iter()
        .rev()
        .copied()
        .filter(|field| !field.trim().is_empty())
        .take(LIMIT)
        .collect();
    let discarded = (samples.len() + latest.len()).saturating_sub(LIMIT);
    samples.drain(..discarded);
    samples.extend(latest.into_iter().rev().map(str::to_owned));
}

pub(super) fn read(directory: &Path) -> io::Result<Vec<String>> {
    let file = match fs::read(directory.join(FILE)) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut remaining = file.as_slice();
    let mut samples = Vec::new();
    while !remaining.is_empty() {
        let Some((length, rest)) = remaining.split_first_chunk::<8>() else {
            return Err(invalid());
        };
        let length = usize::try_from(u64::from_le_bytes(*length)).map_err(|_| invalid())?;
        if samples.len() == LIMIT || length == 0 || length > rest.len() {
            return Err(invalid());
        }
        let (sample, rest) = rest.split_at(length);
        samples.push(
            std::str::from_utf8(sample)
                .map_err(|_| invalid())?
                .to_owned(),
        );
        remaining = rest;
    }
    Ok(samples)
}

pub(super) fn save(directory: &Path, samples: &[String]) -> io::Result<()> {
    if samples.is_empty() {
        return Ok(());
    }
    // Lengths delimit exact UTF-8 captures, including multiline and embedded NUL text.
    let mut output = BufWriter::new(private_file(&directory.join(FILE))?);
    for sample in samples {
        output.write_all(&(sample.len() as u64).to_le_bytes())?;
        output.write_all(sample.as_bytes())?;
    }
    output.flush()?;
    output.get_ref().sync_all()
}

fn invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "invalid recent sentence samples",
    )
}
