use si_lexicon::{EditError, IndexId, Lexicon, Word, WordId};
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

const FULL: IndexId = IndexId(1);
const INITIALS: IndexId = IndexId(2);
static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(0);

#[test]
fn a_word_has_one_raw_count_across_key_spaces() {
    let mut lexicon = Lexicon::new();
    let word = lexicon.add_word("重", 200).unwrap();
    let other = lexicon.add_word("虫", 50).unwrap();
    assert!(lexicon.add_key(FULL, b"chong", word).unwrap());
    assert!(lexicon.add_key(FULL, b"zhong", word).unwrap());
    assert!(lexicon.add_key(INITIALS, b"ch", word).unwrap());
    assert!(lexicon.add_key(FULL, b"chong", other).unwrap());
    assert!(!lexicon.add_key(FULL, b"chong", word).unwrap());
    assert_eq!(lexicon.add_word("重", 3).unwrap(), word);

    let expected = Word {
        id: word,
        text: "重",
        count: 203,
        reading: None,
    };
    assert_eq!(lexicon.len(), 2);
    assert_eq!(lexicon.find_word("重"), Some(word));
    assert_eq!(lexicon.word(word), Some(expected));
    assert_eq!(
        lexicon.exact(FULL, b"chong").collect::<Vec<_>>(),
        [expected, lexicon.word(other).unwrap()]
    );
    assert_eq!(lexicon.exact(FULL, b"zhong").next(), Some(expected));
    assert_eq!(lexicon.exact(INITIALS, b"ch").next(), Some(expected));
    assert!(lexicon.exact(FULL, b"ch").next().is_none());
}

#[test]
fn compact_and_edit_preserve_key_order_and_word_ids() {
    let mut lexicon = Lexicon::new();
    let first = lexicon.add_word("甲", 1).unwrap();
    let second = lexicon.add_word("乙", 2).unwrap();
    lexicon.add_key(FULL, b"shi", second).unwrap();
    lexicon.add_key(FULL, b"si", first).unwrap();
    lexicon.add_key(INITIALS, b"s", first).unwrap();
    lexicon.compact().unwrap();
    assert!(!lexicon.add_key(FULL, b"shi", second).unwrap());

    let third = lexicon.add_word("丙", 3).unwrap();
    lexicon.add_key(FULL, b"sha", third).unwrap();
    lexicon.add_key(FULL, b"shi", first).unwrap();
    lexicon.add_key(FULL, b"shi", third).unwrap();
    lexicon.add_key(FULL, b"sh\xff", third).unwrap();
    let matches = |lexicon: &Lexicon| {
        lexicon
            .prefix(FULL, b"sh")
            .map(|(key, word)| (key.to_vec(), word.id))
            .collect::<Vec<_>>()
    };
    let expected = [
        (b"sha".to_vec(), third),
        (b"shi".to_vec(), first),
        (b"shi".to_vec(), second),
        (b"shi".to_vec(), third),
        (b"sh\xff".to_vec(), third),
    ];
    assert_eq!(matches(&lexicon), expected);
    assert_eq!(lexicon.prefix(FULL, b"").count(), 6);
    assert_eq!(lexicon.prefix(FULL, b"sh\xff").count(), 1);
    assert_eq!(lexicon.prefix(FULL, b"zz").count(), 0);
    lexicon.compact().unwrap();
    assert_eq!(matches(&lexicon), expected);
    assert_eq!(lexicon.word(first).unwrap().text, "甲");
    assert_eq!(lexicon.word(second).unwrap().text, "乙");
    assert_eq!(lexicon.word(third).unwrap().text, "丙");
}

#[test]
fn saved_dictionaries_can_be_reopened_and_edited_independently() -> io::Result<()> {
    let directory = ScratchDirectory::new()?;
    let base_path = directory.0.join("base.silex");
    let personal_path = directory.0.join("personal.silex");
    let mut base = Lexicon::new();
    let mut personal = Lexicon::new();

    let base_word = base.add_word("SI", 9).unwrap();
    let personal_word = personal.add_word("私人词", 3).unwrap();
    assert_eq!(base_word, WordId(0));
    assert_eq!(personal_word, WordId(0));
    base.add_key(FULL, b"si", base_word).unwrap();
    personal.add_key(FULL, b"private", personal_word).unwrap();
    base.save(&base_path)?;
    personal.save(&personal_path)?;
    drop(base);
    drop(personal);

    let mut personal = Lexicon::open(&personal_path)?;
    assert_eq!(personal.add_word("私人词", 2).unwrap(), personal_word);
    let new_word = personal.add_word("SI Engine", 1).unwrap();
    personal.add_key(FULL, b"sie", new_word).unwrap();
    personal.save(&personal_path)?;
    drop(personal);

    let base = Lexicon::open(&base_path)?;
    let personal = Lexicon::open(&personal_path)?;
    assert_eq!(base.exact(FULL, b"si").next().unwrap().count, 9);
    assert_eq!(personal.exact(FULL, b"private").next().unwrap().count, 5);
    assert_eq!(personal.find_word("SI Engine"), Some(new_word));
    assert_eq!(personal.exact(FULL, b"sie").next().unwrap().id, new_word);
    assert_eq!(base.word(WordId(0)).unwrap().text, "SI");
    assert_eq!(personal.word(WordId(0)).unwrap().text, "私人词");
    assert!(base.find_word("私人词").is_none());
    assert!(base.word(new_word).is_none());

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&personal_path)?.permissions().mode() & 0o077,
            0
        );
    }
    Ok(())
}

