//! Offline probability observations for the selected lexical derivation.
//! Costs, labels and candidate positions never enter these observations.
use super::*;

struct Observation {
    count: f64,
    unigram: f64,
    base: f64,
    user_count: f64,
    user_unigram: Option<f64>,
    user_lift: Option<f64>,
    without_user_grams: f64,
    with_user_grams: f64,
    base_order: usize,
    base_support: f64,
    user_order: usize,
    user_support: f64,
}

impl ScoreSession<'_, '_> {
    fn observe(&mut self, previous: History, language: Language, ids: WordIds) -> Observation {
        let history = previous.for_language(language);
        let model = self.model;
        let vocab = model.base.vocabulary[language as usize];
        let count = model.base.count(ids.base);
        let unigram = (count + 1.0) / (vocab.count + vocab.types).max(1.0);
        let mut row = Observation {
            count,
            unigram,
            base: unigram,
            user_count: 0.0,
            user_unigram: None,
            user_lift: None,
            without_user_grams: unigram,
            with_user_grams: unigram,
            base_order: 0,
            base_support: 0.0,
            user_order: 0,
            user_support: 0.0,
        };
        if let Some(user) = model.user {
            let user_vocab = user.vocabulary[language as usize];
            let union_prior = (count + 1.0)
                / (vocab.count + vocab.types + model.user_only_types[language as usize]).max(1.0);
            row.user_count = user.count(ids.user);
            // A smoothed user distribution, with the shared-vocabulary base distribution as prior.
            let probability = (row.user_count + USER_UNIGRAM_PRIOR * union_prior)
                / (user_vocab.count + USER_UNIGRAM_PRIOR);
            row.user_unigram = Some(probability);
            row.user_lift = Some(probability.log2() - union_prior.log2());
            let weight =
                USER_UNIGRAM_LIMIT * user_vocab.count / (user_vocab.count + USER_UNIGRAM_PRIOR);
            row.without_user_grams = blend(
                union_prior,
                row.user_count / user_vocab.count.max(1.0),
                weight,
            );
        }
        for (count, mass, order) in continuations(
            &mut self.base_cache,
            model.base,
            history.base,
            language,
            ids.base,
        ) {
            row.base = (count + BASE_GRAM_PRIOR * row.base) / (mass + BASE_GRAM_PRIOR);
            row.without_user_grams =
                (count + BASE_GRAM_PRIOR * row.without_user_grams) / (mass + BASE_GRAM_PRIOR);
            if count > 0.0 {
                row.base_order = order;
                row.base_support = count;
            }
        }
        row.with_user_grams = row.without_user_grams;
        if let Some(user) = model.user {
            for (count, mass, order) in
                continuations(&mut self.user_cache, user, history.user, language, ids.user)
            {
                let weight = (mass / (mass + USER_GRAM_PRIOR)).min(USER_GRAM_LIMIT);
                row.with_user_grams = blend(row.with_user_grams, count / mass, weight);
                if count > 0.0 {
                    row.user_order = order;
                    row.user_support = count;
                }
            }
        }
        row
    }

