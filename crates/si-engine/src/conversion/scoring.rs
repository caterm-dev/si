use std::cell::OnceCell;
use std::collections::{HashMap, HashSet};
use std::hash::BuildHasherDefault;
use std::sync::{Arc, Mutex};

use si_gram::{Context, GramModel, MAX_ORDER};
use si_lexicon::{Lexicon, WordId};

use super::cache::IdHasher;
use super::context::FieldContext;
use super::lookup::Lexeme;
use super::{Language, WordIds};
use crate::resources::{
    EngineConfig, EngineResources, SpellingScoringConfig, StatisticalScoringConfig,
};
use crate::text_boundaries::START_TOKEN;

const HISTORY_WORDS: usize = MAX_ORDER - 1;
const CONTEXT_CACHE_CAPACITY: usize = 8_192;

#[derive(Clone, Copy)]
struct Corpus<'a> {
    lexicon: &'a Lexicon,
    grams: Option<&'a GramModel>,
    history_limit: usize,
    total_count: f64,
}

impl<'a> Corpus<'a> {
    fn new(resources: &'a EngineResources) -> Self {
        let total_count = resources
            .lexicon()
            .words()
            .map(|word| word.count as f64)
            .sum();
        let grams = resources.grams();
        // Preserve the existing search history for models through order four.
        let history_limit = grams
            .and_then(|grams| grams.sizes().iter().rposition(|&size| size != 0))
            .map_or(3, |order_index| (order_index + 1).max(3));
        Self {
            lexicon: resources.lexicon(),
            grams,
            history_limit,
            total_count,
        }
    }

    fn count(self, id: Option<WordId>) -> f64 {
        id.and_then(|id| self.lexicon.word(id))
            .map_or(0.0, |word| word.count as f64)
    }

    fn frequency(self, count: f64) -> f64 {
        count / self.total_count.max(1.0)
    }
}

pub(super) struct Scoring<'a> {
    config: EngineConfig,
    base: Corpus<'a>,
    start_token: Option<WordId>,
    user: Option<Corpus<'a>>,
    contexts: Mutex<Option<ContextCaches<'a>>>,
}

impl<'a> Scoring<'a> {
    pub(super) fn new(
        base: &'a EngineResources,
        user: Option<&'a EngineResources>,
        config: EngineConfig,
    ) -> Self {
        let base = Corpus::new(base);
        let user = user
            .map(Corpus::new)
            .filter(|corpus| !corpus.lexicon.is_empty());
        let start_token = base
            .lexicon
            .words_for_text(START_TOKEN)
            .find(|word| word.reading.is_none() && word.count == 0)
            .map(|word| word.id);
        let has_starts = start_token
            .zip(base.grams)
            .is_some_and(|(id, grams)| grams.context(&[id]).continuations().next().is_some());
        Self {
            config,
            base,
            start_token: start_token.filter(|_| has_starts),
            user,
            contexts: Mutex::new(Some(ContextCaches::default())),
        }
    }

    pub(super) fn has_user(&self) -> bool {
        self.user.is_some()
    }

    pub(super) fn sentence_start(&self) -> History {
        let start = self.start_token.map(|id| StartHistory {
            history: HistoryIds::default().with_word(Some(id), self.base.history_limit),
            remaining: self
                .base
                .grams
                .and_then(|grams| grams.sizes().iter().rposition(|&size| size != 0))
                .map_or(0, |order| order + 1),
            count: 0,
            maximum: 0,
        });
        History {
            start,
            ..History::default()
        }
    }

    pub(super) fn unigram(&self, word: Lexeme<'_>) -> Scores {
        let base = self.base.frequency(self.base.count(word.ids.base));
        Scores {
            base,
            personalized: self.user.map_or(base, |user| {
                boost_user_unigram(
                    base,
                    user,
                    user.count(word.ids.user),
                    self.config.statistical_scoring,
                )
            }),
        }
    }

    pub(super) fn extend_history(
        &self,
        previous: History,
        language: Language,
        ids: WordIds,
    ) -> History {
        History {
            base: previous.base.with_word(ids.base, self.base.history_limit),
            user: previous
                .user
                .with_word(ids.user, self.user.map_or(3, |user| user.history_limit)),
            last: Some(language),
            start: previous.start,
        }
    }

