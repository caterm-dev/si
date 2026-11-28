mod baseline_cache;

use std::io;
use std::path::Path;
use std::sync::Mutex;

use si_neural::Reranker;

use super::{Candidate, CandidateLanguage};
use crate::resources::RerankerConfig;
use baseline_cache::BaselineCache;

const BASELINE_CACHE_CAPACITY: usize = 4_096;

/// Immutable local character scorer shared across base and user engines.
pub struct SmallReranker {
    model: Reranker,
    config: RerankerConfig,
    baselines: Mutex<BaselineCache>,
}

impl SmallReranker {
    pub fn open(path: &Path) -> io::Result<Self> {
        Self::open_with_config(path, RerankerConfig::default())
    }

    /// Load a model with parameters already validated by SI configuration parsing.
    pub fn open_with_config(path: &Path, config: RerankerConfig) -> io::Result<Self> {
        Ok(Self {
            model: Reranker::open(path)?,
            config,
            baselines: Mutex::new(BaselineCache::new(BASELINE_CACHE_CAPACITY)),
        })
    }

    pub(super) fn candidate_limit(&self) -> usize {
        self.config.model_candidate_limit
    }

    pub(super) fn candidate_byte_limit(&self) -> usize {
        self.config.model_candidate_token_limit * 4
    }

    /// Score a supplied model pool with the same adjustments used by conversion.
    pub fn bonuses(&self, context: &str, texts: &[&str]) -> Option<Vec<f64>> {
        if self.config.model_score_weight == 0.0 {
            return Some(vec![0.0; texts.len()]);
        }
        if context.is_empty() || self.config.model_context_token_limit == 0 {
            return self.sentence_bonuses(texts);
        }
        let conditioned = self
            .model
            .bounded_sequence_scores(
                context,
                texts,
                self.config.model_context_token_limit,
                self.config.model_candidate_token_limit,
            )
            .ok()??;
        if conditioned.context_tokens_used == 0 {
            return self.sentence_bonuses(texts);
        }
        if self.config.model_score_gap_limit_bits == 0.0 {
            return Some(vec![0.0; texts.len()]);
        }
        let bits: Vec<_> = conditioned
            .scores
            .iter()
            .map(|score| score * std::f64::consts::LOG2_E)
            .collect();
        relative_adjustments(&bits, self.config)
    }

    /// Select the same rows as live conversion, before neural adjustment.
    pub fn pool_indices(
        rows: &[Candidate],
        input_bytes: usize,
        config: RerankerConfig,
    ) -> Vec<usize> {
        rows.iter()
            .enumerate()
            .take_while(|(_, row)| row.consumed_bytes == input_bytes)
            .filter(|(_, row)| {
                row.language != CandidateLanguage::Literal
                    && eligible(
                        row.personal,
                        row.verbatim,
                        row.is_corrected(),
                        row.completion,
                        row.text.len(),
                        config.model_candidate_token_limit * 4,
                    )
            })
            .take(config.model_candidate_limit)
            .map(|(index, _)| index)
            .collect()
    }

    /// Whole-input rows that receive a model score or the pool's worst adjustment.
    pub fn adjustment_indices(rows: &[Candidate], input_bytes: usize) -> Vec<usize> {
        rows.iter()
            .enumerate()
            .filter(|(_, row)| {
                row.consumed_bytes == input_bytes
                    && row.language != CandidateLanguage::Literal
                    && adjustment_eligible(row.personal, row.verbatim)
            })
            .map(|(index, _)| index)
            .collect()
    }

    fn sentence_bonuses(&self, texts: &[&str]) -> Option<Vec<f64>> {
        if self.config.model_sentence_reward_cap_bits == 0.0 {
            return Some(vec![0.0; texts.len()]);
        }
        // Empty neural context seeds the native BOS token. Score the complete
        // sequence, including its internal dependencies and byte-fallback tokens.
        let scores = self.baseline_scores(texts)?;
        sentence_adjustments(&scores, texts, self.config)
    }