    pub(in crate::conversion) fn populate_features(&mut self, evidence: &mut PathEvidence) {
        if evidence.words.is_empty() {
            return;
        }
        let mut internal = History::default();
        let mut contextual = self.initial_history;
        let mut rows = Vec::with_capacity(evidence.words.len());
        let mut context_logp = 0.0;
        let mut context_user_gain = 0.0;
        let mut context_order = 0;
        let mut context_user_support = 0.0;
        let mut crosses_boundary = true;
        let first_language = if evidence.words[0].language == 0 {
            Language::Chinese
        } else {
            Language::English
        };
        let initial = self.initial_history.for_language(first_language);
        let history_words = initial.base.len.max(initial.user.len);
        for (i, word) in evidence.words.iter().enumerate() {
            let language = if word.language == 0 {
                Language::Chinese
            } else {
                Language::English
            };
            let ids = WordIds {
                base: word.base,
                user: word.user,
            };
            let row = self.observe(internal, language, ids);
            let conditioned = self.observe(contextual, language, ids);
            context_logp += conditioned.base.log2();
            context_user_gain +=
                conditioned.with_user_grams.log2() - conditioned.without_user_grams.log2();
            crosses_boundary &= contextual.last == Some(language);
            if crosses_boundary {
                if conditioned.base_order > i + 1 {
                    context_order = context_order.max(conditioned.base_order);
                }
                if conditioned.user_order > i + 1 {
                    context_user_support += conditioned.user_support.ln_1p();
                }
            }
            internal = self.model.extend_history(internal, language, ids);
            contextual = self.model.extend_history(contextual, language, ids);
            rows.push(row);
        }
        let n = rows.len() as f64;
        let internal_rows = &rows[1..];
        let links = internal_rows.len() as f64;
        let mean = |values: Vec<f64>| -> Option<f64> {
            (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
        };
        let minimum = |values: Vec<f64>| values.into_iter().reduce(f64::min);
        let mut f = vec![None; crate::ranking_features::NAMES.len()];
        f[0] = mean(rows.iter().map(|r| r.count.ln_1p()).collect());
        f[1] = minimum(rows.iter().map(|r| r.count.ln_1p()).collect());
        let unigram_sum = rows.iter().map(|r| r.unigram.log2()).sum::<f64>();
        f[2] = Some(unigram_sum);
        f[3] = Some(unigram_sum / n);
        f[4] = minimum(rows.iter().map(|r| r.unigram.log2()).collect());
        if links > 0.0 {
            let sum = internal_rows.iter().map(|r| r.base.log2()).sum::<f64>();
            f[5] = Some(sum);
            f[6] = Some(sum / links);
            f[7] = minimum(internal_rows.iter().map(|r| r.base.log2()).collect());
            if self.model.base.grams.is_some() {
                f[8] =
                    Some(internal_rows.iter().filter(|r| r.base_order > 0).count() as f64 / links);
                f[9] = Some(
                    internal_rows
                        .iter()
                        .map(|r| r.base_order)
                        .max()
                        .unwrap_or(0) as f64,
                );
                f[10] = Some(
                    mean(
                        internal_rows
                            .iter()
                            .filter(|r| r.base_order > 0)
                            .map(|r| r.base_support.ln_1p())
                            .collect(),
                    )
                    .unwrap_or(0.0),
                );
            }
        }
        f[13] = Some(history_words as f64);
        f[14] = Some(context_logp);
        f[15] = Some(context_logp - rows.iter().map(|r| r.base.log2()).sum::<f64>());
        f[16] = self
            .model
            .base
            .grams
            .is_some()
            .then_some(context_order as f64);
        f[25] = Some(f64::from(self.model.user.is_some()));
        if self.model.user.is_some() {
            f[26] = Some(rows.iter().filter(|r| r.user_count > 0.0).count() as f64 / n);
            f[27] = mean(rows.iter().map(|r| r.user_count.ln_1p()).collect());
            f[28] = minimum(rows.iter().map(|r| r.user_count.ln_1p()).collect());
            f[29] = mean(
                rows.iter()
                    .filter_map(|r| r.user_unigram.map(f64::log2))
                    .collect(),
            );
            f[30] = mean(rows.iter().filter_map(|r| r.user_lift).collect());
        }
        let user_grams = self.model.user.is_some_and(|user| user.grams.is_some());
        f[31] = Some(f64::from(user_grams));
        if user_grams {
            if links > 0.0 {
                f[32] =
                    Some(internal_rows.iter().filter(|r| r.user_order > 0).count() as f64 / links);
                f[33] = Some(
                    mean(
                        internal_rows
                            .iter()
                            .filter(|r| r.user_order > 0)
                            .map(|r| r.user_support.ln_1p())
                            .collect(),
                    )
                    .unwrap_or(0.0),
                );
                f[34] = mean(
                    internal_rows
                        .iter()
                        .map(|r| r.with_user_grams.log2() - r.without_user_grams.log2())
                        .collect(),
                );
            }
            f[35] = Some(context_user_support);
            f[36] = Some(context_user_gain);
        }
        evidence.statistics = f;
    }
}
