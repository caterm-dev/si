//! Storage-only app learning: compare one previous snapshot and append new paragraphs.
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use si_gram::GramBuilder;
use si_lexicon::Lexicon;

use super::super::{AppLearningConfig, lock_destination, open_compatible_grams};
use super::{ingest, snapshot};

const FILES: [&str; 3] = ["app.silex", "app.sigram", "meta-v1.txt"];

/// Only the previous accepted snapshot is retained, independently for each app.
/// Source text is transient; edits append observations and never retract old counts.
pub struct AppLearningSession {
    directory: PathBuf,
    bundle: String,
    previous: Vec<String>,
    revision: u64,
    config: AppLearningConfig,
}

impl AppLearningSession {
    pub fn open(directory: PathBuf, bundle: String) -> io::Result<Self> {
        Self::open_with_config(directory, bundle, AppLearningConfig::default())
    }

    pub fn open_with_config(
        directory: PathBuf,
        bundle: String,
        config: AppLearningConfig,
    ) -> io::Result<Self> {
        if bundle.is_empty()
            || bundle.len() > 255
            || !bundle
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
        {
            return Err(invalid("invalid application identifier"));
        }
        private_directory(&directory)?;
        let _lock = lock_destination(&directory.join("model"), false)?;
        recover(&directory, &bundle, config.max_model_bytes)?;
        migrate_legacy(&directory, &bundle, config.max_model_bytes)?;
        let revision = if directory.join(FILES[2]).exists() {
            read_state(&directory, &bundle, config.max_model_bytes)?;
            let revision = revision_at(&directory, &bundle)?;
            clean_legacy(&directory)?;
            revision
        } else {
            if FILES[..2].iter().any(|name| directory.join(name).exists()) {
                return Err(invalid("incomplete app model"));
            }
            0
        };
        Ok(Self {
            directory,
            bundle,
            previous: Vec::new(),
            revision,
            config,
        })
    }

    pub fn max_snapshot_bytes(&self) -> usize {
        self.config.max_snapshot_bytes
    }

    /// Compare exact paragraph occurrences with the previous snapshot, irrespective of order.
    /// Repetitions in one snapshot are preserved; returning to older unseen-in-last text counts again.
    pub fn observe(&mut self, base: &Lexicon, text: &[&str]) -> io::Result<bool> {
        if text
            .iter()
            .try_fold(0usize, |total, p| total.checked_add(p.len()))
            .is_none_or(|bytes| bytes > self.config.max_snapshot_bytes)
        {
            return Ok(false);
        }
        if text.iter().any(|p| p.is_empty()) {
            return Err(invalid("empty app paragraph"));
        }
        let _lock = lock_destination(&self.directory.join("model"), false)?;
        recover(&self.directory, &self.bundle, self.config.max_model_bytes)?;
        let revision = if self.directory.join(FILES[2]).exists() {
            revision_at(&self.directory, &self.bundle)?
        } else {
            0
        };
        if revision != self.revision {
            return Err(invalid("app model changed externally"));
        }
        let mut remaining = BTreeMap::<&str, usize>::new();
        for paragraph in &self.previous {
            *remaining.entry(paragraph).or_default() += 1;
        }
        let mut added = Vec::new();
        for &paragraph in text {
            match remaining.get_mut(paragraph) {
                Some(count) if *count > 0 => *count -= 1,
                _ => added.push(paragraph),
            }
        }
        if added.is_empty() {
            self.previous = text.iter().map(|p| (*p).to_owned()).collect();
            return Ok(false);
        }
        let mut model = if self.revision == 0 {
            empty_state()
        } else {
            read_state(&self.directory, &self.bundle, self.config.max_model_bytes)?
        };
        ingest::observe(
            &mut model,
            base,
            added.into_iter().map(Ok),
            self.config.max_order,
        )?;
        self.publish(&mut model, text)?;
        Ok(true)
    }