    fn baseline_scores(&self, texts: &[&str]) -> Option<Vec<f64>> {
        let mut cached = self.baselines.try_lock().ok();
        let mut scores: Vec<_> = texts
            .iter()
            .map(|text| cached.as_mut().and_then(|cache| cache.get(text)))
            .collect();
        drop(cached);
        let missing: Vec<_> = scores
            .iter()
            .enumerate()
            .filter_map(|(i, score)| score.is_none().then_some(i))
            .collect();
        if !missing.is_empty() {
            let texts: Vec<_> = missing.iter().map(|&i| texts[i]).collect();
            // Cache locks never cover inference. Concurrent conversions can
            // compute locally rather than waiting on another request's cache.
            let baseline = self
                .model
                .bounded_sequence_scores("", &texts, 0, self.config.model_candidate_token_limit)
                .ok()??;
            if !baseline.scores.iter().all(|score| score.is_finite()) {
                return None;
            }
            let mut cached = self.baselines.try_lock().ok();
            for ((i, text), score) in missing.into_iter().zip(texts).zip(baseline.scores) {
                scores[i] = Some(score);
                if let Some(cache) = cached.as_mut() {
                    cache.insert(text, score);
                }
            }
        }
        scores.into_iter().collect()
    }
}

pub(super) fn eligible(
    personal: bool,
    verbatim: bool,
    corrected: bool,
    completion: bool,
    bytes: usize,
    byte_limit: usize,
) -> bool {
    !personal && !verbatim && !corrected && !completion && bytes <= byte_limit
}

pub(super) fn adjustment_eligible(personal: bool, verbatim: bool) -> bool {
    !personal && !verbatim
}

fn sentence_adjustments(
    scores: &[f64],
    texts: &[&str],
    config: RerankerConfig,
) -> Option<Vec<f64>> {
    if scores.len() != texts.len()
        || texts.iter().any(|text| text.is_empty())
        || scores.iter().any(|score| *score > 0.0)
    {
        return None;
    }
    let bits: Vec<_> = scores
        .iter()
        .map(|score| score * std::f64::consts::LOG2_E)
        .collect();
    bounded_adjustments(
        &bits,
        config.model_score_weight,
        config.model_sentence_reward_cap_bits,
    )
}

fn relative_adjustments(scores: &[f64], config: RerankerConfig) -> Option<Vec<f64>> {
    bounded_adjustments(
        scores,
        config.model_score_weight,
        config.model_score_gap_limit_bits,
    )
}

