//! Validated, immutable conversion tuning. Source defaults live only in config/si.conf.
use super::source::{bad_line, strip_bom};
use std::collections::BTreeMap;
use std::fmt::Display;
use std::io;
use std::path::Path;
use std::str::FromStr;

macro_rules! settings_group {
    ($name:ident, $section:literal, { $($field:ident: $ty:ty = ($lower:expr, $upper:expr)),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, PartialEq)]
        pub struct $name { $(pub(crate) $field: $ty),+ }
        impl $name {
            fn parse(mut section: Section<'_>) -> io::Result<Self> {
                let result = Self { $($field: section.number(stringify!($field), $lower, $upper)?),+ };
                section.finish()?;
                Ok(result)
            }
        }
    }
}

settings_group!(FieldContextConfig, "field_context", {
    preceding_text_utf16_limit: usize = (1, 4096),
    segmentation_history_limit: usize = (1, 16),
    segmentation_temperature: f64 = (0.125, 32.000),
});

settings_group!(RerankerConfig, "local_model_ranking", {
    model_score_weight: f64 = (0.000, 4.000),
    model_score_gap_limit_bits: f64 = (0.000, 32.000),
    model_sentence_reward_cap_bits: f64 = (0.000, 32.000),
    model_candidate_limit: usize = (1, 64),
    model_context_token_limit: usize = (0, 128),
    model_candidate_token_limit: usize = (1, 64),
});

settings_group!(StatisticalScoringConfig, "statistical_scoring", {
    sentence_start_reward_limit_bits: f64 = (0.000, 8.000),
    base_word_gram_confidence_count: f64 = (0.001, 1000000.000),
    base_word_gram_reward_cap_bits: f64 = (0.000, 32.000),
    base_word_gram_backoff_discount: f64 = (0.000, 1.000),
    base_word_gram_backoff_penalty_cap_bits: f64 = (0.000, 8.000),
    base_word_gram_backoff_minimum_count: f64 = (0.000, 1000000.000),
    base_word_gram_backoff_confidence_count: f64 = (0.001, 1000000.000),
    user_word_gram_prior_count: f64 = (0.001, 1000000.000),
    word_gram_interpolation_weight_limit: f64 = (0.000, 0.800),
    user_unigram_prior_count: f64 = (0.001, 1000000.000),
    user_unigram_boost_weight_limit: f64 = (0.000, 0.800),
});

settings_group!(SpellingScoringConfig, "spelling_scoring", {
    completion_base_cost_bits: f64 = (0.000, 64.000),
    completion_missing_letter_cost_bits: f64 = (0.000, 16.000),
    pinyin_abbreviation_cost_bits: f64 = (0.000, 64.000),
});

settings_group!(PinyinCorrectionConfig, "pinyin_correction", {
    missing_key_correction_cost_bits: f64 = (0.125, 64.000),
    adjacent_swap_correction_cost_bits: f64 = (0.125, 64.000),
    neighbor_key_correction_cost_bits: f64 = (0.125, 64.000),
    conservative_correction_minimum_lead_bits: f64 = (0.000, 32.000),
    higher_recall_correction_minimum_lead_bits: f64 = (0.000, 32.000),
    higher_recall_context_backoff_cost_bits: f64 = (0.000, 32.000),
});

settings_group!(CandidateSearchConfig, "candidate_search", {
    full_search_beam_width: usize = (1, 64),
    preview_search_beam_width: usize = (1, 64),
    correction_search_beam_width: usize = (1, 64),
    completion_missing_letter_limit: usize = (0, 32),
    direct_completion_limit_per_language: usize = (1, 128),
});

impl PinyinCorrectionConfig {
    pub(crate) fn minimum_edit_cost(self) -> f64 {
        self.missing_key_correction_cost_bits
            .min(self.adjacent_swap_correction_cost_bits)
            .min(self.neighbor_key_correction_cost_bits)
    }
}

impl Default for RerankerConfig {
    fn default() -> Self {
        EngineConfig::default().local_model_ranking
    }
}

/// Immutable conversion settings, validated before indexing resources or processing input.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EngineConfig {
    pub field_context: FieldContextConfig,
    pub local_model_ranking: RerankerConfig,
    pub statistical_scoring: StatisticalScoringConfig,
    pub spelling_scoring: SpellingScoringConfig,
    pub pinyin_correction: PinyinCorrectionConfig,
    pub candidate_search: CandidateSearchConfig,
}
impl Default for EngineConfig {
    fn default() -> Self {
        Self::parse(
            Path::new("config/si.conf"),
            include_str!("../../../../config/si.conf"),
            None,
        )
        .expect("valid bundled engine configuration")
    }
}
impl EngineConfig {
    pub fn preceding_text_utf16_limit(self) -> usize {
        self.field_context.preceding_text_utf16_limit
    }

