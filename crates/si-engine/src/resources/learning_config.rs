use std::cmp::Ordering;
use std::fs;
use std::io;
use std::path::Path;

use si_gram::{GramOrder, MAX_ORDER};
use si_lexicon::IndexId;

use super::source::{bad_line, parse_count, strip_bom};

const FIELDS: [(&str, u64, u64); 13] = [
    ("pinyin_index", 0, u32::MAX as u64),
    ("min_count_2", 1, u64::MAX),
    ("min_forward_percent_2", 0, 100),
    ("min_backward_percent_2", 0, 100),
    ("min_lift_2", 0, u32::MAX as u64),
    // Accept the previous configuration format while only learning bigrams.
    ("min_count_3", 1, u64::MAX),
    ("min_forward_percent_3", 0, 100),
    ("min_backward_percent_3", 0, 100),
    ("min_lift_3", 0, u32::MAX as u64),
    ("min_count_4", 1, u64::MAX),
    ("min_forward_percent_4", 0, 100),
    ("min_backward_percent_4", 0, 100),
    ("min_lift_4", 0, u32::MAX as u64),
];

/// Validated offline vocabulary learning settings.
pub struct LearningConfig {
    pub(super) pinyin_index: IndexId,
    pub(super) min_count: u64,
    min_forward_percent: u64,
    min_backward_percent: u64,
    min_lift: u64,
}

impl LearningConfig {
    pub(super) fn qualifies(&self, count: u64, left: u128, right: u128, total: u128) -> bool {
        let count = u128::from(count);
        count * 100 >= left * u128::from(self.min_forward_percent)
            && count * 100 >= right * u128::from(self.min_backward_percent)
            && (self.min_lift == 0
                || compare_ratios(count, left, right * u128::from(self.min_lift), total)
                    != Ordering::Less)
    }
}

fn compare_ratios(mut a: u128, mut b: u128, mut c: u128, mut d: u128) -> Ordering {
    if let (Some(left), Some(right)) = (a.checked_mul(d), c.checked_mul(b)) {
        return left.cmp(&right);
    }
    // Comparing continued-fraction terms avoids overflowing on large totals.
    let mut reverse = false;
    loop {
        let quotients = (a / b).cmp(&(c / d));
        let (left, right) = (a % b, c % d);
        let order = if quotients != Ordering::Equal {
            quotients
        } else if left == 0 || right == 0 {
            left.cmp(&right)
        } else {
            (a, b, c, d) = (b, left, d, right);
            reverse = !reverse;
            continue;
        };
        return if reverse { order.reverse() } else { order };
    }
}

impl LearningConfig {
    /// Read the minimum sample and association thresholds for bigrams.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        let text = read_config(path)?;
        if is_sectioned(&text) {
            return Ok(SiConfig::parse(path, &text)?.base_learning);
        }
        parse_legacy(path, &text)
    }
}

/// Separate thresholds for learning from a user's smaller corpus.
pub struct UserLearningConfig(pub(super) LearningConfig);

impl Default for UserLearningConfig {
    fn default() -> Self {
        SiConfig::default().user_learning
    }
}

impl UserLearningConfig {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        let text = read_config(path)?;
        if is_sectioned(&text) {
            return Ok(SiConfig::parse(path, &text)?.user_learning);
        }
        Self::validate(parse_legacy(path, &text)?)
    }

    fn validate(config: LearningConfig) -> io::Result<Self> {
        if config.pinyin_index != IndexId(0) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "user learning requires Pinyin index 0",
            ));
        }
        Ok(Self(config))
    }
}

/// Settings shared by the offline corpus and vocabulary workflows.
pub struct SiConfig {
    pub base_max_order: GramOrder,
    pub user_max_order: GramOrder,
    pub base_learning: LearningConfig,
    pub user_learning: UserLearningConfig,
}

impl Default for SiConfig {
    fn default() -> Self {
        Self::parse(
            Path::new("config/si.conf"),
            include_str!("../../../../config/si.conf"),
        )
        .expect("valid bundled SI configuration")
    }
}

impl SiConfig {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        Self::parse(path, &read_config(path)?)
    }

    fn parse(path: &Path, text: &str) -> io::Result<Self> {
        let mut sections = [None, None];
        let mut current = None;
        for (line_number, line) in settings(text) {
            let section = match line {
                "[base]" => Some(0),
                "[user]" => Some(1),
                _ => None,
            };
            if let Some(section) = section {
                if sections[section].replace(Section::default()).is_some() {
                    return Err(bad_line(
                        path,
                        line_number,
                        "duplicate configuration section",
                    ));
                }
                current = Some(section);
                continue;
            }
            let Some(index) = current else {
                return Err(bad_line(path, line_number, "expected [base] or [user]"));
            };
            let section = sections[index]
                .as_mut()
                .expect("selected configuration section");
            let (key, value) = split_setting(path, line_number, line)?;
            if key == "max_order" {
                let order = parse_count(value)
                    .and_then(|order| GramOrder::try_from(order).ok())
                    .ok_or_else(|| {
                        bad_line(
                            path,
                            line_number,
                            format!("max_order must be an integer in 2..={MAX_ORDER}"),
                        )
                    })?;
                if section.max_order.replace(order).is_some() {
                    return Err(bad_line(path, line_number, "duplicate max_order"));
                }
            } else {
                section.set_learning(path, line_number, key, value)?;
            }
        }
        let [base, user] = sections;
        let finish = |name: &str, section: Option<Section>| {
            let section = section.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{}: missing {name} section", path.display()),
                )
            })?;
            let order = section
                .max_order
                .ok_or_else(|| missing(path, name, "max_order"))?;
            Ok::<_, io::Error>((order, section.learning(path, name)?))
        };
        let (base_max_order, base_learning) = finish("[base]", base)?;
        let (user_max_order, user_learning) = finish("[user]", user)?;
        Ok(Self {
            base_max_order,
            user_max_order,
            base_learning,
            user_learning: UserLearningConfig::validate(user_learning)?,
        })
    }
}