#[test]
fn invalid_edits_leave_counts_and_words_unchanged() {
    let mut lexicon = Lexicon::new();
    assert_eq!(lexicon.add_word("", 1), Err(EditError::EmptyText));
    let word = lexicon.add_word("word", u64::MAX).unwrap();
    assert_eq!(lexicon.add_word("word", 1), Err(EditError::CountOverflow));
    assert_eq!(lexicon.word(word).unwrap().count, u64::MAX);
    assert_eq!(lexicon.add_key(FULL, b"", word), Err(EditError::EmptyKey));
    let missing = WordId(1);
    assert_eq!(
        lexicon.add_key(FULL, b"word", missing),
        Err(EditError::UnknownWord)
    );
    let zero = lexicon.add_word("zero", 0).unwrap();
    assert_eq!(lexicon.word(zero).unwrap().count, 0);
    assert!(lexicon.exact(FULL, b"word").next().is_none());
}

#[test]
fn corrupt_snapshot_returns_an_error() -> io::Result<()> {
    let directory = ScratchDirectory::new()?;
    let path = directory.0.join("dictionary.silex");
    let mut lexicon = Lexicon::new();
    let word = lexicon.add_word("词", 10).unwrap();
    lexicon.add_key(FULL, b"ci", word).unwrap();
    lexicon.save(&path)?;
    let bytes = fs::read(&path)?;

    fs::write(&path, &bytes[..bytes.len() - 1])?;
    assert!(
        matches!(Lexicon::open(&path), Err(error) if error.kind() == io::ErrorKind::InvalidData)
    );

    let mut invalid = bytes.clone();
    let last = invalid.len() - 1;
    invalid[last] = 0xff;
    fs::write(&path, invalid)?;
    assert!(
        matches!(Lexicon::open(&path), Err(error) if error.kind() == io::ErrorKind::InvalidData)
    );
    Ok(())
}

#[test]
fn a_legacy_aggregate_cannot_be_updated_as_an_individual_reading() -> io::Result<()> {
    let directory = ScratchDirectory::new()?;
    let path = directory.0.join("legacy.silex");
    let mut lexicon = Lexicon::new();
    let id = lexicon.add_word("重", 10).unwrap();
    lexicon.add_key(FULL, b"chong", id).unwrap();
    lexicon.add_key(FULL, b"zhong", id).unwrap();
    lexicon.save(&path)?;
    let mut legacy = fs::read(&path)?;
    let reading_record = 32 + 16 + "重".len();
    legacy.drain(reading_record..reading_record + 8);
    legacy.drain(28..32);
    legacy[6] = 2;
    fs::write(&path, legacy)?;

    let mut lexicon = Lexicon::open(&path)?;
    assert_eq!(lexicon.word(id).unwrap().reading, None);
    assert_eq!(
        lexicon.add_reading(FULL, b"chong", "重", 1),
        Err(EditError::UnresolvedReading)
    );
    assert_eq!(lexicon.word(id).unwrap().count, 10);
    assert_eq!(lexicon.len(), 1);
    Ok(())
}

#[test]
fn failed_snapshot_replacement_cleans_up_the_temporary_file() -> io::Result<()> {
    let directory = ScratchDirectory::new()?;
    let destination = directory.0.join("existing.silex");
    fs::create_dir(&destination)?;
    let mut lexicon = Lexicon::new();
    assert!(lexicon.save(&destination).is_err());
    assert!(destination.is_dir());
    assert_eq!(fs::read_dir(&directory.0)?.count(), 1);
    Ok(())
}

struct ScratchDirectory(PathBuf);

impl ScratchDirectory {
    fn new() -> io::Result<Self> {
        loop {
            let sequence = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("si-lexicon-{}-{sequence}", std::process::id()));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
    }
}

impl Drop for ScratchDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
