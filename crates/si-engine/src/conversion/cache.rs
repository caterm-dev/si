//! Bounded, resource-local memoization. Entries never contain composition text.

use std::hash::{Hash, Hasher};

/// Direct-mapped memo for integer-only dictionary identities. A collision just
/// replaces an optimization entry; full key equality is always required.
pub(super) struct Memo<K, V> {
    rows: Vec<Option<(K, V)>>,
    capacity: usize,
}

impl<K: Copy + Eq + Hash, V> Memo<K, V> {
    pub(super) fn new(capacity: usize) -> Self {
        debug_assert!(capacity.is_power_of_two());
        Self {
            rows: Vec::new(),
            capacity,
        }
    }

    fn index(&self, key: &K) -> usize {
        let mut hash = IdHasher(0);
        key.hash(&mut hash);
        hash.finish() as usize & (self.capacity - 1)
    }

    pub(super) fn get(&self, key: &K) -> Option<&V> {
        self.rows
            .get(self.index(key))?
            .as_ref()
            .filter(|(stored, _)| stored == key)
            .map(|(_, value)| value)
    }

    pub(super) fn insert(&mut self, key: K, value: V) {
        let index = self.index(&key);
        if self.rows.is_empty() {
            self.rows.resize_with(self.capacity, || None);
        }
        self.rows[index] = Some((key, value));
    }
}

/// Noncryptographic hash for internal numeric IDs and ranges only. It never
/// decides candidate identity or ranking; cache hits still compare full keys.
#[derive(Default)]
pub(super) struct IdHasher(u64);

impl Hasher for IdHasher {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for chunk in bytes.chunks(8) {
            let mut word = [0; 8];
            word[..chunk.len()].copy_from_slice(chunk);
            self.write_u64(u64::from_le_bytes(word));
        }
    }

    fn write_u64(&mut self, value: u64) {
        self.0 = (self.0.rotate_left(5) ^ value).wrapping_mul(0x517cc1b727220a95);
    }
    fn write_usize(&mut self, value: usize) {
        self.write_u64(value as u64);
    }
    fn write_u32(&mut self, value: u32) {
        self.write_u64(u64::from(value));
    }
    fn write_u8(&mut self, value: u8) {
        self.write_u64(u64::from(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Copy, Eq, PartialEq)]
    struct Colliding(u32);

    impl Hash for Colliding {
        fn hash<H: Hasher>(&self, state: &mut H) {
            state.write_u8(0);
        }
    }

    #[test]
    fn collisions_and_replacements_cannot_return_another_identity() {
        let mut memo = Memo::new(4);
        memo.insert(Colliding(1), "first");
        assert_eq!(memo.get(&Colliding(1)), Some(&"first"));
        memo.insert(Colliding(2), "second");
        assert_eq!(memo.get(&Colliding(1)), None);
        assert_eq!(memo.get(&Colliding(2)), Some(&"second"));
        for id in 3..100 {
            memo.insert(Colliding(id), "replacement");
        }
        assert_eq!(memo.rows.len(), 4);
        assert_eq!(memo.get(&Colliding(2)), None);
        assert_eq!(memo.get(&Colliding(99)), Some(&"replacement"));
    }
}
