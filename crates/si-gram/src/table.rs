use std::collections::HashMap;
use std::ops::Range;

use crate::BuildError;

pub(crate) struct Table<const N: usize> {
    pub(crate) keys: Vec<[u32; N]>,
    pub(crate) counts: Vec<u64>,
    shift: u32,
    bucket_ends: Vec<u32>,
}

impl<const N: usize> Table<N> {
    pub(crate) fn max_word_ordinal(&self) -> Option<u32> {
        self.keys.iter().flatten().copied().max()
    }

    pub(crate) fn into_counts(self) -> HashMap<[u32; N], u64> {
        std::iter::zip(self.keys, self.counts).collect()
    }

    pub(crate) fn from_counts(counts: HashMap<[u32; N], u64>) -> Result<Self, BuildError> {
        u32::try_from(counts.len()).map_err(|_| BuildError::CapacityExceeded)?;
        let mut rows: Vec<_> = counts.into_iter().collect();
        rows.sort_unstable_by_key(|&(key, _)| key);
        let (keys, counts) = rows.into_iter().unzip();
        Ok(Self::from_sorted(keys, counts))
    }

    pub(crate) fn from_sorted(keys: Vec<[u32; N]>, counts: Vec<u64>) -> Self {
        // A small directory narrows each binary search to one range of first word IDs.
        // Derive it at load time, so it adds no bytes to the file.
        let mut shift = 0;
        let mut bucket_ends = Vec::new();
        if let Some(last) = keys.last() {
            let bits = u32::BITS - last[0].leading_zeros();
            let buckets = (keys.len() / 32).clamp(1, 4096);
            shift = bits.saturating_sub(buckets.ilog2()).min(u32::BITS - 1);
            bucket_ends = (0..=(last[0] >> shift))
                .map(|bucket| keys.partition_point(|key| key[0] >> shift <= bucket) as u32)
                .collect();
        }
        Self {
            keys,
            counts,
            shift,
            bucket_ends,
        }
    }

    pub(crate) fn prune(&mut self, min_count: u64) -> usize {
        let Some(mut retained) = self.counts.iter().position(|&count| count < min_count) else {
            return 0;
        };
        let len = self.counts.len();
        for index in retained + 1..len {
            let count = self.counts[index];
            if count >= min_count {
                self.keys[retained] = self.keys[index];
                self.counts[retained] = count;
                retained += 1;
            }
        }
        self.keys.truncate(retained);
        self.counts.truncate(retained);
        *self = Self::from_sorted(
            std::mem::take(&mut self.keys),
            std::mem::take(&mut self.counts),
        );
        len - retained
    }

    pub(crate) fn count(&self, key: [u32; N]) -> Option<u64> {
        let range = self.bucket(key[0]);
        let offset = self.keys[range.clone()].binary_search(&key).ok()?;
        Some(self.counts[range.start + offset])
    }

    pub(crate) fn prefix<const H: usize>(&self, history: [u32; H]) -> (&[[u32; N]], &[u64]) {
        let range = self.bucket(history[0]);
        let keys = &self.keys[range.clone()];
        let start = keys.partition_point(|key| key[..H] < history[..]);
        let end = start + keys[start..].partition_point(|key| key[..H] == history);
        (
            &keys[start..end],
            &self.counts[range.start + start..range.start + end],
        )
    }

    fn bucket(&self, first: u32) -> Range<usize> {
        let bucket = (first >> self.shift) as usize;
        let Some(&end) = self.bucket_ends.get(bucket) else {
            return 0..0;
        };
        let start = if bucket == 0 {
            0
        } else {
            self.bucket_ends[bucket - 1]
        };
        start as usize..end as usize
    }
}
