use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::ops::Bound::{Included, Unbounded};

use crate::{EditError, IndexId, section_end};

type Key<'a> = (IndexId, &'a [u8]);
type KeyPostings<'a> = (Key<'a>, &'a [u32]);

#[derive(Default)]
pub(crate) struct KeyIndex {
    pub(crate) keys: Vec<u8>,
    pub(crate) records: Vec<KeyRecord>,
    pub(crate) postings: Vec<u32>,
}

pub(crate) struct KeyRecord {
    pub(crate) index: IndexId,
    pub(crate) key_end: u32,
    pub(crate) postings_end: u32,
}

impl KeyIndex {
    pub(crate) fn key(&self, position: usize) -> Key<'_> {
        let record = &self.records[position];
        let start = position
            .checked_sub(1)
            .map_or(0, |i| self.records[i].key_end);
        (
            record.index,
            &self.keys[start as usize..record.key_end as usize],
        )
    }

    fn words(&self, position: usize) -> &[u32] {
        let start = position
            .checked_sub(1)
            .map_or(0, |i| self.records[i].postings_end);
        &self.postings[start as usize..self.records[position].postings_end as usize]
    }

    pub(crate) fn get(&self, key: Key<'_>) -> &[u32] {
        let position = self.lower_bound(key);
        if position < self.records.len() && self.key(position) == key {
            self.words(position)
        } else {
            &[]
        }
    }

    pub(crate) fn from(&self, key: Key<'_>) -> impl Iterator<Item = KeyPostings<'_>> {
        let start = self.lower_bound(key);
        (start..self.records.len()).map(|position| (self.key(position), self.words(position)))
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = KeyPostings<'_>> {
        (0..self.records.len()).map(|position| (self.key(position), self.words(position)))
    }

    fn lower_bound(&self, key: Key<'_>) -> usize {
        let mut start = 0;
        let mut end = self.records.len();
        while start < end {
            let middle = start + (end - start) / 2;
            if self.key(middle) < key {
                start = middle + 1;
            } else {
                end = middle;
            }
        }
        start
    }

    pub(crate) fn push(&mut self, key: Key<'_>, words: Postings<'_>) -> Result<(), EditError> {
        let (index, key) = key;
        section_end(self.records.len(), 1)?;
        let key_end = section_end(self.keys.len(), key.len())?;
        let postings_end = section_end(self.postings.len(), words.len())?;
        self.keys.extend_from_slice(key);
        self.postings.extend(words);
        self.records.push(KeyRecord {
            index,
            key_end,
            postings_end,
        });
        Ok(())
    }
}

#[derive(Default)]
pub(crate) struct PendingIndex(BTreeMap<IndexId, BTreeMap<Vec<u8>, Vec<u32>>>);

impl PendingIndex {
    pub(crate) fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub(crate) fn insert(&mut self, (index, key): Key<'_>, id: u32) -> bool {
        let keys = self.0.entry(index).or_default();
        let words = match keys.get_mut(key) {
            Some(words) => words,
            None => {
                keys.insert(key.to_vec(), vec![id]);
                return true;
            }
        };
        match words.binary_search(&id) {
            Ok(_) => false,
            Err(position) => {
                words.insert(position, id);
                true
            }
        }
    }

    pub(crate) fn get(&self, (index, key): Key<'_>) -> &[u32] {
        self.0
            .get(&index)
            .and_then(|keys| keys.get(key))
            .map_or(&[], Vec::as_slice)
    }

    pub(crate) fn from(&self, (index, prefix): Key<'_>) -> impl Iterator<Item = KeyPostings<'_>> {
        self.0
            .get(&index)
            .map(|keys| keys.range::<[u8], _>((Included(prefix), Unbounded)))
            .into_iter()
            .flatten()
            .map(move |(key, ids)| ((index, key.as_slice()), ids.as_slice()))
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = KeyPostings<'_>> {
        self.0.iter().flat_map(|(&index, keys)| {
            keys.iter()
                .map(move |(key, ids)| ((index, key.as_slice()), ids.as_slice()))
        })
    }
}

pub(crate) struct Postings<'a> {
    packed: &'a [u32],
    pending: &'a [u32],
}

impl<'a> Postings<'a> {
    pub(crate) fn new(packed: &'a [u32], pending: &'a [u32]) -> Self {
        Self { packed, pending }
    }
}

impl Iterator for Postings<'_> {
    type Item = u32;

    fn next(&mut self) -> Option<u32> {
        let list = match (self.packed.first(), self.pending.first()) {
            (_, None) => &mut self.packed,
            (Some(packed), Some(pending)) if packed < pending => &mut self.packed,
            _ => &mut self.pending,
        };
        let (&id, rest) = list.split_first()?;
        *list = rest;
        Some(id)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let length = self.packed.len() + self.pending.len();
        (length, Some(length))
    }
}

impl ExactSizeIterator for Postings<'_> {}

pub(crate) fn merge_keys<'a>(
    packed: impl Iterator<Item = KeyPostings<'a>> + 'a,
    pending: impl Iterator<Item = KeyPostings<'a>> + 'a,
) -> impl Iterator<Item = (Key<'a>, Postings<'a>)> + 'a {
    let mut packed = packed.peekable();
    let mut pending = pending.peekable();
    std::iter::from_fn(move || {
        let order = match (packed.peek(), pending.peek()) {
            (Some((left, _)), Some((right, _))) => left.cmp(right),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => return None,
        };
        let (key, base, edits) = match order {
            Ordering::Less => {
                let (key, words) = packed.next().unwrap();
                (key, words, &[][..])
            }
            Ordering::Greater => {
                let (key, words) = pending.next().unwrap();
                (key, &[][..], words)
            }
            Ordering::Equal => {
                let (key, base) = packed.next().unwrap();
                let (_, edits) = pending.next().unwrap();
                (key, base, edits)
            }
        };
        Some((key, Postings::new(base, edits)))
    })
}