#[derive(Default)]
struct Section {
    max_order: Option<GramOrder>,
    values: [Option<u64>; FIELDS.len()],
}

impl Section {
    fn set_learning(&mut self, path: &Path, line: usize, key: &str, value: &str) -> io::Result<()> {
        let slot = FIELDS
            .iter()
            .position(|(name, _, _)| *name == key)
            .ok_or_else(|| bad_line(path, line, "unknown learning setting"))?;
        let (name, lower, upper) = FIELDS[slot];
        let value = parse_count(value)
            .filter(|value| (lower..=upper).contains(value))
            .ok_or_else(|| {
                bad_line(
                    path,
                    line,
                    format!("{name} must be an integer in {lower}..={upper}"),
                )
            })?;
        if self.values[slot].replace(value).is_some() {
            return Err(bad_line(path, line, "duplicate learning setting"));
        }
        Ok(())
    }

    fn learning(self, path: &Path, section: &str) -> io::Result<LearningConfig> {
        let value =
            |slot: usize| self.values[slot].ok_or_else(|| missing(path, section, FIELDS[slot].0));
        Ok(LearningConfig {
            pinyin_index: IndexId(value(0)? as u32),
            min_count: value(1)?,
            min_forward_percent: value(2)?,
            min_backward_percent: value(3)?,
            min_lift: value(4)?,
        })
    }
}

fn read_config(path: &Path) -> io::Result<String> {
    fs::read_to_string(path)
        .map_err(|error| io::Error::new(error.kind(), format!("{}: {error}", path.display())))
}

fn settings(text: &str) -> impl Iterator<Item = (usize, &str)> {
    strip_bom(text)
        .lines()
        .enumerate()
        .filter_map(|(index, line)| {
            let line = line.split_once('#').map_or(line, |(value, _)| value).trim();
            (!line.is_empty()).then_some((index + 1, line))
        })
}

fn is_sectioned(text: &str) -> bool {
    settings(text)
        .next()
        .is_some_and(|(_, line)| line.starts_with('['))
}

fn split_setting<'a>(path: &Path, number: usize, line: &'a str) -> io::Result<(&'a str, &'a str)> {
    line.split_once('=')
        .map(|(key, value)| (key.trim(), value.trim()))
        .ok_or_else(|| bad_line(path, number, "expected a setting in key = value form"))
}

fn missing(path: &Path, section: &str, field: &str) -> io::Error {
    let label = if section.is_empty() {
        "learning"
    } else {
        section
    };
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{}: missing {label} setting {field}", path.display()),
    )
}

fn parse_legacy(path: &Path, text: &str) -> io::Result<LearningConfig> {
    let mut section = Section::default();
    for (line_number, line) in settings(text) {
        let (key, value) = split_setting(path, line_number, line)?;
        section.set_learning(path, line_number, key, value)?;
    }
    section.learning(path, "")
}

#[cfg(test)]
mod tests {
    use super::{GramOrder, IndexId, LearningConfig, Ordering, SiConfig, compare_ratios};

    #[test]
    fn bundled_config_preserves_separate_base_and_user_thresholds() {
        let config = SiConfig::default();
        assert_eq!(config.base_max_order, GramOrder::Fourgram);
        assert_eq!(config.user_max_order, GramOrder::Fourgram);
        assert_eq!(config.base_learning.min_count, 40_000);
        assert_eq!(config.base_learning.min_forward_percent, 4);
        assert_eq!(config.base_learning.min_backward_percent, 4);
        assert_eq!(config.base_learning.min_lift, 10);
        assert_eq!(config.user_learning.0.min_count, 5);
        assert_eq!(config.user_learning.0.min_forward_percent, 30);
        assert_eq!(config.user_learning.0.min_backward_percent, 30);
        assert_eq!(config.user_learning.0.min_lift, 2);
    }

    #[test]
    fn association_comparisons_are_inclusive_and_exact() {
        let threshold = LearningConfig {
            pinyin_index: IndexId(0),
            min_count: 1,
            min_forward_percent: 50,
            min_backward_percent: 25,
            min_lift: 2,
        };
        let count = u64::MAX;
        let left = u128::from(count) * 2;
        let right = u128::from(count) * 4;
        let total = u128::from(count) * 16;
        assert!(threshold.qualifies(count, left, right, total));
        assert!(!threshold.qualifies(count, left + 1, right, total));
        assert!(!threshold.qualifies(count, left, right + 1, total));
        assert!(!threshold.qualifies(count, left, right, total - 1));
        let max = u128::MAX;
        assert_eq!(
            compare_ratios(max - 1, max, max - 2, max - 1),
            Ordering::Greater
        );
        assert_eq!(
            compare_ratios(max - 2, max - 1, max - 1, max),
            Ordering::Less
        );
    }
}
