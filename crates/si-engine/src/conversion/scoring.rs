use std::collections::HashMap;

use si_gram::{Context, GramModel, MAX_ORDER};
use si_lexicon::{Lexicon, WordId};

use super::Language;
use super::lookup::{Lexeme, Lookup};
use crate::han;
use crate::resources::EngineResources;

const USER_UNIGRAM_PRIOR: f64 = 32.0;
const USER_UNIGRAM_LIMIT: f64 = 0.8;
const BASE_GRAM_PRIOR: f64 = 32.0;
const USER_GRAM_PRIOR: f64 = 8.0;
const USER_GRAM_LIMIT: f64 = 0.8;
const HISTORY_WORDS: usize = MAX_ORDER - 1;
const LANGUAGE_START_BITS: f64 = 1.0;
const LANGUAGE_SWITCH_BITS: f64 = 4.0;
const ENGLISH_TOKEN_BITS: f64 = 1.0;
const HAN_CHARACTER_BITS: f64 = 2.0 / std::f64::consts::LN_2;

#[derive(Clone, Copy, Default)]
struct Vocabulary {
    count: f64,
    types: f64,
}

#[derive(Clone, Copy)]
struct Corpus<'a> {
    lexicon: &'a Lexicon,
    grams: Option<&'a GramModel>,
    history_limit: usize,
    vocabulary: [Vocabulary; 2],
}

impl<'a> Corpus<'a> {
    fn new(resources: &'a EngineResources) -> Self {
        let mut vocabulary = [Vocabulary::default(); 2];
        for word in resources.lexicon().words() {
            if let Some(language) = word
                .reading
                .and_then(|reading| Language::from_index(reading.index))
            {
                let total = &mut vocabulary[language as usize];
                total.count += word.count as f64;
                total.types += 1.0;
            }
        }
        let grams = resources.grams();
        // Preserve the existing search history for models through order four.
        let history_limit = grams
            .and_then(|grams| grams.sizes().iter().rposition(|&size| size != 0))
            .map_or(3, |order_index| (order_index + 1).max(3));
        Self {
            lexicon: resources.lexicon(),
            grams,
            history_limit,
            vocabulary,
        }
    }

    fn count(self, id: Option<WordId>) -> f64 {
        id.and_then(|id| self.lexicon.word(id))
            .map_or(0.0, |word| word.count as f64)
    }
}

pub(super) struct Scoring<'a> {
    base: Corpus<'a>,
    user: Option<Corpus<'a>>,
    user_only_types: [f64; 2],
}

impl<'a> Scoring<'a> {
    pub(super) fn new(
        base: &'a EngineResources,
        user: Option<&'a EngineResources>,
        lookup: &Lookup<'_>,
    ) -> Self {
        let base = Corpus::new(base);
        let user = user
            .map(Corpus::new)
            .filter(|corpus| !corpus.lexicon.is_empty());
        let mut user_only_types = [0.0; 2];
        if let Some(user) = user {
            for word in user.lexicon.words().filter(|word| !lookup.paired(word.id)) {
                if let Some(language) = word
                    .reading
                    .and_then(|reading| Language::from_index(reading.index))
                {
                    user_only_types[language as usize] += 1.0;
                }
            }
        }
        Self {
            base,
            user,
            user_only_types,
        }
    }

    pub(super) fn has_user(&self) -> bool {
        self.user.is_some()
    }