    fn publish(&mut self, model: &mut snapshot::State, text: &[&str]) -> io::Result<()> {
        let staged = self.directory.join(".pending");
        remove_directory(&staged)?;
        private_directory(&staged)?;
        model.lexicon.save(staged.join(FILES[0]))?;
        model.grams.bind_lexicon(&model.lexicon)?;
        model.grams.save(staged.join(FILES[1]))?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_secs();
        let revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| invalid("app revision overflow"))?;
        let mut meta = snapshot::private_file(&staged.join(FILES[2]))?;
        writeln!(
            meta,
            "SI-APP-LEARNING-1\n{}\n{now}\n{revision}\n{}\n{}\n{}",
            self.bundle,
            model.lexicon.len(),
            model.grams.sizes().iter().sum::<usize>(),
            text.len()
        )?;
        meta.sync_all()?;
        if let Err(error) = sync_files(&staged, self.config.max_model_bytes) {
            // An unarmed oversized write must not remain as retained model data.
            let _ = remove_directory(&staged);
            return Err(error);
        }
        // The marker commits a roll-forward transaction. Temporary files are removed on success.
        // Advance memory as soon as the marker exists: a failed rename must not double-count on retry.
        let marker = snapshot::private_file(&self.directory.join(".publishing"))?;
        self.previous = text.iter().map(|p| (*p).to_owned()).collect();
        self.revision = revision;
        marker.sync_all()?;
        sync(&self.directory)?;
        recover(&self.directory, &self.bundle, self.config.max_model_bytes)?;
        clean_legacy(&self.directory)
    }
}

fn empty_state() -> snapshot::State {
    snapshot::State {
        lexicon: Lexicon::new(),
        grams: GramBuilder::new().finish().expect("empty grams"),
        batches: BTreeSet::new(),
    }
}

fn read_state(directory: &Path, bundle: &str, max_bytes: u64) -> io::Result<snapshot::State> {
    if !fs::symlink_metadata(directory)?.is_dir() {
        return Err(invalid("app model requires a regular directory"));
    }
    revision_at(directory, bundle)?;
    let mut bytes = 0;
    for name in FILES {
        let meta = fs::symlink_metadata(directory.join(name))?;
        if !meta.is_file() {
            return Err(invalid("app model requires regular files"));
        }
        bytes = total_bytes(bytes, meta.len())?;
    }
    if bytes > max_bytes {
        return Err(invalid("app model byte capacity reached"));
    }
    let lexicon = Lexicon::open(directory.join(FILES[0]))?;
    let grams = open_compatible_grams(&directory.join(FILES[1]), &lexicon)?;
    Ok(snapshot::State {
        lexicon,
        grams,
        batches: BTreeSet::new(),
    })
}

fn revision_at(directory: &Path, bundle: &str) -> io::Result<u64> {
    let path = directory.join(FILES[2]);
    let info = fs::symlink_metadata(&path)?;
    if !info.is_file() || info.len() > 4096 {
        return Err(invalid("invalid app metadata"));
    }
    let meta = fs::read_to_string(path)?;
    let lines: Vec<_> = meta.lines().collect();
    if lines.len() != 7
        || lines[0] != "SI-APP-LEARNING-1"
        || lines[1] != bundle
        || lines[2..].iter().any(|line| line.parse::<u64>().is_err())
    {
        return Err(invalid("invalid app metadata or identity"));
    }
    lines[3]
        .parse()
        .map_err(|_| invalid("invalid app revision"))
}

