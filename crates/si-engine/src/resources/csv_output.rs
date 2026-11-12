use std::fs::{self, File, OpenOptions};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};

pub(super) struct PendingCsv {
    pub(super) writer: BufWriter<File>,
    path: ReadyCsv,
}

impl PendingCsv {
    pub(super) fn new(destination: &Path, header: &[u8]) -> io::Result<Self> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let pid = std::process::id();
        let mut attempt = 1u64;
        loop {
            let path = append_suffix(destination, &format!(".csv-export.{pid}.{attempt}.tmp"));
            match options.open(&path) {
                Ok(file) => {
                    let mut pending = Self {
                        writer: BufWriter::new(file),
                        path: ReadyCsv(path),
                    };
                    pending.writer.write_all(header)?;
                    return Ok(pending);
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => attempt += 1,
                Err(error) => return Err(error),
            }
        }
    }

    pub(super) fn finish(self) -> io::Result<ReadyCsv> {
        let Self { mut writer, path } = self;
        let synced = writer.flush().and_then(|()| writer.get_ref().sync_all());
        drop(writer);
        synced?;
        Ok(path)
    }
}

pub(super) struct ReadyCsv(PathBuf);

impl ReadyCsv {
    /// Publish the complete CSV without replacing an existing path.
    pub(super) fn publish(&self, destination: &Path) -> io::Result<()> {
        fs::hard_link(&self.0, destination)
    }
}

impl Drop for ReadyCsv {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub(super) fn append_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

pub(super) fn write_field(output: &mut impl Write, text: &str) -> io::Result<()> {
    if !text.contains([',', '"', '\r', '\n']) {
        return output.write_all(text.as_bytes());
    }
    output.write_all(b"\"")?;
    let mut fields = text.split('"');
    output.write_all(fields.next().unwrap_or_default().as_bytes())?;
    for part in fields {
        output.write_all(b"\"\"")?;
        output.write_all(part.as_bytes())?;
    }
    output.write_all(b"\"")
}