    pub(super) fn field_history(&self, mut history: History, user: bool) -> History {
        let corpus = if user { self.user } else { Some(self.base) };
        let limit = corpus
            .and_then(|corpus| corpus.grams)
            .and_then(|grams| grams.sizes().iter().rposition(|&size| size != 0))
            .map_or(0, |index| index + 1);
        let mut ids = if user { history.user } else { history.base };
        ids.len = ids.len.min(limit);
        ids.ids[ids.len..].fill(WordId(0));
        history = History::default();
        if user {
            history.user = ids;
        } else {
            history.base = ids;
        }
        history
    }

    pub(super) fn session(&self, field: Arc<FieldContext>) -> ScoreSession<'_, 'a> {
        ScoreSession {
            model: self,
            field,
            start_maxima: HashMap::new(),
            // Lease the cached dictionary contexts for this request. Concurrent
            // conversions compute locally, without waiting for the lease.
            contexts: self
                .contexts
                .try_lock()
                .ok()
                .and_then(|mut cached| cached.take())
                .unwrap_or_default(),
        }
    }
}

#[derive(Clone, Copy, Default)]
pub(super) struct Scores {
    pub(super) base: f64,
    pub(super) personalized: f64,
}

/// Request-local scoring inputs shared by paths through the same lexical edge.
pub(super) struct WordScore<'a> {
    word: Lexeme<'a>,
    unigram: OnceCell<Scores>,
}

impl<'a> WordScore<'a> {
    pub(super) fn new(word: Lexeme<'a>) -> Self {
        Self {
            word,
            unigram: OnceCell::new(),
        }
    }
}

impl std::ops::Add for Scores {
    type Output = Self;