/// Call under the app lock. If interrupted, finish publishing the one staged model on next open.
fn recover(directory: &Path, bundle: &str, max_bytes: u64) -> io::Result<()> {
    let marker = directory.join(".publishing");
    let staged = directory.join(".pending");
    if !marker.exists() {
        return remove_directory(&staged);
    }
    let info = fs::symlink_metadata(&marker)?;
    if !info.is_file() || info.len() != 0 {
        return Err(invalid("invalid app publication marker"));
    }
    if !fs::symlink_metadata(&staged)?.is_dir() {
        return Err(invalid("invalid app staging directory"));
    }
    // Validate the complete proposed pair before changing any remaining fixed file.
    let candidate = |name: &str| {
        let path = staged.join(name);
        if path.exists() {
            path
        } else {
            directory.join(name)
        }
    };
    let meta_directory = if staged.join(FILES[2]).exists() {
        &staged
    } else {
        directory
    };
    revision_at(meta_directory, bundle)?;
    let mut bytes = 0;
    for name in FILES {
        let meta = fs::symlink_metadata(candidate(name))?;
        if !meta.is_file() {
            return Err(invalid("invalid staged app file"));
        }
        bytes = total_bytes(bytes, meta.len())?;
    }
    if bytes > max_bytes {
        return Err(invalid("app model byte capacity reached"));
    }
    let lexicon = Lexicon::open(candidate(FILES[0]))?;
    open_compatible_grams(&candidate(FILES[1]), &lexicon)?;
    for name in FILES {
        let source = staged.join(name);
        if source.exists() {
            if !fs::symlink_metadata(&source)?.is_file() {
                return Err(invalid("invalid staged app file"));
            }
            fs::rename(source, directory.join(name))?;
        }
    }
    read_state(directory, bundle, max_bytes)?;
    sync(directory)?;
    fs::remove_file(marker)?;
    sync(directory)?;
    remove_directory(&staged)?;
    sync(directory)
}

fn migrate_legacy(directory: &Path, bundle: &str, max_bytes: u64) -> io::Result<()> {
    let pointer = directory.join("current");
    if !pointer.exists() {
        return Ok(());
    }
    if directory.join(FILES[2]).exists() {
        read_state(directory, bundle, max_bytes)?;
        return clean_legacy(directory);
    }
    let slot = fs::read_to_string(&pointer)?;
    if !["snapshot-a\n", "snapshot-b\n"].contains(&slot.as_str()) {
        return Err(invalid("invalid legacy app pointer"));
    }
    let source = directory.join(slot.trim());
    read_state(&source, bundle, max_bytes)?;
    let staged = directory.join(".pending");
    private_directory(&staged)?;
    for name in FILES {
        fs::copy(source.join(name), staged.join(name))?;
    }
    sync_files(&staged, max_bytes)?;
    snapshot::private_file(&directory.join(".publishing"))?.sync_all()?;
    sync(directory)?;
    recover(directory, bundle, max_bytes)?;
    clean_legacy(directory)
}

fn clean_legacy(directory: &Path) -> io::Result<()> {
    for name in ["current", "current.next"] {
        let path = directory.join(name);
        if path.exists() {
            fs::remove_file(path)?;
        }
    }
    for name in ["snapshot-a", "snapshot-b"] {
        remove_directory(&directory.join(name))?;
    }
    sync(directory)
}

fn sync_files(directory: &Path, max_bytes: u64) -> io::Result<()> {
    let mut bytes = 0;
    for name in FILES {
        let path = directory.join(name);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        }
        bytes = total_bytes(bytes, fs::metadata(&path)?.len())?;
        File::open(path)?.sync_all()?;
    }
    if bytes > max_bytes {
        return Err(invalid("app model byte capacity reached"));
    }
    sync(directory)
}

fn total_bytes(total: u64, next: u64) -> io::Result<u64> {
    total
        .checked_add(next)
        .ok_or_else(|| invalid("app model byte size overflow"))
}

