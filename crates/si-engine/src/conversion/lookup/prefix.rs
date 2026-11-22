//! Memoize dictionary transitions shared by exact and corrected spellings.
//! Keys identify immutable row ranges, not input buffers or client state.

use std::sync::{Mutex, MutexGuard};

use super::Entry;
use crate::conversion::cache::Memo;

const PREFIX_CACHE_CAPACITY: usize = 8_192;
const MIN_CACHED_ROWS: usize = 32;

#[derive(Clone, Copy, Eq, Hash, PartialEq)]
struct Key {
    start: usize,
    count: usize,
    depth: usize,
    byte: u8,
}

pub(super) struct PrefixCache(Mutex<Memo<Key, (usize, usize)>>);

impl Default for PrefixCache {
    fn default() -> Self {
        Self(Mutex::new(Memo::new(PREFIX_CACHE_CAPACITY)))
    }
}

pub(super) struct Prefixes<'cache, 'rows, 'data> {
    dictionary: &'rows [Entry<'data>],
    cache: Option<MutexGuard<'cache, Memo<Key, (usize, usize)>>>,
}

impl PrefixCache {
    pub(super) fn query<'cache, 'rows, 'data>(
        &'cache self,
        dictionary: &'rows [Entry<'data>],
    ) -> Prefixes<'cache, 'rows, 'data> {
        Prefixes {
            dictionary,
            cache: self.0.try_lock().ok(),
        }
    }
}

impl<'rows, 'data> Prefixes<'_, 'rows, 'data> {
    pub(super) fn matching(
        &mut self,
        rows: &'rows [Entry<'data>],
        depth: usize,
        byte: u8,
    ) -> &'rows [Entry<'data>] {
        if rows.is_empty() {
            return rows;
        }
        // Tiny ranges are cheaper to search directly than to hash and cache.
        if rows.len() < MIN_CACHED_ROWS || self.cache.is_none() {
            let lower =
                rows.partition_point(|row| row.spelling.get(depth).is_none_or(|&key| key < byte));
            let tail = &rows[lower..];
            let upper = tail.partition_point(|row| row.spelling.get(depth) == Some(&byte));
            return &tail[..upper];
        }
        // Every caller supplies a subslice of this dictionary. These offsets
        // stay valid for the cache's entire immutable resource lifetime.
        let start = (rows.as_ptr() as usize - self.dictionary.as_ptr() as usize)
            / std::mem::size_of::<Entry<'_>>();
        let key = Key {
            start,
            count: rows.len(),
            depth,
            byte,
        };
        if let Some(&(start, end)) = self.cache.as_ref().and_then(|cache| cache.get(&key)) {
            return &self.dictionary[start..end];
        }
        let lower =
            rows.partition_point(|row| row.spelling.get(depth).is_none_or(|&key| key < byte));
        let tail = &rows[lower..];
        let upper = tail.partition_point(|row| row.spelling.get(depth) == Some(&byte));
        if let Some(cache) = &mut self.cache {
            cache.insert(key, (start + lower, start + lower + upper));
        }
        &tail[..upper]
    }
}
