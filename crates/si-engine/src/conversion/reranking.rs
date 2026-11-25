use std::io;
use std::path::Path;

use si_neural::Reranker;

use crate::resources::RerankerConfig;

/// Immutable local character scorer shared across base and user engines.
pub struct SmallReranker {
    model: Reranker,
    config: RerankerConfig,
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
        })
    }

    pub(super) fn candidate_limit(&self) -> usize {
        self.config.model_candidate_limit
    }

    pub(super) fn candidate_byte_limit(&self) -> usize {
        self.config.model_candidate_token_limit * 4
    }

    pub(super) fn bonuses(&self, context: &str, texts: &[&str]) -> Option<Vec<f64>> {
        let scores = self
            .model
            .bounded_mean_scores(
                context,
                texts,
                self.config.model_context_token_limit,
                self.config.model_candidate_token_limit,
            )
            .ok()??;
        relative_bonuses(&scores, self.config)
    }
}

fn relative_bonuses(scores: &[f64], config: RerankerConfig) -> Option<Vec<f64>> {
    if !scores.iter().all(|score| score.is_finite()) {
        return None;
    }
    let highest = scores.iter().copied().reduce(f64::max)?;
    Some(
        scores
            .iter()
            .map(|score| {
                let gap_bits = (score - highest) * std::f64::consts::LOG2_E;
                config.model_score_weight
                    * (config.model_score_gap_limit_bits
                        + gap_bits.max(-config.model_score_gap_limit_bits))
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::relative_bonuses;
    use crate::resources::RerankerConfig;

    #[test]
    fn relative_rewards_preserve_model_gaps_and_cap_before_weighting() {
        let scores = [0.0, -2.0, -7.0, -8.0, -20.0].map(|bits| bits * std::f64::consts::LN_2);
        let rewards = relative_bonuses(&scores, RerankerConfig::default()).unwrap();
        for (actual, expected) in rewards.iter().zip([6.4, 4.8, 0.8, 0.0, 0.0]) {
            assert!((actual - expected).abs() < 1e-12);
        }
    }

    #[test]
    fn worse_outliers_and_shared_offsets_do_not_change_existing_rewards() {
        let scores = [-1.75, -5.85, -5.32];
        let expected = relative_bonuses(&scores, RerankerConfig::default()).unwrap();
        assert!(expected[0] > expected[2] && expected[2] > expected[1]);
        let extended =
            relative_bonuses(&[-1.75, -5.85, -5.32, -100.0], RerankerConfig::default()).unwrap();
        assert_eq!(&extended[..3], expected);
        let shifted =
            relative_bonuses(&scores.map(|score| score - 10.0), RerankerConfig::default()).unwrap();
        for (actual, expected) in shifted.iter().zip(expected) {
            assert!((actual - expected).abs() < 1e-12);
        }
        let tied = relative_bonuses(&[-3.0, -3.0], RerankerConfig::default()).unwrap();
        assert_eq!(tied[0], tied[1]);
        assert!((tied[0] - 6.4).abs() < 1e-12);
    }

    #[test]
    fn unusable_model_scores_abstain() {
        assert!(relative_bonuses(&[], RerankerConfig::default()).is_none());
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(relative_bonuses(&[-1.0, invalid], RerankerConfig::default()).is_none());
        }
    }

    #[test]
    fn custom_parameters_change_the_reward_scale_and_clipping() {
        let scores = [0.0, -2.0, -5.0].map(|bits| bits * std::f64::consts::LN_2);
        let config = RerankerConfig {
            model_score_weight: 0.5,
            model_score_gap_limit_bits: 4.0,
            ..RerankerConfig::default()
        };
        assert_eq!(
            relative_bonuses(&scores, config).unwrap(),
            vec![2.0, 1.0, 0.0]
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
            assert_eq!(relative_bonuses(&scores, config).unwrap(), vec![0.0; 3]);
        }
    }
}
