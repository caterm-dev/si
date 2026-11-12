use std::collections::BTreeSet;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};

use si_gram::{GramBuilder, GramModel};
use si_lexicon::Lexicon;

use super::super::{lock_destination, open_compatible_grams};

pub(super) const LEXICON: &str = "user.silex";
pub(super) const GRAMS: &str = "user.sigram";
const HAN: &str = "characters.silex";
const HAN_GRAMS: &str = "characters.sigram";
const BATCHES: &str = "batches";

pub(super) struct State {
    pub(super) lexicon: Lexicon,
    pub(super) grams: GramModel,
    pub(super) han: Lexicon,
    pub(super) han_grams: GramModel,
    pub(super) batches: BTreeSet<String>,
}

impl State {
    fn empty() -> Self {
        Self {
            lexicon: Lexicon::new(),
            grams: empty_grams(),
            han: Lexicon::new(),
            han_grams: empty_grams(),
            batches: BTreeSet::new(),
        }
    }

    pub(super) fn take_grams(&mut self) -> (GramBuilder, GramBuilder) {
        (
            std::mem::replace(&mut self.grams, empty_grams()).into_builder(),
            std::mem::replace(&mut self.han_grams, empty_grams()).into_builder(),
        )
    }
}

fn empty_grams() -> GramModel {
    GramBuilder::new().finish().expect("empty gram model")
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Slot {
    First,
    Second,
}

impl Slot {
    fn name(self) -> &'static str {
        match self {
            Self::First => "snapshot-a",
            Self::Second => "snapshot-b",
        }
    }
}

pub(super) struct Profile<'a> {
    directory: &'a Path,
    _lock: File,
}

impl<'a> Profile<'a> {
    pub(super) fn open(directory: &'a Path, create: bool) -> io::Result<Option<Self>> {
        if directory
            .extension()
            .is_none_or(|extension| extension != "si-user")
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "user profile directory must end in .si-user",
            ));
        }
        if create && !directory.exists() {
            match private_directory(directory, true) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
        let metadata = match fs::symlink_metadata(directory) {
            Ok(metadata) => metadata,
            Err(error) if !create && error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        if !metadata.is_dir() {
            return Err(invalid("user profile must be a regular directory"));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if metadata.permissions().mode() & 0o077 != 0 {
                return Err(invalid(
                    "user profile directory must be accessible only by its owner",
                ));
            }
        }
        let lock = lock_destination(&directory.join("profile"), false)?;
        let marker = directory.join("format-v1");
        match fs::symlink_metadata(&marker) {
            Ok(metadata) if metadata.is_file() && metadata.len() == 0 => {}
            Ok(_) => return Err(invalid("invalid user profile format marker")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                for entry in fs::read_dir(directory)? {
                    if entry?.file_name() != "profile.lock" {
                        return Err(invalid("user profile requires a dedicated directory"));
                    }
                }
                if !create {
                    return Ok(None);
                }
                private_file(&marker)?.sync_all()?;
                sync_directory(directory)?;
            }
            Err(error) => return Err(error),
        }
        Ok(Some(Self {
            directory,
            _lock: lock,
        }))
    }

    pub(super) fn active(&self) -> io::Result<Option<Slot>> {
        match fs::read(self.directory.join("current")) {
            Ok(bytes) => match bytes.as_slice() {
                b"a\n" => Ok(Some(Slot::First)),
                b"b\n" => Ok(Some(Slot::Second)),
                b"empty\n" => Ok(None),
                _ => Err(invalid("invalid user profile snapshot pointer")),
            },
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    pub(super) fn slot(&self, slot: Slot) -> PathBuf {
        self.directory.join(slot.name())
    }

    pub(super) fn read(&self, active: Option<Slot>) -> io::Result<State> {
        let Some(active) = active else {
            return Ok(State::empty());
        };
        let directory = self.slot(active);
        let lexicon = Lexicon::open(directory.join(LEXICON))?;
        let grams = open_compatible_grams(&directory.join(GRAMS), &lexicon)?;
        let han = Lexicon::open(directory.join(HAN))?;
        let han_grams = GramModel::open(directory.join(HAN_GRAMS))?;
        if !han_grams.uses_surface_tokens() {
            return Err(invalid("invalid user profile character grams"));
        }
        han_grams.check_lexicon(&han)?;
        let mut batches = BTreeSet::new();
        for id in fs::read_to_string(directory.join(BATCHES))?.lines() {
            if !valid_batch_id(id) || !batches.insert(id.to_owned()) {
                return Err(invalid("invalid user profile batch IDs"));
            }
        }
        Ok(State {
            lexicon,
            grams,
            han,
            han_grams,
            batches,
        })
    }

    pub(super) fn publish(&self, active: Option<Slot>, state: &mut State) -> io::Result<()> {
        let next = match active {
            Some(Slot::First) => Slot::Second,
            _ => Slot::First,
        };
        let directory = self.slot(next);
        private_directory(&directory, false)?;
        state.lexicon.save(directory.join(LEXICON))?;
        state.grams.save(directory.join(GRAMS))?;
        state.han.save(directory.join(HAN))?;
        state.han_grams.save(directory.join(HAN_GRAMS))?;
        let mut batches = BufWriter::new(private_file(&directory.join(BATCHES))?);
        for id in &state.batches {
            writeln!(batches, "{id}")?;
        }
        batches.flush()?;
        batches.get_ref().sync_all()?;
        sync_directory(&directory)?;
        self.publish_pointer(match next {
            Slot::First => b"a\n",
            Slot::Second => b"b\n",
        })?;
        self.clean_inactive(Some(next))
    }

    pub(super) fn clear(&self) -> io::Result<()> {
        self.publish_pointer(b"empty\n")?;
        self.clean_inactive(None)
    }

    fn publish_pointer(&self, contents: &[u8]) -> io::Result<()> {
        let staged = self.directory.join("current.next");
        remove_if_present(&staged, |path| fs::remove_file(path))?;
        let mut file = private_file(&staged)?;
        file.write_all(contents)?;
        file.sync_all()?;
        drop(file);
        fs::rename(staged, self.directory.join("current"))?;
        sync_directory(self.directory)
    }

    pub(super) fn clean_inactive(&self, active: Option<Slot>) -> io::Result<()> {
        // A prior commit may have stopped after renaming the pointer. Make
        // that rename durable before deleting any older generation.
        sync_directory(self.directory)?;
        for slot in [Slot::First, Slot::Second] {
            if active != Some(slot) {
                remove_if_present(&self.slot(slot), |path| fs::remove_dir_all(path))?;
            }
        }
        remove_if_present(&self.directory.join("current.next"), |path| {
            fs::remove_file(path)
        })?;
        sync_directory(self.directory)
    }
}

pub(super) fn valid_batch_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn private_directory(path: &Path, recursive: bool) -> io::Result<()> {
    let mut builder = DirBuilder::new();
    builder.recursive(recursive);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)
}

fn private_file(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn remove_if_present(path: &Path, remove: impl FnOnce(&Path) -> io::Result<()>) -> io::Result<()> {
    match remove(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        result => result,
    }
}

fn sync_directory(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}