fn bounded_adjustments(scores: &[f64], weight: f64, limit: f64) -> Option<Vec<f64>> {
    if !scores.iter().all(|score| score.is_finite()) {
        return None;
    }
    let highest = scores.iter().copied().reduce(f64::max)?;
    Some(
        scores
            .iter()
            .map(|score| weight * (score - highest).max(-limit))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::{SmallReranker, relative_adjustments, sentence_adjustments};
    use crate::resources::RerankerConfig;

    #[test]
    fn cached_unconditional_scores_follow_exact_text_and_never_wait_for_the_cache() {
        let path =
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
        let model = SmallReranker::open(&path).unwrap();
        let expected = model.baseline_scores(&["肌酸", "计算"]).unwrap();
        let reversed = model.baseline_scores(&["计算", "肌酸"]).unwrap();
        assert_eq!(reversed, [expected[1], expected[0]]);
        let held = model.baselines.lock().unwrap();
        let uncached = model.baseline_scores(&["肌酸", "计算"]).unwrap();
        assert_eq!(uncached, expected);
        drop(held);
        let first = model.bonuses("我准备", &["吃肌酸", "吃计算"]).unwrap();
        assert_eq!(
            first,
            model.bonuses("我准备", &["吃肌酸", "吃计算"]).unwrap()
        );
        let empty = model.bonuses("", &["持有时间", "吃有时间"]).unwrap();
        assert!(empty[0] == 0.0 && empty[1] < 0.0);
        assert_eq!(empty, model.bonuses("", &["持有时间", "吃有时间"]).unwrap());
    }

    #[test]
    fn bos_adjustments_preserve_sequence_gaps_without_length_normalization() {
        let config = RerankerConfig {
            model_score_weight: 0.8,
            ..RerankerConfig::default()
        };
        let log = std::f64::consts::LN_2;
        let scores = [-4.0 * log, -8.0 * log, -100.0 * log, -4.0 * log];
        let texts = ["好", "你好", "🙂", "é\u{301}"];
        let adjustments = sentence_adjustments(&scores, &texts, config).unwrap();
        assert_eq!(adjustments, [0.0, -3.2, -6.4, 0.0]);
        assert_eq!(
            sentence_adjustments(&scores[..2], &texts[..2], config).unwrap(),
            adjustments[..2]
        );
        assert_eq!(
            sentence_adjustments(&scores, &["你", "好", "你好", "🙂"], config).unwrap(),
            adjustments
        );
        let custom = RerankerConfig {
            model_score_weight: 0.5,
            model_sentence_reward_cap_bits: 6.0,
            ..config
        };
        assert_eq!(
            sentence_adjustments(&scores, &texts, custom).unwrap(),
            [0.0, -2.0, -3.0, 0.0]
        );
        let shifted = scores.map(|score| score - 100.0 * log);
        for (actual, expected) in sentence_adjustments(&shifted, &texts, config)
            .unwrap()
            .iter()
            .zip(&adjustments)
        {
            assert!((actual - expected).abs() < 1e-12);
        }
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 1.0] {
            assert!(sentence_adjustments(&[invalid], &["好"], config).is_none());
        }
        assert!(sentence_adjustments(&[0.0], &[""], config).is_none());
        assert!(sentence_adjustments(&scores, &["好"], config).is_none());
        assert!(sentence_adjustments(&[], &[], config).is_none());
    }

    #[test]
    fn relative_adjustments_preserve_probability_gaps_and_cap_before_weighting() {
        let scores = [0.0, -2.0, -7.0, -8.0, -20.0];
        let config = RerankerConfig {
            model_score_weight: 1.0,
            ..RerankerConfig::default()
        };
        let rewards = relative_adjustments(&scores, config).unwrap();
        for (actual, expected) in rewards.iter().zip([0.0, -2.0, -7.0, -8.0, -8.0]) {
            assert!((actual - expected).abs() < 1e-12);
        }
    }

    #[test]
    fn worse_outliers_and_shared_offsets_do_not_change_existing_adjustments() {
        let scores = [-1.75, -5.85, -5.32];
        let expected = relative_adjustments(&scores, RerankerConfig::default()).unwrap();
        assert!(expected[0] > expected[2] && expected[2] > expected[1]);
        let extended =
            relative_adjustments(&[-1.75, -5.85, -5.32, -100.0], RerankerConfig::default())
                .unwrap();
        assert_eq!(&extended[..3], expected);
        let shifted =
            relative_adjustments(&scores.map(|score| score - 10.0), RerankerConfig::default())
                .unwrap();
        for (actual, expected) in shifted.iter().zip(expected) {
            assert!((actual - expected).abs() < 1e-12);
        }
        let tied = relative_adjustments(&[-3.0, -3.0], RerankerConfig::default()).unwrap();
        assert_eq!(tied[0], tied[1]);
        assert_eq!(tied[0], 0.0);
    }

    #[test]
    fn unusable_model_scores_abstain() {
        assert!(relative_adjustments(&[], RerankerConfig::default()).is_none());
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(relative_adjustments(&[-1.0, invalid], RerankerConfig::default()).is_none());
        }
    }

    #[test]
    fn custom_parameters_change_the_adjustment_scale_and_clipping() {
        let scores = [0.0, -2.0, -5.0];
        let config = RerankerConfig {
            model_score_weight: 0.5,
            model_score_gap_limit_bits: 4.0,
            ..RerankerConfig::default()
        };
        assert_eq!(
            relative_adjustments(&scores, config).unwrap(),
            vec![0.0, -1.0, -2.0]
        );
        for config in [
            RerankerConfig {
                model_score_weight: 0.0,
                ..config
            },
            RerankerConfig {
                model_score_gap_limit_bits: 0.0,
                ..config
            },
        ] {
            assert_eq!(relative_adjustments(&scores, config).unwrap(), vec![0.0; 3]);
        }
    }
}
