//! Character scoring and LambdaRank for lexical candidates.
use std::collections::HashMap;
use std::io;
use std::path::Path;

use si_neural::{LambdaRank, Reranker};

use super::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionPreferences, CorrectionSearch,
    CorrectionSensitivity, EnabledLanguages, PersonalPhrase,
};
use crate::ranking_features;

const RERANKER_FEATURES: [&str; 3] = [
    "reranker_logp_sum",
    "reranker_logp_mean",
    "reranker_context_gain",
];
const SI_POOL_LIMIT: usize = 64;

pub struct HybridRanking {
    reranker: Reranker,
    ranker: LambdaRank,
    v5: bool,
}

pub struct RankedCandidate {
    pub candidate: Candidate,
    pub model_score: Option<f64>,
}

impl From<Candidate> for RankedCandidate {
    fn from(candidate: Candidate) -> Self {
        Self {
            candidate,
            model_score: None,
        }
    }
}

struct Features {
    row_index: usize,
    values: Vec<Option<f64>>,
}

impl HybridRanking {
    /// The character scorer must match the LambdaRank training bundle.
    pub fn open(path: &Path) -> io::Result<Self> {
        let ranker = LambdaRank::open(&path.join("lambdarank.json"))?;
        let matches = |extra: &[&str]| {
            ranker
                .feature_names
                .iter()
                .map(String::as_str)
                .eq(ranking_features::NAMES
                    .into_iter()
                    .chain(extra.iter().copied())
                    .chain(RERANKER_FEATURES))
        };
        let v5 = matches(&ranking_features::V5_ADDITIONS);
        if !v5 && !matches(&[]) {
            return Err(io::Error::other("unexpected ranking feature order"));
        }
        let reranker = Reranker::open(&path.join("reranker"))?;
        if reranker.checkpoint_sha256() != ranker.reranker_checkpoint_sha256 {
            return Err(io::Error::other("incompatible ranking checkpoint"));
        }
        Ok(Self {
            reranker,
            ranker,
            v5,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn convert(
        &self,
        engine: &CandidateEngine<'_>,
        source: &str,
        languages: EnabledLanguages,
        phrases: &[PersonalPhrase<'_>],
        preferences: ConversionPreferences<'_>,
        preceding: &str,
        correction: Option<CorrectionSensitivity>,
    ) -> Vec<RankedCandidate> {
        let learned_margin = correction.zip(self.ranker.correction_margins).map(
            |(mode, [conservative, higher_recall])| match mode {
                CorrectionSensitivity::Conservative => conservative,
                CorrectionSensitivity::HigherRecall => higher_recall,
            },
        );
        let heuristic = correction.map(CorrectionSearch::Heuristic);
        let candidates = engine.convert_for_ranking(
            source,
            languages,
            phrases,
            preferences,
            preceding,
            if learned_margin.is_some() {
                Some(CorrectionSearch::ModelPool)
            } else {
                heuristic
            },
        );
        let mut rows: Vec<_> = candidates.into_iter().map(RankedCandidate::from).collect();
        if self
            .enhance(
                &mut rows,
                source,
                preceding,
                preferences,
                learned_margin.is_some(),
            )
            .is_err()
        {
            if learned_margin.is_some() {
                return engine
                    .convert_with_correction(
                        source,
                        languages,
                        false,
                        phrases,
                        preferences,
                        preceding,
                        correction,
                    )
                    .into_iter()
                    .map(RankedCandidate::from)
                    .collect();
            }
            for row in &mut rows {
                row.model_score = None;
            }
        }
        apply_correction_policy(&mut rows, learned_margin);
        for row in &mut rows {
            row.candidate.ranking_evidence = None;
        }
        // Sort only the slots participating in the model. Policy-only candidates
        // and the unscored tail retain their relative engine order.
        let indices: Vec<_> = rows
            .iter()
            .enumerate()
            .filter_map(|(i, row)| row.model_score.map(|_| i))
            .collect();
        let mut ranked: Vec<_> = indices
            .iter()
            .map(|&i| (i, rows[i].model_score.unwrap()))
            .collect();
        ranked.sort_by(|(li, left), (ri, right)| right.total_cmp(left).then(li.cmp(ri)));
        // Move the ranked rows through an indexed buffer without cloning text or evidence.
        let mut slots: Vec<_> = rows.into_iter().map(Some).collect();
        let ordered: Vec<_> = ranked.into_iter().map(|(i, _)| slots[i].take()).collect();
        for (i, row) in indices.into_iter().zip(ordered) {
            slots[i] = row;
        }
        let mut result: Vec<_> = slots.into_iter().flatten().collect();
        result.sort_by_key(|row| {
            let candidate = &row.candidate;
            (
                candidate.language == CandidateLanguage::Literal,
                !candidate.preferred,
                std::cmp::Reverse(candidate.consumed_bytes),
            )
        });
        result
    }

    fn enhance(
        &self,
        rows: &mut [RankedCandidate],
        source: &str,
        preceding: &str,
        preferences: ConversionPreferences<'_>,
        model_correction_pool: bool,
    ) -> io::Result<()> {
        let mut features = Vec::new();
        let correction_slots = if model_correction_pool {
            rows.iter()
                .filter(|row| row.candidate.is_corrected())
                .count()
        } else {
            0
        };
        for (row_index, row) in rows.iter().enumerate() {
            let candidate = &row.candidate;
            if candidate.consumed_bytes != source.len()
                || candidate.language == CandidateLanguage::Literal
            {
                continue;
            }
            if features.len() >= SI_POOL_LIMIT - correction_slots
                && !(model_correction_pool && candidate.is_corrected())
            {
                continue;
            }
            let values = if self.v5 {
                ranking_features::extract_v5(
                    source,
                    preceding,
                    !preceding.is_empty(),
                    candidate,
                    preferences,
                )
            } else {
                ranking_features::extract(source, preceding, candidate)
            };
            if let Some(values) = values {
                features.push(Features { row_index, values });
            }
        }
        let mut surfaces = Vec::new();
        let mut token_counts = Vec::new();
        let mut scored = HashMap::new();
        for feature in &features {
            let text = &rows[feature.row_index].candidate.text;
            if let Some(count) = self.reranker.scoreable_token_count(text) {
                scored.entry(text.clone()).or_insert_with(|| {
                    let index = surfaces.len();
                    surfaces.push(text.clone());
                    token_counts.push(count);
                    index
                });
            }
        }
        let conditioned = self.reranker.rank(preceding, &surfaces, Some(0.0))?;
        let unconditional = if preceding.is_empty() {
            None
        } else {
            Some(self.reranker.rank("", &surfaces, Some(0.0))?)
        };
        for mut feature in features {
            let row = &mut rows[feature.row_index];
            let index = scored.get(&row.candidate.text).copied();
            let total = index.and_then(|i| conditioned.scores[i]);
            let mean = total
                .zip(index)
                .map(|(value, i)| value / token_counts[i] as f64);
            let gain = total
                .zip(index)
                .and_then(|(value, i)| Some(value - unconditional.as_ref()?.scores[i]?));
            feature.values.extend([total, mean, gain]);
            row.model_score = Some(self.ranker.score(&feature.values)?);
        }
        Ok(())
    }
}

fn apply_correction_policy(rows: &mut Vec<RankedCandidate>, learned_margin: Option<f64>) {
    let Some(margin) = learned_margin else {
        for row in rows.iter_mut().filter(|row| row.candidate.is_corrected()) {
            row.model_score = None;
        }
        return;
    };
    let best_ordinary = rows
        .iter()
        .filter(|row| !row.candidate.is_corrected())
        .filter_map(|row| row.model_score)
        .max_by(f64::total_cmp)
        .unwrap_or(0.0);
    rows.retain(|row| {
        !row.candidate.is_corrected()
            || row
                .model_score
                .is_some_and(|score| score - best_ordinary > margin)
    });
}
