mod baseline_cache;

use std::io;
use std::path::Path;
use std::sync::Mutex;

use si_neural::Reranker;

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

    pub(super) fn bonuses(&self, context: &str, texts: &[&str]) -> Option<Vec<f64>> {
        if context.is_empty()
            || self.config.model_context_token_limit == 0
            || self.config.model_score_weight == 0.0
            || self.config.model_score_gap_limit_bits == 0.0
        {
            return Some(vec![0.0; texts.len()]);
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
            return Some(vec![0.0; texts.len()]);
        }
        let baseline = self.baseline_scores(texts)?;
        let lifts: Vec<_> = conditioned
            .scores
            .iter()
            .zip(baseline)
            .map(|(with, without)| (with - without) * std::f64::consts::LOG2_E)
            .collect();
        relative_adjustments(&lifts, self.config)
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

fn relative_adjustments(scores: &[f64], config: RerankerConfig) -> Option<Vec<f64>> {
    if !scores.iter().all(|score| score.is_finite()) {
        return None;
    }
    let highest = scores.iter().copied().reduce(f64::max)?;
    Some(
        scores
            .iter()
            .map(|score| {
                config.model_score_weight
                    * (score - highest).max(-config.model_score_gap_limit_bits)
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::{SmallReranker, relative_adjustments};
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
        assert_eq!(
            model.bonuses("", &["吃肌酸", "吃计算"]),
            Some(vec![0.0, 0.0])
        );
    }

    #[test]
    fn relative_adjustments_preserve_lift_gaps_and_cap_before_weighting() {
        let scores = [0.0, -2.0, -7.0, -8.0, -20.0];
        let rewards = relative_adjustments(&scores, RerankerConfig::default()).unwrap();
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
