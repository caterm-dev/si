use std::fs::{self, DirBuilder, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use si_gram::GramModel;
use si_lexicon::Lexicon;

use super::paragraph_review::ParagraphReview;
use super::{LexiconReview, ParagraphImport, lock_destination};

const STAGING_PREFIX: &str = ".pending.si-corpus.";
const STAGED_LEXICON: &str = "lexicon.silex";
const STAGED_GRAMS: &str = "words.sigram";
const STAGED_REVIEW: &str = "review.csv";
const STAGED_ENGLISH: &str = "english.csv";
const PARTNER: &str = "partner";

pub(super) struct Paths {
    pub(super) lexicon: PathBuf,
    pub(super) grams: PathBuf,
    review: PathBuf,
    english: PathBuf,
}

impl Paths {
    pub(super) fn new(lexicon: &Path, grams: &Path) -> io::Result<Self> {
        let lexicon = snapshot_path(lexicon, "silex")?;
        let grams = snapshot_path(grams, "sigram")?;
        let review = sidecar_path(&grams, ".review.csv");
        let english = sidecar_path(&grams, ".english.csv");
        Ok(Self {
            lexicon,
            grams,
            review,
            english,
        })
    }

    pub(super) fn check_destinations(&self) -> io::Result<()> {
        for path in [&self.lexicon, &self.grams, &self.review, &self.english] {
            snapshot_exists(path)?;
        }
        Ok(())
    }

    pub(super) fn lock_destinations(&self) -> io::Result<[File; 2]> {
        let mut paths = [&self.lexicon, &self.grams];
        paths.sort_unstable();
        Ok([
            lock_destination(paths[0], false)?,
            lock_destination(paths[1], false)?,
        ])
    }

    pub(super) fn clear_grams(&self) -> io::Result<bool> {
        let _locks = self.lock_destinations()?;
        check_no_pending_ingest(&self.lexicon)?;
        check_no_pending_ingest(&self.grams)?;
        if !snapshot_exists(&self.grams)? {
            return Ok(false);
        }
        fs::remove_file(&self.grams)?;
        Ok(true)
    }

    pub(super) fn save(
        &self,
        lexicon: &mut Lexicon,
        grams: &GramModel,
        review: ParagraphReview,
        report: ParagraphImport,
        sources: &[PathBuf],
    ) -> io::Result<ParagraphImport> {
        self.prepare(lexicon, grams, review, &report, sources)?;
        self.recover(sources)?
            .ok_or_else(|| io::Error::other("prepared corpus import disappeared"))
    }

    fn prepare(
        &self,
        lexicon: &mut Lexicon,
        grams: &GramModel,
        mut review: ParagraphReview,
        report: &ParagraphImport,
        sources: &[PathBuf],
    ) -> io::Result<()> {
        let lexicon_stage = StagingDirectory::new(&self.lexicon)?;
        let grams_stage = StagingDirectory::new(&self.grams)?;
        lexicon.save(lexicon_stage.0.join(STAGED_LEXICON))?;
        grams.save(grams_stage.0.join(STAGED_GRAMS))?;
        let english_rows = review.save_english(&grams_stage.0.join(STAGED_ENGLISH))?;
        let rows = review.save(lexicon, &grams_stage.0.join(STAGED_REVIEW))?;
        write_synced(
            &lexicon_stage.0.join("report"),
            &encode_report(report, rows, english_rows),
        )?;
        write_synced(&lexicon_stage.0.join("sources"), &encode_sources(sources)?)?;
        for (stage, partner) in [(&lexicon_stage, &self.grams), (&grams_stage, &self.lexicon)] {
            write_synced(
                &stage.0.join(PARTNER),
                partner.as_os_str().as_encoded_bytes(),
            )?;
        }
        // Publishing the lexicon record commits both stages for recovery.
        fs::rename(&grams_stage.0, pending_path(&self.grams))?;
        fs::rename(&lexicon_stage.0, pending_path(&self.lexicon))
    }

    pub(super) fn recover(&self, sources: &[PathBuf]) -> io::Result<Option<ParagraphImport>> {
        let lexicon_pending = pending_path(&self.lexicon);
        let grams_pending = pending_path(&self.grams);
        let lexicon_ready = pending_for(&lexicon_pending, &self.grams)?;
        let grams_ready = pending_for(&grams_pending, &self.lexicon)?;
        if !lexicon_ready {
            // An interruption before the commit point left only the gram stage.
            if grams_ready {
                clear_pending(&grams_pending)?;
            }
            return Ok(None);
        }
        if fs::read(lexicon_pending.join("sources"))? != encode_sources(sources)? {
            return Err(io::Error::other(
                "resume the pending corpus ingest with its original source paths before importing another batch",
            ));
        }

        let report = decode_report(
            &fs::read(lexicon_pending.join("report"))?,
            &self.review,
            &self.english,
        )?;
        let staged_lexicon = lexicon_pending.join(STAGED_LEXICON);
        if grams_ready {
            let updates = [
                (staged_lexicon, &self.lexicon),
                (grams_pending.join(STAGED_GRAMS), &self.grams),
                (grams_pending.join(STAGED_REVIEW), &self.review),
                (grams_pending.join(STAGED_ENGLISH), &self.english),
            ];
            let count = if report.english_review.is_some() {
                4
            } else {
                3
            };
            let updates = &updates[..count];
            let mut ready = [false; 4];
            for ((source, destination), ready) in updates.iter().zip(&mut ready) {
                *ready = snapshot_exists(source)?;
                if !*ready && !snapshot_exists(destination)? {
                    return Err(io::Error::other(
                        "pending corpus import is missing a snapshot",
                    ));
                }
            }
            for ((source, destination), ready) in updates.iter().zip(ready) {
                if ready {
                    fs::rename(source, destination)?;
                }
            }
            clear_pending(&grams_pending)?;
        } else if snapshot_exists(&staged_lexicon)?
            || !snapshot_exists(&self.lexicon)?
            || !snapshot_exists(&self.grams)?
            || !snapshot_exists(&self.review)?
            || (report.english_review.is_some() && !snapshot_exists(&self.english)?)
        {
            return Err(io::Error::other(
                "pending corpus import is missing its gram stage",
            ));
        }
        clear_pending(&lexicon_pending)?;
        Ok(Some(report))
    }
}

fn snapshot_path(path: &Path, extension: &str) -> io::Result<PathBuf> {
    if !path.extension().is_some_and(|actual| {
        actual
            .as_encoded_bytes()
            .eq_ignore_ascii_case(extension.as_bytes())
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "corpus ingest requires a .{extension} path, got {}",
                path.display()
            ),
        ));
    }
    check_path(path)?;
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "missing corpus snapshot filename",
        )
    })?;
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;
    let path = parent.canonicalize()?.join(name);
    check_path(&path)?;
    Ok(path)
}