    pub(super) fn is_section(line: &str) -> bool {
        matches!(
            line,
            "[field_context]"
                | "[local_model_ranking]"
                | "[statistical_scoring]"
                | "[spelling_scoring]"
                | "[pinyin_correction]"
                | "[candidate_search]"
        )
    }
    pub(super) fn parse_overrides(path: &Path, text: &str) -> io::Result<Self> {
        Self::parse(path, text, Some(Self::default()))
    }
    fn parse(path: &Path, text: &str, defaults: Option<Self>) -> io::Result<Self> {
        let mut sections = sections(path, text)?;
        let result = Self {
            field_context: match sections.remove("field_context") {
                Some(section) => FieldContextConfig::parse(section)?,
                None => defaults
                    .map(|defaults| defaults.field_context)
                    .ok_or_else(|| missing(path, "field_context", "section"))?,
            },
            local_model_ranking: match sections.remove("local_model_ranking") {
                Some(section) => RerankerConfig::parse(section)?,
                None => defaults
                    .map(|defaults| defaults.local_model_ranking)
                    .ok_or_else(|| missing(path, "local_model_ranking", "section"))?,
            },
            statistical_scoring: match sections.remove("statistical_scoring") {
                Some(section) => StatisticalScoringConfig::parse(section)?,
                None => defaults
                    .map(|defaults| defaults.statistical_scoring)
                    .ok_or_else(|| missing(path, "statistical_scoring", "section"))?,
            },
            spelling_scoring: match sections.remove("spelling_scoring") {
                Some(section) => SpellingScoringConfig::parse(section)?,
                None => defaults
                    .map(|defaults| defaults.spelling_scoring)
                    .ok_or_else(|| missing(path, "spelling_scoring", "section"))?,
            },
            pinyin_correction: match sections.remove("pinyin_correction") {
                Some(section) => PinyinCorrectionConfig::parse(section)?,
                None => defaults
                    .map(|defaults| defaults.pinyin_correction)
                    .ok_or_else(|| missing(path, "pinyin_correction", "section"))?,
            },
            candidate_search: match sections.remove("candidate_search") {
                Some(section) => CandidateSearchConfig::parse(section)?,
                None => defaults
                    .map(|defaults| defaults.candidate_search)
                    .ok_or_else(|| missing(path, "candidate_search", "section"))?,
            },
        };
        if result.candidate_search.preview_search_beam_width
            > result.candidate_search.full_search_beam_width
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "{}: preview_search_beam_width must not exceed full_search_beam_width",
                    path.display()
                ),
            ));
        }
        if result
            .pinyin_correction
            .higher_recall_correction_minimum_lead_bits
            > result
                .pinyin_correction
                .conservative_correction_minimum_lead_bits
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "{}: higher_recall_correction_minimum_lead_bits must not exceed conservative_correction_minimum_lead_bits",
                    path.display()
                ),
            ));
        }
        Ok(result)
    }
}
struct Section<'a> {
    path: &'a Path,
    name: &'a str,
    values: BTreeMap<&'a str, (usize, &'a str)>,
}
impl Section<'_> {
    fn number<T: FromStr + PartialOrd + Display>(
        &mut self,
        key: &str,
        lower: T,
        upper: T,
    ) -> io::Result<T> {
        let (line, text) = self
            .values
            .remove(key)
            .ok_or_else(|| missing(self.path, self.name, key))?;
        text.parse::<T>()
            .ok()
            .filter(|value| *value >= lower && *value <= upper)
            .ok_or_else(|| {
                bad_line(
                    self.path,
                    line,
                    format!(
                        "[{0}].{key} must be {1} in {lower}..={upper}",
                        self.name,
                        if std::any::type_name::<T>() == "usize" {
                            "an integer"
                        } else {
                            "finite"
                        }
                    ),
                )
            })
    }
    fn finish(self) -> io::Result<()> {
        if let Some((key, (line, _))) = self.values.first_key_value() {
            return Err(bad_line(
                self.path,
                *line,
                format!("unknown [{}] setting {key}", self.name),
            ));
        }
        Ok(())
    }
}
fn missing(path: &Path, section: &str, key: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{}: missing [{section}] {key}", path.display()),
    )
}
fn sections<'a>(path: &'a Path, text: &'a str) -> io::Result<BTreeMap<&'a str, Section<'a>>> {
    let mut result = BTreeMap::<&str, Section<'a>>::new();
    let mut selected = None;
    for (index, line) in strip_bom(text).lines().enumerate() {
        let line = line.split('#').next().unwrap_or_default().trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') {
            selected = if EngineConfig::is_section(line) {
                let name = &line[1..line.len() - 1];
                if result
                    .insert(
                        name,
                        Section {
                            path,
                            name,
                            values: BTreeMap::new(),
                        },
                    )
                    .is_some()
                {
                    return Err(bad_line(
                        path,
                        index + 1,
                        format!("duplicate [{name}] section"),
                    ));
                }
                Some(name)
            } else {
                None
            };
        } else if let Some(name) = selected {
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| bad_line(path, index + 1, "expected key = value"))?;
            let (key, value) = (key.trim(), value.trim());
            if result
                .get_mut(name)
                .unwrap()
                .values
                .insert(key, (index + 1, value))
                .is_some()
            {
                return Err(bad_line(
                    path,
                    index + 1,
                    format!("duplicate [{name}] setting {key}"),
                ));
            }
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::EngineConfig;
    use std::path::Path;
    const BUNDLED: &str = include_str!("../../../../config/si.conf");
    fn change(key: &str, value: &str) -> String {
        BUNDLED
            .lines()
            .map(|line| {
                if line
                    .split_once('=')
                    .is_some_and(|(name, _)| name.trim() == key)
                {
                    format!("{key} = {value}")
                } else {
                    line.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
    fn parse(text: &str) -> std::io::Result<EngineConfig> {
        EngineConfig::parse_overrides(Path::new("fixture.conf"), text)
    }
    #[test]
    fn every_engine_parameter_enforces_its_documented_numeric_range() {
        // Bounds are the public tuning contract, including exact endpoint acceptance.
        for (key, minimum, maximum, below, above, integer) in [
            ("preceding_text_utf16_limit", "1", "4096", "0", "4097", true),
            ("segmentation_history_limit", "1", "16", "0", "17", true),
            (
                "segmentation_temperature",
                "0.125",
                "32",
                "0.0625",
                "33",
                false,
            ),
            ("model_score_weight", "0", "4", "-0.01", "5", false),
            (
                "model_score_gap_limit_bits",
                "0",
                "32",
                "-0.01",
                "33",
                false,
            ),
            ("model_candidate_limit", "1", "64", "0", "65", true),
            (
                "model_sentence_reward_cap_bits",
                "0",
                "32",
                "-0.01",
                "33",
                false,
            ),
            ("model_context_token_limit", "0", "128", "-1", "129", true),
            ("model_candidate_token_limit", "1", "64", "0", "65", true),
            (
                "sentence_start_reward_limit_bits",
                "0",
                "8",
                "-0.01",
                "9",
                false,
            ),
            (
                "base_word_gram_confidence_count",
                "0.001",
                "1000000",
                "0.0005",
                "1000001",
                false,
            ),
            (
                "base_word_gram_reward_cap_bits",
                "0",
                "32",
                "-0.01",
                "33",
                false,
            ),
            (
                "base_word_gram_backoff_discount",
                "0",
                "1",
                "-0.01",
                "1.01",
                false,
            ),
            (
                "base_word_gram_backoff_penalty_cap_bits",
                "0",
                "8",
                "-0.01",
                "9",
                false,
            ),
            (
                "base_word_gram_backoff_minimum_count",
                "0",
                "1000000",
                "-0.01",
                "1000001",
                false,
            ),
            (
                "base_word_gram_backoff_confidence_count",
                "0.001",
                "1000000",
                "0.0005",
                "1000001",
                false,
            ),
            (
                "user_word_gram_prior_count",
                "0.001",
                "1000000",
                "0.0005",
                "1000001",
                false,
            ),
            (
                "word_gram_interpolation_weight_limit",
                "0",
                "0.8",
                "-0.01",
                "1.8",
                false,
            ),
            (
                "user_unigram_prior_count",
                "0.001",
                "1000000",
                "0.0005",
                "1000001",
                false,
            ),
            (
                "user_unigram_boost_weight_limit",
                "0",
                "0.8",
                "-0.01",
                "1.8",
                false,
            ),
            ("completion_base_cost_bits", "0", "64", "-0.01", "65", false),
            (
                "completion_missing_letter_cost_bits",
                "0",
                "16",
                "-0.01",
                "17",
                false,
            ),
            (
                "pinyin_abbreviation_cost_bits",
                "0",
                "64",
                "-0.01",
                "65",
                false,
            ),
            (
                "missing_key_correction_cost_bits",
                "0.125",
                "64",
                "0.0625",
                "65",
                false,
            ),
            (
                "adjacent_swap_correction_cost_bits",
                "0.125",
                "64",
                "0.0625",
                "65",
                false,
            ),
            (
                "neighbor_key_correction_cost_bits",
                "0.125",
                "64",
                "0.0625",
                "65",
                false,
            ),
            (
                "conservative_correction_minimum_lead_bits",
                "0",
                "32",
                "-0.01",
                "33",
                false,
            ),
            (
                "higher_recall_correction_minimum_lead_bits",
                "0",
                "32",
                "-0.01",
                "33",
                false,
            ),
            (
                "higher_recall_context_backoff_cost_bits",
                "0",
                "32",
                "-0.01",
                "33",
                false,
            ),
            ("full_search_beam_width", "1", "64", "0", "65", true),
            ("preview_search_beam_width", "1", "64", "0", "65", true),
            ("correction_search_beam_width", "1", "64", "0", "65", true),
            (
                "completion_missing_letter_limit",
                "0",
                "32",
                "-1",
                "33",
                true,
            ),
            (
                "direct_completion_limit_per_language",
                "1",
                "128",
                "0",
                "129",
                true,
            ),
        ] {
            for value in [minimum, maximum] {
                let mut text = change(key, value);
                if key == "full_search_beam_width" {
                    text = text.replace(
                        "preview_search_beam_width = 6",
                        "preview_search_beam_width = 1",
                    );
                }
                if key == "preview_search_beam_width" {
                    text =
                        text.replace("full_search_beam_width = 24", "full_search_beam_width = 64");
                }
                if key == "higher_recall_correction_minimum_lead_bits" {
                    text = text.replace(
                        "conservative_correction_minimum_lead_bits = 2",
                        "conservative_correction_minimum_lead_bits = 32",
                    );
                }
                assert!(parse(&text).is_ok(), "valid endpoint {key}={value}");
            }
            for value in [below, above, "NaN", "inf", "-inf", "wrong"] {
                let error = parse(&change(key, value)).unwrap_err().to_string();
                assert!(error.contains(key), "{key}={value}: {error}");
                assert!(error.contains("fixture.conf"));
            }
            if integer {
                assert!(parse(&change(key, "1.5")).is_err(), "{key}");
            }
            let duplicate = change(key, &format!("{minimum}\n{key} = {maximum}"));
            assert!(
                parse(&duplicate)
                    .unwrap_err()
                    .to_string()
                    .contains("duplicate"),
                "{key}"
            );
        }
    }
    #[test]
    fn engine_configuration_rejects_inconsistent_limits_and_unknown_or_missing_fields() {
        for (key, value) in [
            ("preview_search_beam_width", "25"),
            ("higher_recall_correction_minimum_lead_bits", "3"),
        ] {
            assert!(
                parse(&change(key, value))
                    .unwrap_err()
                    .to_string()
                    .contains("must not exceed")
            );
        }
        for section in [
            "field_context",
            "local_model_ranking",
            "statistical_scoring",
            "spelling_scoring",
            "pinyin_correction",
            "candidate_search",
        ] {
            let unknown = BUNDLED.replace(
                &format!("[{section}]"),
                &format!("[{section}]\nunknown_setting = 1"),
            );
            assert!(parse(&unknown).unwrap_err().to_string().contains("unknown"));
            let duplicate = format!("{BUNDLED}\n[{section}]\n");
            assert!(
                parse(&duplicate)
                    .unwrap_err()
                    .to_string()
                    .contains("duplicate")
            );
        }
        let missing = BUNDLED.replace("full_search_beam_width = 24", "");
        assert!(
            parse(&missing)
                .unwrap_err()
                .to_string()
                .contains("missing [candidate_search] full_search_beam_width")
        );
        let legacy = &BUNDLED[BUNDLED.find("[base]").unwrap()..];
        assert_eq!(parse(legacy).unwrap(), EngineConfig::default());
    }
}
