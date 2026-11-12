use std::fs;
use std::io;
use std::path::Path;

use si_lexicon::IndexId;

use super::source::{bad_line, parse_count, strip_bom};

const FORCE_COUNT_SLOT: usize = 7;
const FIELDS: [(&str, u64, u64); 8] = [
    ("pinyin_index", 0, u32::MAX as u64),
    ("min_count_2", 1, u64::MAX),
    ("min_prefix_percent_2", 0, 100),
    ("min_count_3", 1, u64::MAX),
    ("min_prefix_percent_3", 0, 100),
    ("min_count_4", 1, u64::MAX),
    ("min_prefix_percent_4", 0, 100),
    ("force_count", 0, u64::MAX),
];

/// Validated offline vocabulary learning settings.
pub struct LearningConfig {
    pub(super) pinyin_index: IndexId,
    pub(super) orders: [OrderThreshold; 3],
}

#[derive(Clone, Copy)]
pub(super) struct OrderThreshold {
    min_count: u64,
    min_prefix_percent: u64,
    force_count: Option<u64>,
}

impl OrderThreshold {
    pub(super) fn qualifies(self, count: u64, prefix_total: u128) -> bool {
        self.force_count.is_some_and(|limit| count > limit)
            || (count >= self.min_count
                && u128::from(count) * 100 >= prefix_total * u128::from(self.min_prefix_percent))
    }
}

impl LearningConfig {
    /// Read the learning thresholds and optional high-count rule.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        let text = fs::read_to_string(path).map_err(|error| {
            io::Error::new(error.kind(), format!("{}: {error}", path.display()))
        })?;
        let mut values = [None; FIELDS.len()];
        for (index, line) in strip_bom(&text).lines().enumerate() {
            let line = line.split_once('#').map_or(line, |(value, _)| value).trim();
            if line.is_empty() {
                continue;
            }
            let error = |message| bad_line(path, index + 1, message);
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| error("expected a learning setting in key = value form"))?;
            let slot = FIELDS
                .iter()
                .position(|(name, _, _)| *name == key.trim())
                .ok_or_else(|| error("unknown learning setting"))?;
            let (name, lower, upper) = FIELDS[slot];
            let value = parse_count(value.trim())
                .filter(|value| (lower..=upper).contains(value))
                .ok_or_else(|| {
                    bad_line(
                        path,
                        index + 1,
                        format!("{name} must be an integer in {lower}..={upper}"),
                    )
                })?;
            if values[slot].replace(value).is_some() {
                return Err(error("duplicate learning setting"));
            }
        }

        let value = |slot: usize| {
            values[slot].ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!(
                        "{}: missing learning setting {}",
                        path.display(),
                        FIELDS[slot].0
                    ),
                )
            })
        };
        let threshold = |slot| {
            Ok::<_, io::Error>(OrderThreshold {
                min_count: value(slot)?,
                min_prefix_percent: value(slot + 1)?,
                force_count: values[FORCE_COUNT_SLOT],
            })
        };
        Ok(Self {
            pinyin_index: IndexId(value(0)? as u32),
            orders: [threshold(1)?, threshold(3)?, threshold(5)?],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::OrderThreshold;

    #[test]
    fn prefix_comparison_is_exact_when_totals_exceed_u64() {
        let threshold = OrderThreshold {
            min_count: 1,
            min_prefix_percent: 50,
            force_count: None,
        };
        let count = u64::MAX;
        let total = u128::from(count) * 2;
        assert!(threshold.qualifies(count, total));
        assert!(!threshold.qualifies(count, total + 1));
    }
}
