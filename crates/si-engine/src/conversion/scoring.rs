mod features;

use std::cell::OnceCell;
use std::collections::{HashMap, HashSet};

use si_gram::{Context, GramModel, MAX_ORDER};
use si_lexicon::{Lexicon, WordId};

use super::lookup::Lexeme;
use super::{Language, WordIds};
use crate::han;
use crate::ranking_features::PathEvidence;
use crate::resources::EngineResources;

const USER_UNIGRAM_PRIOR: f64 = 32.0;
const USER_UNIGRAM_LIMIT: f64 = 0.8;
const BASE_GRAM_PRIOR: f64 = 32.0;
const USER_GRAM_PRIOR: f64 = 8.0;
const GRAM_WEIGHT_LIMIT: f64 = 0.8;
const HISTORY_WORDS: usize = MAX_ORDER - 1;

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
}

impl<'a> Scoring<'a> {
    pub(super) fn new(base: &'a EngineResources, user: Option<&'a EngineResources>) -> Self {
        let base = Corpus::new(base);
        let user = user
            .map(Corpus::new)
            .filter(|corpus| !corpus.lexicon.is_empty());
        Self { base, user }
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

    pub(super) fn session(
        &self,
        initial_history: History,
        capture_evidence: bool,
    ) -> ScoreSession<'_, 'a> {
        ScoreSession {
            model: self,
            capture_evidence,
            evidence: None,
            initial_history,
            base_cache: HashMap::new(),
            user_cache: HashMap::new(),
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
        self.ids[..limit].rotate_right(1);
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

type ContextCache<'a> = HashMap<ContextKey, Prepared<'a>>;

pub(super) struct CompletionBounds {
    continuations: HashMap<WordId, f64>,
}

pub(super) struct ScoreSession<'model, 'data> {
    model: &'model Scoring<'data>,
    capture_evidence: bool,
    evidence: Option<Box<PathEvidence>>,
    initial_history: History,
    base_cache: ContextCache<'data>,
    user_cache: ContextCache<'data>,
}

impl ScoreSession<'_, '_> {
    pub(super) fn completion_bounds(
        &mut self,
        histories: impl Iterator<Item = History>,
    ) -> Option<CompletionBounds> {
        // Personalized grams have a separate vocabulary and interpolation.
        let corpus = self.model.base;
        if self.model.user.is_some() {
            return None;
        }
        let mut continuations = HashMap::<WordId, f64>::new();
        if let Some(grams) = corpus.grams {
            let keys: HashSet<_> = histories
                .flat_map(|history| context_keys(history.base))
                .collect();
            for key in keys {
                let row = prepare_context(&mut self.base_cache, grams, key);
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
        }
        Some(CompletionBounds { continuations })
    }

    pub(super) fn completion_upper_bits(
        &self,
        bounds: Option<&CompletionBounds>,
        word: &WordScore<'_>,
        missing: usize,
    ) -> f64 {
        let logp = bounds.map_or(0.0, |bounds| {
            let unigram = word
                .unigram
                .get_or_init(|| self.model.unigram(word.word))
                .base;
            let observed = word
                .word
                .ids
                .base
                .and_then(|id| bounds.continuations.get(&id))
                .copied()
                .unwrap_or_default();
            // Each smoothing step is a weighted average of the old prior and
            // count / mass. The largest of those inputs bounds the final prior.
            probability_bits(unigram.max(observed))
        });
        // Allow for accumulated rounding in smoothing and the optimistic score.
        logp - (4.0 + missing as f64) + 1e-9
    }

    pub(super) fn take_evidence(&mut self) -> Option<Box<PathEvidence>> {
        self.evidence.take()
    }

    pub(super) fn has_user(&self) -> bool {
        self.model.has_user()
    }

    pub(super) fn start(&mut self, word: Lexeme<'_>, missing: usize) -> (History, Scores, Scores) {
        let word_score = WordScore::new(word);
        let (history, scores) = self.step(History::default(), &word_score, missing);
        let mut evidence = self.evidence.take();
        let mut adjustment = Scores::default();
        let preceding = self.initial_history;
        if (preceding.base.len > 0 || preceding.user.len > 0)
            && word.personal.is_none()
            && !word.verbatim
        {
            // Compare the same first word with and without preceding grams, using the same costs.
            let (_, conditioned) = self.step(preceding, &word_score, missing);
            if let (Some(base), Some(context)) = (&mut evidence, self.evidence.take()) {
                base.context_history_words = preceding.base.len;
                base.context_matched = context.gram_hit_tokens > 0;
                base.context_gram_order = context.max_gram_order;
                base.context_log_support = context.gram_log_support;
            }
            adjustment.base = conditioned.base - scores.base;
            adjustment.personalized = conditioned.personalized - scores.personalized;
        }
        self.evidence = evidence;
        (history, scores, adjustment)
    }

    pub(super) fn step(
        &mut self,
        previous: History,
        word_score: &WordScore<'_>,
        missing: usize,
    ) -> (History, Scores) {
        self.evidence = None;
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
        let base_prior = priors.base;
        let mut gram_order = 0;
        let mut gram_support = 0.0;
        for (observed, mass, order) in
            continuations(&mut self.base_cache, base, previous.base, word.ids.base)
        {
            if self.capture_evidence && observed > 0.0 {
                gram_order = order;
                gram_support = observed;
            }
            priors.base = smooth_base_gram(priors.base, observed, mass);
            priors.personalized = smooth_base_gram(priors.personalized, observed, mass);
        }
        if let Some(user) = self.model.user {
            for (observed, mass, _) in
                continuations(&mut self.user_cache, user, previous.user, word.ids.user)
            {
                priors.personalized = boost_user_gram(priors.personalized, observed, mass);
            }
        }
        let cost = if missing > 0 {
            4.0 + missing as f64
        } else {
            0.0
        };
        if self.capture_evidence {
            let scalars = word.text.chars().count();
            self.evidence = Some(Box::new(PathEvidence {
                words: vec![crate::ranking_features::EvidenceWord {
                    language: language as u8,
                    base: word.ids.base,
                    user: word.ids.user,
                }],
                chinese_tokens: usize::from(language == Language::Chinese),
                missing_letters: missing,
                gram_model_available: base.grams.is_some(),
                unigram_bits: probability_bits(base_prior),
                gram_adjustment_bits: probability_bits(priors.base) - probability_bits(base_prior),
                spelling_cost_bits: cost,
                gram_hit_tokens: usize::from(gram_order > 0),
                max_gram_order: gram_order,
                gram_log_support: gram_support.ln_1p(),
                tokens: 1,
                single_character_tokens: usize::from(
                    language == Language::Chinese && han::single(word.text).is_some(),
                ),
                min_token_scalars: scalars,
                max_token_scalars: scalars,
                language_switches: usize::from(
                    previous.last.is_some_and(|previous| previous != language),
                ),
                ..Default::default()
            }));
        }
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
) -> impl Iterator<Item = (f64, f64, usize)> + 'cache
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
            Some((count, row.mass, key.len + 1))
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

fn prepare_context<'cache, 'data>(
    cache: &'cache mut ContextCache<'data>,
    grams: &'data GramModel,
    key: ContextKey,
) -> &'cache Prepared<'data> {
    cache.entry(key).or_insert_with(|| {
        let context = grams.context(&key.ids[..key.len]);
        let mass = context.continuations().map(|(_, count)| count as f64).sum();
        Prepared { context, mass }
    })
}
