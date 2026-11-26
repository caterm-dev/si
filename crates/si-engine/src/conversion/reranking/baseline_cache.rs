use std::collections::{BTreeMap, HashMap};

/// Exact output bytes map to immutable, unconditional sequence log scores.
/// No spelling, host context, personal preferences or candidate lists are kept.
pub(super) struct BaselineCache {
    scores: HashMap<String, (f64, u64)>,
    recency: BTreeMap<u64, String>,
    clock: u64,
    capacity: usize,
}

impl BaselineCache {
    pub(super) fn new(capacity: usize) -> Self {
        Self {
            scores: HashMap::new(),
            recency: BTreeMap::new(),
            clock: 0,
            capacity,
        }
    }

    fn tick(&mut self) -> u64 {
        if self.clock == u64::MAX {
            self.scores.clear();
            self.recency.clear();
            self.clock = 0;
        }
        self.clock += 1;
        self.clock
    }

    pub(super) fn get(&mut self, text: &str) -> Option<f64> {
        let tick = self.tick();
        let (score, previous) = self.scores.get_mut(text)?;
        self.recency.remove(previous);
        *previous = tick;
        self.recency.insert(tick, text.to_owned());
        Some(*score)
    }

    pub(super) fn insert(&mut self, text: &str, score: f64) {
        let tick = self.tick();
        if let Some((_, previous)) = self.scores.insert(text.to_owned(), (score, tick)) {
            self.recency.remove(&previous);
        }
        self.recency.insert(tick, text.to_owned());
        if self.scores.len() > self.capacity {
            let (_, oldest) = self.recency.pop_first().expect("nonempty score cache");
            self.scores.remove(&oldest);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::BaselineCache;

    #[test]
    fn hits_refresh_recency_and_replacements_do_not_consume_capacity() {
        let mut cache = BaselineCache::new(2);
        cache.insert("甲", -1.0);
        cache.insert("乙", -2.0);
        assert_eq!(cache.get("甲"), Some(-1.0));
        cache.insert("丙", -3.0);
        assert_eq!(cache.get("乙"), None);
        cache.insert("甲", -4.0);
        assert_eq!(cache.get("丙"), Some(-3.0));
        assert_eq!(cache.get("甲"), Some(-4.0));
        assert_eq!(cache.scores.len(), cache.recency.len());
    }

    #[test]
    fn byte_distinct_outputs_remain_distinct_and_clock_overflow_discards_scores() {
        let mut cache = BaselineCache::new(2);
        cache.insert("é", -1.0);
        cache.insert("e\u{301}", -2.0);
        assert_eq!(cache.get("é"), Some(-1.0));
        assert_eq!(cache.get("e\u{301}"), Some(-2.0));
        cache.clock = u64::MAX;
        assert_eq!(cache.get("é"), None);
        assert!(cache.scores.is_empty() && cache.recency.is_empty());
        cache.insert("甲", -3.0);
        assert_eq!(cache.get("甲"), Some(-3.0));
    }
}