    pub(super) fn session(&self) -> ScoreSession<'_, 'a> {
        ScoreSession {
            model: self,
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
    pub(super) fn last(self) -> Option<Language> {
        self.last
    }
}

#[derive(Clone, Copy, Eq, Hash, PartialEq)]
struct ContextKey {
    ids: [WordId; HISTORY_WORDS],
    len: usize,
    language: Language,
}

struct Prepared<'a> {
    context: Context<'a>,
    mass: f64,
}

type ContextCache<'a> = HashMap<ContextKey, Prepared<'a>>;

pub(super) struct ScoreSession<'model, 'data> {
    model: &'model Scoring<'data>,
    base_cache: ContextCache<'data>,
    user_cache: ContextCache<'data>,
}

impl ScoreSession<'_, '_> {
    pub(super) fn step(
        &mut self,
        previous: History,
        word: Lexeme<'_>,
        missing: usize,
    ) -> (History, Scores) {
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
            let score = -word_cost - spelling_cost - language_cost(previous.last, language)
                + f64::from(pinned);
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
        let history = if previous.last == Some(language) {
            previous
        } else {
            History::default()
        };
        let base = self.model.base;
        let vocab = base.vocabulary[language as usize];
        let base_count = base.count(word.ids.base) + 1.0;
        let base_prior = base_count / (vocab.count + vocab.types).max(1.0);
        let mut priors = Scores {
            base: base_prior,
            personalized: base_prior,
        };
        if let Some(user) = self.model.user {
            let user_vocab = user.vocabulary[language as usize];
            let union_mass =
                vocab.count + vocab.types + self.model.user_only_types[language as usize];
            let union_prior = base_count / union_mass.max(1.0);
            let user_weight =
                USER_UNIGRAM_LIMIT * user_vocab.count / (user_vocab.count + USER_UNIGRAM_PRIOR);
            let user_probability = user.count(word.ids.user) / user_vocab.count.max(1.0);
            priors.personalized = blend(union_prior, user_probability, user_weight);
        }
        for (observed, mass) in continuations(
            &mut self.base_cache,
            base,
            history.base,
            word,
            word.ids.base,
        ) {
            let total = mass + BASE_GRAM_PRIOR;
            priors.base = (observed + BASE_GRAM_PRIOR * priors.base) / total;
            priors.personalized = (observed + BASE_GRAM_PRIOR * priors.personalized) / total;
        }
        if let Some(user) = self.model.user {
            for (observed, mass) in continuations(
                &mut self.user_cache,
                user,
                history.user,
                word,
                word.ids.user,
            ) {
                let weight = (mass / (mass + USER_GRAM_PRIOR)).min(USER_GRAM_LIMIT);
                priors.personalized = blend(priors.personalized, observed / mass, weight);
            }
        }
        let mut cost = language_cost(previous.last, language);
        cost += match language {
            Language::English => ENGLISH_TOKEN_BITS,
            Language::Chinese if han::single(word.text).is_some() => HAN_CHARACTER_BITS,
            Language::Chinese => 0.0,
        };
        if missing > 0 {
            cost += 4.0 + missing as f64;
        }
        let next = History {
            base: history.base.with_word(word.ids.base, base.history_limit),
            user: history.user.with_word(
                word.ids.user,
                self.model.user.map_or(3, |user| user.history_limit),
            ),
            last: Some(language),
        };
        (
            next,
            Scores {
                base: priors.base.log2() - cost,
                personalized: priors.personalized.log2() - cost,
            },
        )
    }
}

fn language_cost(previous: Option<Language>, next: Language) -> f64 {
    match previous {
        None => LANGUAGE_START_BITS,
        Some(last) if last != next => LANGUAGE_SWITCH_BITS,
        Some(_) => 0.0,
    }
}

fn blend(prior: f64, probability: f64, weight: f64) -> f64 {
    (1.0 - weight) * prior + weight * probability
}

fn continuations<'cache, 'data>(
    cache: &'cache mut ContextCache<'data>,
    corpus: Corpus<'data>,
    history: HistoryIds,
    word: Lexeme<'_>,
    id: Option<WordId>,
) -> impl Iterator<Item = (f64, f64)> + 'cache
where
    'data: 'cache,
{
    let language = word.language;
    corpus
        .grams
        .into_iter()
        .flat_map(move |grams| {
            (1..=history.len).map(move |len| {
                let mut ids = [WordId(0); HISTORY_WORDS];
                for (destination, &source) in ids.iter_mut().zip(history.ids[..len].iter().rev()) {
                    *destination = source;
                }
                (grams, ContextKey { ids, len, language })
            })
        })
        .filter_map(move |(grams, key)| {
            let row = cache.entry(key).or_insert_with(|| {
                let context = grams.context(&key.ids[..key.len]);
                let mass = context
                    .continuations()
                    .filter(|(id, _)| {
                        corpus
                            .lexicon
                            .word(*id)
                            .and_then(|word| word.reading)
                            .and_then(|reading| Language::from_index(reading.index))
                            == Some(language)
                    })
                    .map(|(_, count)| count as f64)
                    .sum();
                Prepared { context, mass }
            });
            if row.mass == 0.0 {
                return None;
            }
            let count = id.and_then(|id| row.context.count(id)).unwrap_or(0) as f64;
            Some((count, row.mass))
        })
}
