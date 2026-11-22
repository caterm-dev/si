use std::cell::OnceCell;
use std::collections::{HashMap, HashSet};
use std::hash::BuildHasherDefault;
use std::sync::Mutex;

use si_gram::{Context, GramModel, MAX_ORDER};
use si_lexicon::{Lexicon, WordId};

use super::cache::IdHasher;
use super::lookup::Lexeme;
use super::{Language, WordIds};
use crate::resources::EngineResources;

const USER_UNIGRAM_PRIOR: f64 = 32.0;
const USER_UNIGRAM_LIMIT: f64 = 0.8;
const BASE_GRAM_PRIOR: f64 = 32.0;
const USER_GRAM_PRIOR: f64 = 8.0;
const GRAM_WEIGHT_LIMIT: f64 = 0.8;
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
    base: Corpus<'a>,
    user: Option<Corpus<'a>>,
    contexts: Mutex<Option<ContextCaches<'a>>>,
}

impl<'a> Scoring<'a> {
    pub(super) fn new(base: &'a EngineResources, user: Option<&'a EngineResources>) -> Self {
        let base = Corpus::new(base);
        let user = user
            .map(Corpus::new)
            .filter(|corpus| !corpus.lexicon.is_empty());
        Self {
            base,
            user,
            contexts: Mutex::new(Some(ContextCaches::default())),
        }
    }

    pub(super) fn has_user(&self) -> bool {
        self.user.is_some()
    }

    pub(super) fn unigram(&self, word: Lexeme<'_>) -> Scores {
        let base = self.base.frequency(self.base.count(word.ids.base));
        Scores {
            base,
            personalized: self.user.map_or(base, |user| {
                boost_user_unigram(base, user, user.count(word.ids.user))
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
        }
    }

    pub(super) fn session(&self, initial_history: History) -> ScoreSession<'_, 'a> {
        ScoreSession {
            model: self,
            initial_history,
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

#[derive(Clone, Copy, Default, Eq, PartialEq)]
pub(super) struct History {
    base: HistoryIds,
    user: HistoryIds,
    last: Option<Language>,
}

impl History {
    pub(super) fn from_field(base: Self, user: Self) -> Self {
        Self {
            base: base.base,
            user: user.user,
            last: base.last.or(user.last),
        }
    }

    pub(super) fn last(self) -> Option<Language> {
        self.last
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
    initial_history: History,
    contexts: ContextCaches<'data>,
}

impl ScoreSession<'_, '_> {
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
        probability_bits(upper) - (4.0 + missing as f64) + 1e-9
    }

    pub(super) fn has_user(&self) -> bool {
        self.model.has_user()
    }

    pub(super) fn start(&mut self, word: Lexeme<'_>, missing: usize) -> (History, Scores, Scores) {
        let word_score = WordScore::new(word);
        let (history, scores) = self.step(History::default(), &word_score, missing);
        let mut adjustment = Scores::default();
        let preceding = self.initial_history;
        if (preceding.base.len > 0 || preceding.user.len > 0)
            && word.personal.is_none()
            && !word.verbatim
        {
            // Compare the same first word with and without preceding grams, using the same costs.
            let (_, conditioned) = self.step(preceding, &word_score, missing);
            adjustment.base = conditioned.base - scores.base;
            adjustment.personalized = conditioned.personalized - scores.personalized;
        }
        (history, scores, adjustment)
    }

    pub(super) fn step(
        &mut self,
        previous: History,
        word_score: &WordScore<'_>,
        missing: usize,
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
                4.0 + missing as f64
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
            priors.base = smooth_base_gram(priors.base, observed, mass);
            priors.personalized = smooth_base_gram(priors.personalized, observed, mass);
        }
        if let Some(user) = self.model.user {
            for (observed, mass) in
                continuations(&mut self.contexts.user, user, previous.user, word.ids.user)
            {
                priors.personalized = boost_user_gram(priors.personalized, observed, mass);
            }
        }
        let cost = if missing > 0 {
            4.0 + missing as f64
        } else {
            0.0
        };
        let next = self.model.extend_history(previous, language, word.ids);
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

fn probability_bits(probability: f64) -> f64 {
    // Known zero-count words remain selectable with a finite score.
    probability.max(f64::MIN_POSITIVE).log2()
}

fn smooth_base_gram(prior: f64, count: f64, mass: f64) -> f64 {
    let weight = gram_weight(mass, BASE_GRAM_PRIOR);
    // Missing continuations still retain lower-order evidence, even for frequent histories.
    (1.0 - weight) * prior + weight * (count / mass)
}

fn boost(prior: f64, probability: f64, weight: f64) -> f64 {
    prior + weight * (probability - prior).max(0.0)
}

fn boost_user_unigram(prior: f64, user: Corpus<'_>, count: f64) -> f64 {
    let weight = USER_UNIGRAM_LIMIT * user.total_count / (user.total_count + USER_UNIGRAM_PRIOR);
    boost(prior, user.frequency(count), weight)
}

fn boost_user_gram(prior: f64, count: f64, mass: f64) -> f64 {
    boost(prior, count / mass, gram_weight(mass, USER_GRAM_PRIOR))
}

fn gram_weight(mass: f64, prior_mass: f64) -> f64 {
    (mass / (mass + prior_mass)).min(GRAM_WEIGHT_LIMIT)
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