fn private_directory(path: &Path) -> io::Result<()> {
    if !path.exists() {
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(path)?;
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() {
        return Err(invalid("app profile must be a regular directory"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(invalid("app profile is not private"));
        }
    }
    Ok(())
}

fn remove_directory(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(path),
        Ok(_) => Err(invalid("app staging path must be a regular directory")),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

fn sync(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    File::open(path)?.sync_all()?;
    Ok(())
}
fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use si_gram::GramOrder;
    use si_lexicon::IndexId;
    use std::sync::atomic::{AtomicU64, Ordering};
    const BUNDLE: &str = "org.example.synthetic";

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            static ID: AtomicU64 = AtomicU64::new(0);
            Self(std::env::temp_dir().join(format!(
                "si-app-simple-{}-{}",
                std::process::id(),
                ID.fetch_add(1, Ordering::Relaxed)
            )))
        }
        fn session(&self) -> AppLearningSession {
            AppLearningSession::open(self.0.clone(), BUNDLE.into()).unwrap()
        }
        fn model(&self) -> snapshot::State {
            read_state(
                &self.0,
                BUNDLE,
                AppLearningConfig::default().max_model_bytes,
            )
            .unwrap()
        }
        fn entries(&self) -> BTreeSet<String> {
            fs::read_dir(&self.0)
                .unwrap()
                .map(|e| e.unwrap().file_name().into_string().unwrap())
                .collect()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn base() -> Lexicon {
        let mut lexicon = Lexicon::new();
        for word in ["alpha", "beta", "gamma", "delta", "epsilon"] {
            lexicon
                .add_reading(IndexId(1), word.as_bytes(), word, 100)
                .unwrap();
        }
        lexicon
    }
    fn count(state: &snapshot::State, text: &str) -> u64 {
        state
            .lexicon
            .words()
            .filter(|w| w.text == text)
            .map(|w| w.count)
            .sum()
    }

    #[test]
    fn identical_and_reordered_snapshots_do_not_write_but_only_the_previous_is_remembered() {
        let fixture = Fixture::new();
        let mut session = fixture.session();
        let base = base();
        session
            .observe(&base, &["alpha beta", "gamma delta"])
            .unwrap();
        let before = fs::read(fixture.0.join(FILES[2])).unwrap();
        assert!(
            !session
                .observe(&base, &["alpha beta", "gamma delta"])
                .unwrap()
        );
        assert!(
            !session
                .observe(&base, &["gamma delta", "alpha beta"])
                .unwrap()
        );
        assert_eq!(fs::read(fixture.0.join(FILES[2])).unwrap(), before);
        session
            .observe(&base, &["gamma delta", "epsilon alpha"])
            .unwrap();
        session
            .observe(&base, &["alpha beta", "gamma delta"])
            .unwrap();
        assert_eq!(count(&fixture.model(), "alpha"), 3);
        assert_eq!(count(&fixture.model(), "gamma"), 1);
        assert_eq!(session.previous, ["alpha beta", "gamma delta"]);
    }

    #[test]
    fn changed_paragraphs_append_without_retracting_old_words_or_grams() {
        let fixture = Fixture::new();
        let mut session = fixture.session();
        let base = base();
        session
            .observe(&base, &["alpha", "beta gamma", "delta"])
            .unwrap();
        session
            .observe(&base, &["alpha", "beta epsilon", "delta"])
            .unwrap();
        let state = fixture.model();
        assert_eq!(count(&state, "alpha"), 1);
        assert_eq!(count(&state, "beta"), 2);
        assert_eq!(count(&state, "gamma"), 1);
        assert_eq!(count(&state, "epsilon"), 1);
        let beta = state.lexicon.find_word("beta").unwrap();
        let gamma = state.lexicon.find_word("gamma").unwrap();
        let epsilon = state.lexicon.find_word("epsilon").unwrap();
        assert_eq!(state.grams.count(&[beta, gamma]), Some(1));
        assert_eq!(state.grams.count(&[beta, epsilon]), Some(1));
    }

    #[test]
    fn occurrence_difference_and_empty_snapshots_preserve_the_simple_policy() {
        let fixture = Fixture::new();
        let mut session = fixture.session();
        let base = base();
        session
            .observe(&base, &["alpha beta", "alpha beta"])
            .unwrap();
        assert!(
            !session
                .observe(&base, &["alpha beta", "alpha beta"])
                .unwrap()
        );
        session
            .observe(&base, &["alpha beta", "alpha beta", "alpha beta"])
            .unwrap();
        assert_eq!(count(&fixture.model(), "alpha"), 3);
        assert!(!session.observe(&base, &[]).unwrap());
        assert!(session.previous.is_empty());
        session.observe(&base, &["alpha beta"]).unwrap();
        assert_eq!(count(&fixture.model(), "alpha"), 4);
    }

    #[test]
    fn fixed_files_are_private_and_restart_starts_with_an_empty_previous_snapshot() {
        let fixture = Fixture::new();
        let base = base();
        fixture.session().observe(&base, &["alpha beta"]).unwrap();
        fixture.session().observe(&base, &["alpha beta"]).unwrap();
        assert_eq!(count(&fixture.model(), "alpha"), 2);
        assert_eq!(
            fixture.entries(),
            FILES
                .into_iter()
                .chain(["model.lock"])
                .map(str::to_owned)
                .collect()
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&fixture.0).unwrap().permissions().mode() & 0o777,
                0o700
            );
            for name in FILES {
                assert_eq!(
                    fs::metadata(fixture.0.join(name))
                        .unwrap()
                        .permissions()
                        .mode()
                        & 0o777,
                    0o600
                );
            }
        }
        assert!(
            !fs::read_to_string(fixture.0.join(FILES[2]))
                .unwrap()
                .contains("alpha beta")
        );
    }

    #[test]
    fn stale_writers_and_invalid_snapshots_leave_the_existing_model_unchanged() {
        let fixture = Fixture::new();
        let base = base();
        let mut first = fixture.session();
        let mut stale = fixture.session();
        first.observe(&base, &["alpha beta"]).unwrap();
        assert!(stale.observe(&base, &["gamma delta"]).is_err());
        assert!(
            !first
                .observe(
                    &base,
                    &[&"x".repeat(AppLearningConfig::default().max_snapshot_bytes + 1)]
                )
                .unwrap()
        );
        assert!(!first.observe(&base, &["alpha beta"]).unwrap());
        assert_eq!(count(&fixture.model(), "gamma"), 0);
        assert_eq!(count(&fixture.model(), "alpha"), 1);
    }

    #[test]
    fn publication_recovery_finishes_each_interrupted_file_boundary() {
        for moved in 0..=3 {
            let fixture = Fixture::new();
            let base = base();
            fixture.session().observe(&base, &["alpha beta"]).unwrap();
            let mut state = fixture.model();
            ingest::observe(&mut state, &base, [Ok("gamma delta")], GramOrder::Fourgram).unwrap();
            let staged = fixture.0.join(".pending");
            private_directory(&staged).unwrap();
            state.lexicon.save(staged.join(FILES[0])).unwrap();
            state.grams.bind_lexicon(&state.lexicon).unwrap();
            state.grams.save(staged.join(FILES[1])).unwrap();
            writeln!(
                snapshot::private_file(&staged.join(FILES[2])).unwrap(),
                "SI-APP-LEARNING-1\n{BUNDLE}\n0\n2\n{}\n{}\n1",
                state.lexicon.len(),
                state.grams.sizes().iter().sum::<usize>()
            )
            .unwrap();
            sync_files(&staged, AppLearningConfig::default().max_model_bytes).unwrap();
            snapshot::private_file(&fixture.0.join(".publishing"))
                .unwrap()
                .sync_all()
                .unwrap();
            for name in FILES.iter().take(moved) {
                fs::rename(staged.join(name), fixture.0.join(name)).unwrap();
            }
            let session = fixture.session();
            assert_eq!(session.revision, 2);
            assert_eq!(count(&fixture.model(), "alpha"), 1);
            assert_eq!(count(&fixture.model(), "gamma"), 1);
            assert_eq!(fixture.entries().len(), 4);
        }
    }

    #[test]
    fn legacy_slots_are_flattened_without_losing_the_active_pair() {
        let fixture = Fixture::new();
        let base = base();
        fixture.session().observe(&base, &["alpha beta"]).unwrap();
        let legacy = fixture.0.join("snapshot-a");
        private_directory(&legacy).unwrap();
        private_directory(&fixture.0.join("snapshot-b")).unwrap();
        for name in FILES {
            fs::rename(fixture.0.join(name), legacy.join(name)).unwrap();
        }
        writeln!(
            snapshot::private_file(&fixture.0.join("current")).unwrap(),
            "snapshot-a"
        )
        .unwrap();
        fixture.session();
        assert_eq!(count(&fixture.model(), "alpha"), 1);
        assert_eq!(fixture.entries().len(), 4);
    }

    #[test]
    fn retry_after_an_interrupted_publication_does_not_count_the_batch_twice() {
        let fixture = Fixture::new();
        let base = base();
        let mut session = fixture.session();
        session.observe(&base, &["alpha beta"]).unwrap();
        let mut state = fixture.model();
        ingest::observe(&mut state, &base, [Ok("gamma delta")], GramOrder::Fourgram).unwrap();
        // Block the second rename after the transaction has been armed and its first file moved.
        fs::remove_file(fixture.0.join(FILES[1])).unwrap();
        private_directory(&fixture.0.join(FILES[1])).unwrap();
        assert!(
            session
                .publish(&mut state, &["alpha beta", "gamma delta"])
                .is_err()
        );
        fs::remove_dir(fixture.0.join(FILES[1])).unwrap();
        assert!(
            !session
                .observe(&base, &["alpha beta", "gamma delta"])
                .unwrap()
        );
        assert_eq!(count(&fixture.model(), "alpha"), 1);
        assert_eq!(count(&fixture.model(), "gamma"), 1);
        assert_eq!(fixture.entries().len(), 4);
    }

    #[test]
    fn corrupt_staged_files_are_rejected_before_replacing_valid_fixed_files() {
        let fixture = Fixture::new();
        let base = base();
        fixture.session().observe(&base, &["alpha beta"]).unwrap();
        let before: Vec<_> = FILES
            .iter()
            .map(|name| fs::read(fixture.0.join(name)).unwrap())
            .collect();
        let staged = fixture.0.join(".pending");
        private_directory(&staged).unwrap();
        for name in FILES {
            fs::copy(fixture.0.join(name), staged.join(name)).unwrap();
        }
        fs::write(staged.join(FILES[0]), b"invalid lexicon").unwrap();
        snapshot::private_file(&fixture.0.join(".publishing"))
            .unwrap()
            .sync_all()
            .unwrap();
        assert!(AppLearningSession::open(fixture.0.clone(), BUNDLE.into()).is_err());
        for (name, bytes) in FILES.iter().zip(before) {
            assert_eq!(fs::read(fixture.0.join(name)).unwrap(), bytes);
        }
    }

    #[test]
    fn snapshot_byte_boundary_is_512_kib_and_overflow_does_not_replace_the_previous_snapshot() {
        let fixture = Fixture::new();
        let mut session = fixture.session();
        let base = base();
        let exact = " ".repeat(session.max_snapshot_bytes() - "alpha beta".len()) + "alpha beta";
        assert!(session.observe(&base, &[&exact]).unwrap());
        let before = fs::read(fixture.0.join(FILES[2])).unwrap();
        assert!(!session.observe(&base, &[&(exact.clone() + "é")]).unwrap());
        assert_eq!(session.previous.as_slice(), std::slice::from_ref(&exact));
        assert!(!session.observe(&base, &[&exact]).unwrap());
        assert_eq!(fs::read(fixture.0.join(FILES[2])).unwrap(), before);
        assert_eq!(count(&fixture.model(), "alpha"), 1);
    }

    #[test]
    fn paragraph_count_has_no_separate_quota() {
        let fixture = Fixture::new();
        let mut session = fixture.session();
        assert!(session.observe(&base(), &vec!["alpha beta"; 300]).unwrap());
        assert_eq!(count(&fixture.model(), "alpha"), 300);
    }

    #[test]
    fn model_file_limit_counts_only_the_combined_64_mib_boundary() {
        let fixture = Fixture::new();
        private_directory(&fixture.0).unwrap();
        let lexicon = snapshot::private_file(&fixture.0.join(FILES[0])).unwrap();
        snapshot::private_file(&fixture.0.join(FILES[1])).unwrap();
        let mut meta = snapshot::private_file(&fixture.0.join(FILES[2])).unwrap();
        writeln!(meta, "SI-APP-LEARNING-1\n{BUNDLE}\n0\n1\n0\n0\n0").unwrap();
        let metadata_bytes = fs::metadata(fixture.0.join(FILES[2])).unwrap().len();
        let max_bytes = AppLearningConfig::default().max_model_bytes;
        lexicon.set_len(max_bytes - metadata_bytes).unwrap();
        assert!(sync_files(&fixture.0, max_bytes).is_ok());
        lexicon.set_len(max_bytes - metadata_bytes + 1).unwrap();
        assert!(sync_files(&fixture.0, max_bytes).is_err());
    }

    #[test]
    fn configured_order_controls_new_gram_observations() {
        for max_order in [GramOrder::Bigram, GramOrder::Fourgram, GramOrder::Fivegram] {
            let fixture = Fixture::new();
            let config = AppLearningConfig {
                max_order,
                ..AppLearningConfig::default()
            };
            let mut session =
                AppLearningSession::open_with_config(fixture.0.clone(), BUNDLE.into(), config)
                    .unwrap();
            session
                .observe(&base(), &["alpha beta gamma delta epsilon"])
                .unwrap();
            let state = fixture.model();
            let ids: Vec<_> = ["alpha", "beta", "gamma", "delta", "epsilon"]
                .map(|word| state.lexicon.find_word(word).unwrap())
                .into();
            assert_eq!(state.grams.count(&ids[..2]), Some(1));
            assert_eq!(
                state.grams.count(&ids[..4]),
                (max_order != GramOrder::Bigram).then_some(1)
            );
            assert_eq!(
                state.grams.count(&ids),
                (max_order == GramOrder::Fivegram).then_some(1)
            );
        }
    }

    #[test]
    fn configured_snapshot_limit_skips_overflow_without_changing_the_previous_snapshot() {
        let fixture = Fixture::new();
        let config = AppLearningConfig {
            max_snapshot_bytes: 10,
            ..AppLearningConfig::default()
        };
        let mut session =
            AppLearningSession::open_with_config(fixture.0.clone(), BUNDLE.into(), config).unwrap();
        assert!(session.observe(&base(), &["alpha beta"]).unwrap());
        assert!(!session.observe(&base(), &["alpha betaé"]).unwrap());
        assert_eq!(session.previous, ["alpha beta"]);
        assert!(!session.observe(&base(), &["alpha beta"]).unwrap());
        assert_eq!(count(&fixture.model(), "alpha"), 1);
    }

    #[test]
    fn configured_model_limit_preserves_existing_files_and_previous_snapshot_on_rejection() {
        let fixture = Fixture::new();
        fixture.session().observe(&base(), &["alpha beta"]).unwrap();
        let before: Vec<_> = FILES
            .iter()
            .map(|name| fs::read(fixture.0.join(name)).unwrap())
            .collect();
        let config = AppLearningConfig {
            max_model_bytes: before.iter().map(|bytes| bytes.len() as u64).sum(),
            ..AppLearningConfig::default()
        };
        let mut session =
            AppLearningSession::open_with_config(fixture.0.clone(), BUNDLE.into(), config).unwrap();
        assert!(session.observe(&base(), &["gamma delta epsilon"]).is_err());
        assert!(session.previous.is_empty());
        for (name, bytes) in FILES.iter().zip(before) {
            assert_eq!(fs::read(fixture.0.join(name)).unwrap(), bytes);
        }
        assert!(!fixture.0.join(".pending").exists());
        assert!(!fixture.0.join(".publishing").exists());
    }
}
