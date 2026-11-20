//! Experimental v4 candidate union and LambdaRank features.
use std::collections::HashMap;
use std::io;
use std::path::Path;

use si_neural::{LambdaRank, Pinyin, Reranker};

use super::input::Input;
use super::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionPreferences, CorrectionSearch,
    CorrectionSensitivity, EnabledLanguages, Language, PersonalPhrase,
};
use crate::{han, ranking_features};

const NEURAL_FEATURES: [&str; 6] = [
    "from_si_engine",
    "from_pinyin_model",
    "pinyin_model_beam_rank",
    "reranker_logp_sum",
    "reranker_logp_mean",
    "reranker_context_gain",
];
const SI_POOL_LIMIT: usize = 64;

pub struct HybridRanking {
    pinyin: Pinyin,
    reranker: Reranker,
    ranker: LambdaRank,
    v5: bool,
}

pub struct RankedCandidate {
    pub candidate: Candidate,
    pub model_score: Option<f64>,
    pub neural_only: bool,
}

impl From<Candidate> for RankedCandidate {
    fn from(candidate: Candidate) -> Self {
        Self {
            candidate,
            model_score: None,
            neural_only: false,
        }
    }
}

struct Features {
    row_index: usize,
    values: Vec<Option<f64>>,
    generated_rank: Option<f64>,
}

impl HybridRanking {
    /// The three assets must match the v4 training bundle and each other.
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
                    .chain(NEURAL_FEATURES))
        };
        let v5 = matches(&ranking_features::V5_ADDITIONS);
        if !v5 && !matches(&[]) {
            return Err(io::Error::other("unexpected ranking feature order"));
        }
        let pinyin = Pinyin::open(&path.join("pinyin"))?;
        let reranker = Reranker::open(&path.join("reranker"))?;
        if pinyin.checkpoint_sha256() != ranker.pinyin_checkpoint_sha256
            || reranker.checkpoint_sha256() != ranker.reranker_checkpoint_sha256
        {
            return Err(io::Error::other("incompatible ranking checkpoints"));
        }
        Ok(Self {
            pinyin,
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
        let baseline_len = rows.len();
        if self
            .enhance(
                engine,
                &mut rows,
                source,
                languages,
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
            rows.truncate(baseline_len);
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

    #[allow(clippy::too_many_arguments)]
    fn enhance(
        &self,
        engine: &CandidateEngine<'_>,
        rows: &mut Vec<RankedCandidate>,
        source: &str,
        languages: EnabledLanguages,
        preceding: &str,
        preferences: ConversionPreferences<'_>,
        model_correction_pool: bool,
    ) -> io::Result<()> {
        let mut features = Vec::new();
        let mut known = HashMap::new();
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
            let index = if features.len() < SI_POOL_LIMIT - correction_slots
                || (model_correction_pool && candidate.is_corrected())
            {
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
                values.map(|values| {
                    let index = features.len();
                    features.push(Features {
                        row_index,
                        values,
                        generated_rank: None,
                    });
                    index
                })
            } else {
                None
            };
            known.insert((candidate.language, candidate.text.clone()), index);
        }
        if languages.chinese
            && !source.is_empty()
            && source.len() <= 128
            && !source.bytes().any(|b| b.is_ascii_uppercase())
        {
            let input = Input::new(source);
            let spelling = input.spelling(Language::Chinese);
            if !spelling.is_empty() && spelling.iter().all(u8::is_ascii_lowercase) {
                let contextual = self.pinyin.uses_context();
                let paths = if contextual {
                    input.pinyin_paths(engine.base.lexicon())
                } else {
                    Vec::new()
                };
                let normalized: String = spelling
                    .iter()
                    .map(|&b| {
                        if !contextual && b == b'v' {
                            'ü'
                        } else {
                            b as char
                        }
                    })
                    .collect();
                let generated = self.pinyin.generate(
                    &normalized,
                    contextual.then_some(preceding),
                    &paths,
                    self.ranker.beam_size,
                )?;
                for (index, text) in generated.model_candidates.into_iter().enumerate() {
                    let Some(language) = generated_language(&text, languages) else {
                        continue;
                    };
                    if text == source || text == normalized {
                        continue;
                    }
                    let generated_rank = Some((index + 1) as f64);
                    if let Some(found) = known.get(&(language, text.clone())) {
                        if let Some(feature) = found {
                            features[*feature].generated_rank = generated_rank;
                        }
                    } else {
                        known.insert((language, text.clone()), Some(features.len()));
                        let mut values =
                            vec![None; self.ranker.feature_names.len() - NEURAL_FEATURES.len()];
                        values[24] = Some(match language {
                            CandidateLanguage::Chinese => 0.0,
                            CandidateLanguage::English => 1.0,
                            CandidateLanguage::Mixed => 2.0,
                            CandidateLanguage::Literal => unreachable!(),
                        });
                        features.push(Features {
                            row_index: rows.len(),
                            values,
                            generated_rank,
                        });
                        rows.push(RankedCandidate {
                            model_score: None,
                            neural_only: true,
                            candidate: Candidate {
                                ranking_evidence: None,
                                text,
                                language,
                                consumed_bytes: source.len(),
                                score_bits: Some(0.0),
                                context_adjustment: 0.0,
                                completion: false,
                                lexical_tokens: 0,
                                source_boundaries: vec![],
                                confirmation_boundaries: vec![],
                                personal: false,
                                preferred: false,
                                verbatim: false,
                                correction: None,
                                token_bonus: 0.0,
                            },
                        });
                    }
                }
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
            feature.values.extend([
                Some(f64::from(!row.neural_only)),
                Some(f64::from(feature.generated_rank.is_some())),
                feature.generated_rank,
                total,
                mean,
                gain,
            ]);
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
        .filter(|row| !row.neural_only && !row.candidate.is_corrected())
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

fn generated_language(text: &str, languages: EnabledLanguages) -> Option<CandidateLanguage> {
    let chinese = text.chars().any(han::is_han);
    let english = text.bytes().any(|byte| byte.is_ascii_alphabetic());
    match (chinese, english) {
        (true, false) if languages.chinese => Some(CandidateLanguage::Chinese),
        (true, true) if languages.chinese && languages.english => Some(CandidateLanguage::Mixed),
        (false, true) if languages.english => Some(CandidateLanguage::English),
        _ => None,
    }
}
