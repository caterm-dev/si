use std::io;

use si_gram::GramBuilder;
use si_lexicon::{IndexId, Lexicon, Word, WordId};

use super::{UserModelStore, snapshot};

/// Exact saved identity and count, used for optimistic edits across snapshot generations.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserEntry {
    pub text: String,
    pub reading: Option<(u32, Vec<u8>)>,
    pub count: u64,
}

impl From<Word<'_>> for UserEntry {
    fn from(word: Word<'_>) -> Self {
        Self {
            text: word.text.to_owned(),
            reading: word.reading.map(|r| (r.index.0, r.key.to_vec())),
            count: word.count,
        }
    }
}

impl UserModelStore {
    /// Atomically edit vocabulary and remap surviving grams. Changed identities lose their
    /// old grams; frequency-only edits preserve them. Stale edits never overwrite newer data.
    pub fn edit_entry(&self, old: Option<&UserEntry>, new: Option<&UserEntry>) -> io::Result<()> {
        let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid or stale user entry");
        if old.is_none() && new.is_none() {
            return Err(invalid());
        }
        if let Some(new) = new
            && (new.text.is_empty()
                || new.text.len() > 4096
                || new.text.chars().any(char::is_control)
                || new.reading.as_ref().is_some_and(|(index, key)| {
                    *index > 1
                        || key.is_empty()
                        || key.len() > 256
                        || !key.iter().all(|b| b.is_ascii_lowercase() || *b == b'\'')
                }))
        {
            return Err(invalid());
        }
        let profile = snapshot::Profile::open(&self.directory, true)?.expect("created profile");
        let active = profile.active()?;
        profile.clean_inactive(active)?;
        let mut state = profile.read(active)?;
        let old_id = old
            .map(|old| {
                state
                    .lexicon
                    .words()
                    .find(|w| UserEntry::from(*w) == *old)
                    .map(|w| w.id)
                    .ok_or_else(invalid)
            })
            .transpose()?;
        if new.is_some_and(|new| {
            state.lexicon.words().any(|w| {
                Some(w.id) != old_id
                    && w.text == new.text
                    && UserEntry::from(w).reading == new.reading
            })
        }) {
            return Err(invalid());
        }
        let same_identity = old
            .zip(new)
            .is_some_and(|(a, b)| a.text == b.text && a.reading == b.reading);
        let mut lexicon = Lexicon::new();
        let mut mapping = vec![None; state.lexicon.len()];
        for word in state.lexicon.words() {
            if Some(word.id) == old_id && !same_identity {
                continue;
            }
            let id = WordId(lexicon.len() as u32);
            lexicon
                .restore_word(
                    id,
                    word.text,
                    if Some(word.id) == old_id {
                        new.unwrap().count
                    } else {
                        word.count
                    },
                    word.reading,
                )
                .map_err(io::Error::other)?;
            mapping[word.id.0 as usize] = Some(id);
        }
        for (key, id) in state.lexicon.lookup_keys() {
            if let Some(id) = mapping[id.0 as usize] {
                lexicon
                    .add_key(key.index, key.key, id)
                    .map_err(io::Error::other)?;
            }
        }
        if let Some(new) = new.filter(|_| !same_identity) {
            if let Some((index, key)) = &new.reading {
                lexicon
                    .add_reading(IndexId(*index), key, &new.text, new.count)
                    .map_err(io::Error::other)?;
            } else {
                lexicon
                    .add_word(&new.text, new.count)
                    .map_err(io::Error::other)?;
            }
        }
        let mut grams = GramBuilder::new();
        macro_rules! retain {
            ($rows:expr) => {
                for (ids, count) in $rows {
                    if let Some(ids) = ids
                        .iter()
                        .map(|id| mapping[id.0 as usize])
                        .collect::<Option<Vec<_>>>()
                    {
                        grams.add(&ids, count).map_err(io::Error::other)?;
                    }
                }
            };
        }
        retain!(state.grams.bigrams());
        retain!(state.grams.trigrams());
        retain!(state.grams.fourgrams());
        retain!(state.grams.fivegrams());
        state.lexicon = lexicon;
        state.grams = grams.finish().map_err(io::Error::other)?;
        state.grams.bind_lexicon(&state.lexicon)?;
        profile.publish(active, &mut state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn edits_preserve_unrelated_counts_aliases_and_reject_stale_rows() {
        let path = std::env::temp_dir().join(format!(
            "si-entry-{}-{}.si-user",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = UserModelStore::new(&path);
        let a = UserEntry {
            text: "alpha".into(),
            reading: Some((1, b"alpha".to_vec())),
            count: 7,
        };
        let b = UserEntry {
            text: "beta".into(),
            reading: Some((1, b"beta".to_vec())),
            count: 9,
        };
        store.edit_entry(None, Some(&a)).unwrap();
        store.edit_entry(None, Some(&b)).unwrap();
        assert!(store.edit_entry(None, Some(&a)).is_err());
        {
            let profile = snapshot::Profile::open(&path, false).unwrap().unwrap();
            let active = profile.active().unwrap();
            let mut state = profile.read(active).unwrap();
            state
                .lexicon
                .add_key(IndexId(1), b"alias", WordId(1))
                .unwrap();
            let mut grams = GramBuilder::new();
            grams.add(&[WordId(0), WordId(1)], 3).unwrap();
            grams.add(&[WordId(1), WordId(1)], 5).unwrap();
            state.grams = grams.finish().unwrap();
            state.grams.bind_lexicon(&state.lexicon).unwrap();
            profile.publish(active, &mut state).unwrap();
        }
        let changed = UserEntry {
            count: 12,
            ..a.clone()
        };
        store.edit_entry(Some(&a), Some(&changed)).unwrap();
        assert!(store.edit_entry(Some(&a), None).is_err());
        let loaded = store.load().unwrap().unwrap();
        assert_eq!(loaded.lexicon().words().next().unwrap().count, 12);
        store.edit_entry(Some(&changed), None).unwrap();
        let profile = snapshot::Profile::open(&path, false).unwrap().unwrap();
        let state = profile.read(profile.active().unwrap()).unwrap();
        assert_eq!(state.lexicon.len(), 1);
        assert_eq!(
            state
                .lexicon
                .exact(IndexId(1), b"alias")
                .next()
                .unwrap()
                .text,
            "beta"
        );
        assert_eq!(state.grams.count(&[WordId(0), WordId(0)]), Some(5));
        assert_eq!(state.grams.sizes(), [1, 0, 0, 0]);
        drop(profile);
        let renamed = UserEntry {
            text: "gamma".into(),
            reading: Some((1, b"gamma".to_vec())),
            count: 2,
        };
        store.edit_entry(Some(&b), Some(&renamed)).unwrap();
        store.edit_entry(Some(&renamed), None).unwrap();
        assert!(store.load().unwrap().unwrap().lexicon().is_empty());
        std::fs::remove_dir_all(path).unwrap();
    }
}