fn check_path(path: &Path) -> io::Result<()> {
    if path.components().any(|part| {
        part.as_os_str()
            .as_encoded_bytes()
            .ends_with(b".ingest-pending")
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "corpus snapshot overlaps a reserved ingest path",
        ));
    }
    Ok(())
}

fn snapshot_exists(path: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => Ok(true),
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "corpus ingest requires a regular file at {}",
                path.display()
            ),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn pending_path(path: &Path) -> PathBuf {
    sidecar_path(path, ".ingest-pending")
}

fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

pub(super) fn check_no_pending_ingest(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(pending_path(path)) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
        Ok(_) => Err(io::Error::other(
            "resume the pending corpus ingest before editing this snapshot",
        )),
    }
}

fn pending_for(pending: &Path, partner: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(pending) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Err(io::Error::other("invalid pending corpus import")),
    }
    let expected = match fs::read(pending.join(PARTNER)) {
        Err(error)
            if error.kind() == io::ErrorKind::NotFound && pending.join("output").is_file() =>
        {
            return Err(io::Error::other(
                "resume the pending directory-based import with the previous si-cli version",
            ));
        }
        result => result?,
    };
    if expected != partner.as_os_str().as_encoded_bytes() {
        return Err(io::Error::other(format!(
            "resume the pending corpus ingest using the paired snapshot {}",
            String::from_utf8_lossy(&expected)
        )));
    }
    Ok(true)
}