    fn add(self, other: Self) -> Self {
        Self {
            base: self.base + other.base,
            personalized: self.personalized + other.personalized,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct HistoryIds {
    ids: [WordId; HISTORY_WORDS],
    len: usize,
}

impl Default for HistoryIds {
    fn default() -> Self {
        Self {
            ids: [WordId(0); HISTORY_WORDS],
            len: 0,
        }
    }
}

impl HistoryIds {
    fn with_word(mut self, id: Option<WordId>, limit: usize) -> Self {
        let Some(id) = id else { return Self::default() };
        for index in (1..limit).rev() {
            self.ids[index] = self.ids[index - 1];
        }
        self.ids[0] = id;
        self.len = (self.len + 1).min(limit);
        self
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(super) struct StartHistory {
    history: HistoryIds,
    pub(super) remaining: usize,
    pub(super) count: u64,
    maximum: u64,
}

/// Complete spelling matches compete independently of unfinished completions
/// and edited spellings, so pending suffixes cannot change an exact prefix reward.
#[derive(Clone, Copy, Eq, Hash, PartialEq)]
pub(super) struct StartSpan {
    pub(super) end: usize,
    pub(super) completion: bool,
    pub(super) corrected: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct History {
    base: HistoryIds,
    user: HistoryIds,
    last: Option<Language>,
    start: Option<StartHistory>,
}

impl History {
    pub(super) fn is_empty(self) -> bool {
        self.base.len == 0 && self.user.len == 0
    }
    pub(super) fn last(self) -> Option<Language> {
        self.last
    }

    pub(super) fn has_start(self) -> bool {
        self.start.is_some()
    }

    pub(super) fn start_adjustment(self, reward_limit: f64) -> Option<Scores> {
        self.start.map(|start| Scores {
            base: start_reward(start.count, start.maximum, reward_limit),
            personalized: start_reward(start.count, start.maximum, reward_limit),
        })
    }

    /// A longer observed prefix may change the reward while the boundary remains in range.
    pub(super) fn context_upper(self, current: Scores, reward_limit: f64) -> Scores {
        if self.start.is_some() {
            Scores {
                base: reward_limit,
                personalized: reward_limit,
            }
        } else {
            current
        }
    }
}

#[derive(Clone, Copy, Eq, Hash, PartialEq)]
struct ContextKey {
    ids: [WordId; HISTORY_WORDS],
    len: usize,
}

struct Prepared<'a> {
    context: Context<'a>,
    mass: f64,
}

// Keys contain only bounded dictionary IDs. Full equality still guards every
// hit; no output text or canonical candidate identity uses this fast hash.
type ContextCache<'a> = HashMap<ContextKey, Prepared<'a>, BuildHasherDefault<IdHasher>>;

#[derive(Default)]
struct ContextCaches<'a> {
    base: ContextCache<'a>,
    user: ContextCache<'a>,
}

pub(super) struct CompletionBounds {
    base: HashMap<WordId, f64>,
    user: HashMap<WordId, f64>,
}

pub(super) struct ScoreSession<'model, 'data> {
    model: &'model Scoring<'data>,
    field: Arc<FieldContext>,
    start_maxima: HashMap<StartSpan, u64>,
    contexts: ContextCaches<'data>,
}

impl ScoreSession<'_, '_> {
    pub(super) fn initial_start(&self) -> Option<StartHistory> {
        self.field.start.start
    }

    pub(super) fn set_start_maxima(&mut self, maxima: HashMap<StartSpan, u64>) {
        self.start_maxima = maxima;
    }

    pub(super) fn advance_start(
        &mut self,
        mut start: StartHistory,
        word: Option<WordId>,
    ) -> StartHistory {
        start.maximum = 0;
        if start.remaining > 0 {
            let key = context_keys(start.history)
                .last()
                .expect("start marker history");
            start.count = self
                .model
                .base
                .grams
                .and_then(|grams| {
                    let row = prepare_context(&mut self.contexts.base, grams, key);
                    word.and_then(|id| row.context.count(id))
                })
                .unwrap_or(0);
            start.remaining = if word.is_some() {
                start.remaining - 1
            } else {
                0
            };
            start.history = if start.remaining > 0 {
                start.history.with_word(word, self.model.base.history_limit)
            } else {
                HistoryIds::default()
            };
        }
        start
    }

    /// At the highest order, an unobserved continuation stays neutral forever.
    /// Intersect the sparse gram row with lexical matches instead of multiplying
    /// every homophone by every possible next word.
    pub(super) fn final_start_words(
        &mut self,
        start: StartHistory,
    ) -> Option<impl Iterator<Item = WordId> + '_> {
        if start.remaining != 1 {
            return None;
        }
        let grams = self.model.base.grams?;
        let key = context_keys(start.history)
            .last()
            .expect("start marker history");
        let row = prepare_context(&mut self.contexts.base, grams, key);
        Some(row.context.continuations().map(|(id, _)| id))
    }

    pub(super) fn completion_bounds(
        &mut self,
        histories: impl Iterator<Item = History>,
    ) -> CompletionBounds {
        let histories: Vec<_> = histories.collect();
        CompletionBounds {
            base: completion_continuations(
                &mut self.contexts.base,
                self.model.base.grams,
                histories.iter().map(|history| history.base),
            ),
            user: completion_continuations(
                &mut self.contexts.user,
                self.model.user.and_then(|user| user.grams),
                histories.iter().map(|history| history.user),
            ),
        }
    }

    pub(super) fn completion_upper_bits(
        &self,
        bounds: &CompletionBounds,
        word: &WordScore<'_>,
        missing: usize,
    ) -> f64 {
        let unigram = word
            .unigram
            .get_or_init(|| self.model.unigram(word.word))
            .personalized;
        let base = word.word.ids.base.and_then(|id| bounds.base.get(&id));
        let user = word.word.ids.user.and_then(|id| bounds.user.get(&id));
        // Smoothing and user boosts cannot exceed the larger of their two inputs.
        // The personalized unigram is also an upper bound on the base unigram.
        let upper = unigram
            .max(base.copied().unwrap_or_default())
            .max(user.copied().unwrap_or_default());
        // Allow for accumulated rounding in smoothing and the optimistic score.
        probability_bits(upper) - completion_cost(self.model.config.spelling_scoring, missing)
            + 1e-9
    }

    pub(super) fn has_user(&self) -> bool {
        self.model.has_user()
    }

    pub(super) fn start(
        &mut self,
        word: Lexeme<'_>,
        missing: usize,
        end: usize,
        corrected: bool,
    ) -> (History, Scores, Scores) {
        let word_score = WordScore::new(word);
        let (history, scores) = self.step(
            History {
                start: self.field.start.start,
                ..History::default()
            },
            &word_score,
            missing,
            end,
            corrected,
        );
        let mut adjustment = history
            .start_adjustment(
                self.model
                    .config
                    .statistical_scoring
                    .sentence_start_reward_limit_bits,
            )
            .unwrap_or_default();
        if (!self.field.base.is_empty() || !self.field.user.is_empty())
            && word.personal.is_none()
            && !word.verbatim
        {
            let priors = *word_score.unigram.get_or_init(|| self.model.unigram(word));
            let mixed = self.field_probabilities(priors, word.ids);
            let cost = completion_cost(self.model.config.spelling_scoring, missing);
            adjustment.base = probability_bits(mixed.base) - cost - scores.base;
            adjustment.personalized =
                probability_bits(mixed.personalized) - cost - scores.personalized;
        }
        (history, scores, adjustment)
    }

    fn field_probabilities(&mut self, mut priors: Scores, ids: WordIds) -> Scores {
        let config = self.model.config.statistical_scoring;
        if !self.field.base.is_empty() {
            let mut mixed = Scores::default();
            for row in &self.field.base {
                let mut probability = priors;
                for (observed, mass) in continuations(
                    &mut self.contexts.base,
                    self.model.base,
                    row.history.base,
                    ids.base,
                ) {
                    probability.base = smooth_base_gram(probability.base, observed, mass, config);
                    probability.personalized =
                        smooth_base_gram(probability.personalized, observed, mass, config);
                }
                mixed.base += row.weight * probability.base;
                mixed.personalized += row.weight * probability.personalized;
            }
            priors = Scores {
                base: mixed.base.min(1.0),
                personalized: mixed.personalized.min(1.0),
            };
        }
        if let Some(user) = self.model.user.filter(|_| !self.field.user.is_empty()) {
            let mut mixed = 0.0;
            for row in &self.field.user {
                let mut probability = priors.personalized;
                for (observed, mass) in
                    continuations(&mut self.contexts.user, user, row.history.user, ids.user)
                {
                    probability = boost_user_gram(probability, observed, mass, config);
                }
                mixed += row.weight * probability;
            }
            // User components are boosts; rounding in normalized weights must
            // not turn an otherwise neutral user mixture into a penalty.
            priors.personalized = priors.personalized.max(mixed.min(1.0));
        }
        priors
    }

    pub(super) fn step(
        &mut self,
        previous: History,
        word_score: &WordScore<'_>,
        missing: usize,
        end: usize,
        corrected: bool,
    ) -> (History, Scores) {
        let word = word_score.word;
        let language = word.language;
        if word.verbatim {
            let score = -24.0 - (word.text.chars().count() as f64) * 4.0;
            return (
                History {
                    last: Some(language),
                    ..History::default()
                },
                Scores {
                    base: score,
                    personalized: score,
                },
            );
        }
        if let Some(pinned) = word.personal {
            let word_cost = (20.0 - 1.05 * 10_000_f64.ln()) / std::f64::consts::LN_2;
            let spelling_cost = if missing == 0 {
                0.0
            } else {
                completion_cost(self.model.config.spelling_scoring, missing)
            };
            let score = -word_cost - spelling_cost + f64::from(pinned);
            return (
                History {
                    last: Some(language),
                    ..History::default()
                },
                Scores {
                    base: score,
                    personalized: score,
                },
            );
        }
        let base = self.model.base;
        let mut priors = *word_score.unigram.get_or_init(|| self.model.unigram(word));
        for (observed, mass) in
            continuations(&mut self.contexts.base, base, previous.base, word.ids.base)
        {
            priors.base = smooth_base_gram(
                priors.base,
                observed,
                mass,
                self.model.config.statistical_scoring,
            );
            priors.personalized = smooth_base_gram(
                priors.personalized,
                observed,
                mass,
                self.model.config.statistical_scoring,
            );
        }
        if let Some(user) = self.model.user {
            for (observed, mass) in
                continuations(&mut self.contexts.user, user, previous.user, word.ids.user)
            {
                priors.personalized = boost_user_gram(
                    priors.personalized,
                    observed,
                    mass,
                    self.model.config.statistical_scoring,
                );
            }
        }
        let cost = if missing > 0 {
            completion_cost(self.model.config.spelling_scoring, missing)
        } else {
            0.0
        };
        let mut next = self.model.extend_history(previous, language, word.ids);
        if let Some(start) = next.start.as_mut() {
            *start = self.advance_start(*start, word.ids.base);
            start.maximum = self
                .start_maxima
                .get(&StartSpan {
                    end,
                    completion: missing > 0,
                    corrected,
                })
                .copied()
                .unwrap_or(0);
        }
        (
            next,
            Scores {
                base: probability_bits(priors.base) - cost,
                personalized: probability_bits(priors.personalized) - cost,
            },
        )
    }
}

impl Drop for ScoreSession<'_, '_> {
    fn drop(&mut self) {
        if let Ok(mut cached) = self.model.contexts.try_lock()
            && cached.is_none()
        {
            *cached = Some(std::mem::take(&mut self.contexts));
        }
    }
}

fn completion_cost(config: SpellingScoringConfig, missing: usize) -> f64 {
    if missing == 0 {
        0.0
    } else {
        config.completion_base_cost_bits
            + config.completion_missing_letter_cost_bits * missing as f64
    }
}

fn probability_bits(probability: f64) -> f64 {
    // Known zero-count words remain selectable with a finite score.
    probability.max(f64::MIN_POSITIVE).log2()
}

fn smooth_base_gram(prior: f64, count: f64, mass: f64, config: StatisticalScoringConfig) -> f64 {
    let weight = gram_weight(
        mass,
        config.base_word_gram_prior_count,
        config.word_gram_interpolation_weight_limit,
    );
    // Missing continuations still retain lower-order evidence, even for frequent histories.
    (1.0 - weight) * prior + weight * (count / mass)
}

fn start_reward(count: u64, maximum: u64, reward_limit: f64) -> f64 {
    if maximum == 0 {
        return 0.0;
    }
    let x = (count as f64 / maximum as f64).min(1.0);
    // Smoothstep joins the zero and full-reward plateaus with zero slope.
    reward_limit * x * x * (3.0 - 2.0 * x)
}

fn boost(prior: f64, probability: f64, weight: f64) -> f64 {
    prior + weight * (probability - prior).max(0.0)
}

fn boost_user_unigram(
    prior: f64,
    user: Corpus<'_>,
    count: f64,
    config: StatisticalScoringConfig,
) -> f64 {
    let weight = config.user_unigram_boost_weight_limit * user.total_count
        / (user.total_count + config.user_unigram_prior_count);
    boost(prior, user.frequency(count), weight)
}

fn boost_user_gram(prior: f64, count: f64, mass: f64, config: StatisticalScoringConfig) -> f64 {
    boost(
        prior,
        count / mass,
        gram_weight(
            mass,
            config.user_word_gram_prior_count,
            config.word_gram_interpolation_weight_limit,
        ),
    )
}

fn gram_weight(mass: f64, prior_mass: f64, weight_limit: f64) -> f64 {
    (mass / (mass + prior_mass)).min(weight_limit)
}

fn continuations<'cache, 'data>(
    cache: &'cache mut ContextCache<'data>,
    corpus: Corpus<'data>,
    history: HistoryIds,
    id: Option<WordId>,
) -> impl Iterator<Item = (f64, f64)> + 'cache
where
    'data: 'cache,
{
    corpus
        .grams
        .into_iter()
        .flat_map(move |grams| context_keys(history).map(move |key| (grams, key)))
        .filter_map(move |(grams, key)| {
            let row = prepare_context(cache, grams, key);
            if row.mass == 0.0 {
                return None;
            }
            let count = id.and_then(|id| row.context.count(id)).unwrap_or(0) as f64;
            Some((count, row.mass))
        })
}

fn context_keys(history: HistoryIds) -> impl Iterator<Item = ContextKey> {
    (1..=history.len).map(move |len| {
        let mut ids = [WordId(0); HISTORY_WORDS];
        for (destination, &source) in ids.iter_mut().zip(history.ids[..len].iter().rev()) {
            *destination = source;
        }
        ContextKey { ids, len }
    })
}

fn completion_continuations<'data>(
    cache: &mut ContextCache<'data>,
    grams: Option<&'data GramModel>,
    histories: impl Iterator<Item = HistoryIds>,
) -> HashMap<WordId, f64> {
    let mut continuations = HashMap::<WordId, f64>::new();
    let Some(grams) = grams else {
        return continuations;
    };
    let keys: HashSet<_> = histories.flat_map(context_keys).collect();
    for key in keys {
        let row = prepare_context(cache, grams, key);
        if row.mass > 0.0 {
            for (word, count) in row.context.continuations() {
                let fraction = count as f64 / row.mass;
                continuations
                    .entry(word)
                    .and_modify(|largest| *largest = largest.max(fraction))
                    .or_insert(fraction);
            }
        }
    }
    continuations
}

fn prepare_context<'cache, 'data>(
    cache: &'cache mut ContextCache<'data>,
    grams: &'data GramModel,
    key: ContextKey,
) -> &'cache Prepared<'data> {
    if cache.len() >= CONTEXT_CACHE_CAPACITY && !cache.contains_key(&key) {
        cache.clear();
    }
    cache.entry(key).or_insert_with(|| {
        let context = grams.context(&key.ids[..key.len]);
        let mass = context.continuations().map(|(_, count)| count as f64).sum();
        Prepared { context, mass }
    })
}

#[cfg(test)]
mod tests {
    use super::{
        Corpus, History, HistoryIds, Scores, StartHistory, boost_user_gram, boost_user_unigram,
        smooth_base_gram, start_reward,
    };
    use crate::resources::EngineConfig;
    use si_lexicon::Lexicon;

    #[test]
    fn configured_statistical_priors_and_caps_control_their_probability_components() {
        let original = EngineConfig::default().statistical_scoring;
        let mut custom = original;
        let prior = 0.01;
        let baseline = smooth_base_gram(prior, 16.0, 32.0, original);
        custom.base_word_gram_prior_count = 64.0;
        assert!(smooth_base_gram(prior, 16.0, 32.0, custom) < baseline);
        custom = original;
        custom.word_gram_interpolation_weight_limit = 0.25;
        assert!(smooth_base_gram(prior, 16.0, 32.0, custom) < baseline);
        let baseline = boost_user_gram(prior, 16.0, 32.0, original);
        custom = original;
        custom.user_word_gram_prior_count = 64.0;
        assert!(boost_user_gram(prior, 16.0, 32.0, custom) < baseline);
        custom = original;
        custom.word_gram_interpolation_weight_limit = 0.0;
        assert_eq!(boost_user_gram(prior, 16.0, 32.0, custom), prior);

        let lexicon = Lexicon::new();
        let corpus = Corpus {
            lexicon: &lexicon,
            grams: None,
            history_limit: 3,
            total_count: 32.0,
        };
        let baseline = boost_user_unigram(prior, corpus, 16.0, original);
        custom = original;
        custom.user_unigram_prior_count = 64.0;
        assert!(boost_user_unigram(prior, corpus, 16.0, custom) < baseline);
        custom = original;
        custom.user_unigram_boost_weight_limit = 0.0;
        assert_eq!(boost_user_unigram(prior, corpus, 16.0, custom), prior);
    }

    #[test]
    fn sentence_start_adjustments_and_pruning_bounds_share_the_configured_limit() {
        let history = History {
            start: Some(StartHistory {
                history: HistoryIds::default(),
                remaining: 1,
                count: 50,
                maximum: 100,
            }),
            ..History::default()
        };
        for limit in [0.0, 2.0, 8.0] {
            assert_eq!(history.start_adjustment(limit).unwrap().base, limit / 2.0);
            assert_eq!(history.context_upper(Scores::default(), limit).base, limit);
            assert_eq!(start_reward(100, 100, limit), limit);
        }
    }

    #[test]
    fn sentence_start_reward_uses_relative_probability_and_scales_with_the_pool() {
        assert_eq!(start_reward(0, 0, 2.0), 0.0);
        assert_eq!(start_reward(0, 100, 2.0), 0.0);
        let mut previous = -1.0;
        for (count, expected) in [
            (0, 0.0),
            (1, 0.000596),
            (25, 0.3125),
            (50, 1.0),
            (75, 1.6875),
            (100, 2.0),
        ] {
            let reward = start_reward(count, 100, 2.0);
            assert!((reward - expected).abs() < 1e-12);
            assert!(reward > previous && reward <= 2.0);
            assert_eq!(reward, start_reward(count * 7, 700, 2.0));
            previous = reward;
        }
        assert_eq!(start_reward(u64::MAX, u64::MAX, 2.0), 2.0);
        assert_eq!(start_reward(101, 100, 2.0), 2.0);
    }
}