fn clear_pending(pending: &Path) -> io::Result<()> {
    // Move the record out of the way before deleting it.
    let completed = StagingDirectory::new(pending)?;
    fs::remove_dir(&completed.0)?;
    fs::rename(pending, &completed.0)
}

fn write_synced(path: &Path, contents: &[u8]) -> io::Result<()> {
    let mut file = File::create(path)?;
    file.write_all(contents)?;
    file.sync_all()
}

fn encode_sources(sources: &[PathBuf]) -> io::Result<Vec<u8>> {
    let mut encoded = Vec::new();
    for source in sources {
        encoded.extend_from_slice(std::path::absolute(source)?.as_os_str().as_encoded_bytes());
        encoded.push(0);
    }
    Ok(encoded)
}

fn encode_report(report: &ParagraphImport, review_rows: usize, english_rows: usize) -> Vec<u8> {
    let [two, three, four, five] = report.grams;
    [
        report.paragraphs,
        report.matched_words,
        report.added_english_words,
        report.letter_placeholders,
        report.number_placeholders,
        report.unknown_characters,
        report.ambiguous_words,
        two,
        three,
        four,
        review_rows,
        five,
        english_rows,
    ]
    .into_iter()
    .map(|value| value.to_string())
    .collect::<Vec<_>>()
    .join(" ")
    .into_bytes()
}

fn decode_report(bytes: &[u8], review: &Path, english: &Path) -> io::Result<ParagraphImport> {
    let invalid = || io::Error::other("invalid pending corpus import report");
    let text = std::str::from_utf8(bytes).map_err(|_| invalid())?;
    let values = text
        .split_ascii_whitespace()
        .map(str::parse)
        .collect::<Result<Vec<usize>, _>>()
        .map_err(|_| invalid())?;
    let [
        paragraphs,
        matched_words,
        added_english_words,
        letter_placeholders,
        number_placeholders,
        unknown_characters,
        ambiguous_words,
        two,
        three,
        four,
        rows,
        extra @ ..,
    ] = values.as_slice()
    else {
        return Err(invalid());
    };
    let (five, english_rows) = match extra {
        [] => (0, None),
        [five] => (*five, None),
        [five, english_rows] => (*five, Some(*english_rows)),
        _ => return Err(invalid()),
    };
    Ok(ParagraphImport {
        paragraphs: *paragraphs,
        matched_words: *matched_words,
        added_english_words: *added_english_words,
        letter_placeholders: *letter_placeholders,
        number_placeholders: *number_placeholders,
        unknown_characters: *unknown_characters,
        ambiguous_words: *ambiguous_words,
        grams: [*two, *three, *four, five],
        review: Some(LexiconReview {
            path: review.to_owned(),
            rows: *rows,
        }),
        english_review: english_rows.map(|rows| LexiconReview {
            path: english.to_owned(),
            rows,
        }),
    })
}

struct StagingDirectory(PathBuf);

impl StagingDirectory {
    fn new(destination: &Path) -> io::Result<Self> {
        static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);
        let mut options = DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            options.mode(0o700);
        }
        loop {
            let sequence = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let temporary = format!("{STAGING_PREFIX}{}.{sequence}.tmp", std::process::id());
            let path = destination.with_file_name(temporary);
            match options.create(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
    }
}

impl Drop for StagingDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resources::{EngineResources, add_corpus, ingest_corpus};
    use si_gram::GramBuilder;
    use si_lexicon::IndexId;

    #[test]
    fn a_gram_stage_without_a_commit_record_is_discarded() -> io::Result<()> {
        let scratch = StagingDirectory::new(&std::env::temp_dir().join("si-ingest-test"))?;
        let paths = Paths::new(
            &scratch.0.join("main.silex"),
            &scratch.0.join("main.sigram"),
        )?;
        let pending = pending_path(&paths.grams);
        fs::create_dir(&pending)?;
        write_synced(
            &pending.join(PARTNER),
            paths.lexicon.as_os_str().as_encoded_bytes(),
        )?;
        fs::write(pending.join(STAGED_GRAMS), b"uncommitted")?;
        assert!(paths.recover(&[scratch.0.join("source.txt")])?.is_none());
        assert!(!pending.exists());
        assert!(!paths.grams.exists());
        Ok(())
    }

    #[test]
    fn interrupted_publication_recovers_without_counting_the_corpus_again() -> io::Result<()> {
        let scratch = StagingDirectory::new(&std::env::temp_dir().join("si-ingest-test"))?;
        for phase in 0..=5 {
            let paths = Paths::new(
                &scratch.0.join(format!("lexicons/main-{phase}.silex")),
                &scratch.0.join(format!("grams/main-{phase}.sigram")),
            )?;
            let mut lexicon = Lexicon::new();
            let first = lexicon.add_reading(IndexId(0), b"jia", "甲", 1).unwrap();
            lexicon.save(&paths.lexicon)?;
            lexicon.add_count(first, 1).unwrap();
            let second = lexicon.add_reading(IndexId(1), b"test", "TEST", 1).unwrap();
            let mut builder = GramBuilder::new();
            builder.observe(&[first, second]).unwrap();
            let fivegram = [first, second, first, second, first];
            builder.add(&fivegram, 3).unwrap();
            let mut model = builder.finish().unwrap();
            model.bind_lexicon(&lexicon)?;
            let report = ParagraphImport {
                paragraphs: 1,
                matched_words: 2,
                grams: model.sizes(),
                review: Some(LexiconReview {
                    path: paths.review.clone(),
                    rows: 0,
                }),
                english_review: Some(LexiconReview {
                    path: paths.english.clone(),
                    rows: 1,
                }),
                ..ParagraphImport::default()
            };
            let sources = [scratch.0.join("source-no-longer-needed.txt")];
            let mut review = ParagraphReview::default();
            review.record_english("Unlisted")?;
            paths.prepare(&mut lexicon, &model, review, &report, &sources)?;

            let lexicon_pending = pending_path(&paths.lexicon);
            let grams_pending = pending_path(&paths.grams);
            let updates = [
                (lexicon_pending.join(STAGED_LEXICON), &paths.lexicon),
                (grams_pending.join(STAGED_GRAMS), &paths.grams),
                (grams_pending.join(STAGED_REVIEW), &paths.review),
                (grams_pending.join(STAGED_ENGLISH), &paths.english),
            ];
            for (source, destination) in updates.into_iter().take(phase) {
                fs::rename(source, destination)?;
            }
            if phase == 5 {
                clear_pending(&grams_pending)?;
            } else {
                let blocked = add_corpus(&paths.lexicon, &paths.grams, &sources).unwrap_err();
                assert!(blocked.to_string().contains("pending corpus ingest"));
            }
            let next_batch = [scratch.0.join("next-batch.txt")];
            let blocked = ingest_corpus(&paths.lexicon, &paths.grams, &next_batch).unwrap_err();
            assert!(blocked.to_string().contains("original source paths"));
            assert_eq!(
                ingest_corpus(&paths.lexicon, &paths.grams, &sources)?,
                report
            );
            assert!(!lexicon_pending.exists());
            assert!(!grams_pending.exists());
            let saved = EngineResources::open(&paths.lexicon, Some(&paths.grams))?;
            assert_eq!(saved.lexicon().word(first).unwrap().count, 2);
            assert_eq!(saved.grams().unwrap().count(&[first, second]), Some(1));
            assert_eq!(saved.grams().unwrap().count(&fivegram), Some(3));
            assert_eq!(
                fs::read_to_string(&paths.english)?,
                "text,reading,weight\nUnlisted,unlisted,1\n"
            );
        }
        Ok(())
    }
}
