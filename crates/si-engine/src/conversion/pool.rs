//! Offline exact-path enumeration and post-search scoring-pool experiments.
//! Ordinary conversion does not construct this inspector or change its beams.

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};
use std::rc::Rc;

use super::input::Input;
use super::lookup::{Lookup, Match};
use super::scoring::{History, ScoreSession, Scores, WordScore};
use super::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionBoundary, ConversionOptions,
    ConversionPreferences, CorrectionSensitivity, EnabledLanguages, Language, MAX_OUTPUT_BYTES,
    PrecedingTextCache,
};

const MAX_UNITS: usize = 128;
const MAX_EDGES: usize = 65_536;
const MAX_FRONTIER: usize = 100_000;
// Covers accumulated rounding over at most 128 bounded lexical steps.
const UPPER_SLACK: f64 = 1e-7;

#[derive(Clone, Copy, Debug)]
pub struct PoolOptions {
    pub k_best: usize,
    pub pool_size: usize,
    pub structure_limit: usize,
    pub multiword_limit: usize,
    pub search_budget: usize,
}

impl Default for PoolOptions {
    fn default() -> Self {
        Self {
            k_best: 256,
            pool_size: 12,
            structure_limit: 2,
            multiword_limit: 12,
            search_budget: 100_000,
        }
    }
}

impl PoolOptions {
    pub fn validate(self) -> Result<Self, &'static str> {
        if !(1..=512).contains(&self.k_best)
            || !(1..=64).contains(&self.pool_size)
            || self.structure_limit > 2
            || self.multiword_limit > self.pool_size
            || !(1..=1_000_000).contains(&self.search_budget)
        {
            return Err(
                "Invalid pool limits: k-best 1..512, pool 1..64, structure 0..2, multiword 0..pool, budget 1..1000000",
            );
        }
        Ok(self)
    }
}

#[derive(Clone, Debug)]
pub struct PoolToken {
    pub text: String,
    pub language: CandidateLanguage,
    pub source_start: usize,
    pub source_end: usize,
    pub word_id: u32,
    pub count: u64,
    pub unigram_bits: f64,
    pub gram_bits: f64,
    pub context_bits: f64,
    pub spelling_bits: f64,
    pub structural_single: bool,
    cuts: Vec<usize>,
    output_start: usize,
}

#[derive(Clone, Debug)]
pub struct PoolEntry {
    pub candidate: Candidate,
    pub tokens: Vec<PoolToken>,
    pub native_rank: Option<usize>,
    pub native_eligible: bool,
    pub native_score: Option<f64>,
    pub k_best_rank: Option<usize>,
    pub k_best_score: Option<f64>,
    pub trace_matches_candidate: bool,
    pub eligible: bool,
    pub structure_kept: bool,
    pub quota_kept: bool,
    pub selected: bool,
    pub exclusion: &'static str,
    /// Indices into CandidatePool.entries, allowing review of structural replacements.
    pub blocked_by: Vec<usize>,
}

#[derive(Debug)]
pub struct CandidatePool {
    /// The unmodified conversion result, including prefixes and the original literal.
    pub native: Vec<Candidate>,
    /// Union of native whole results and the expanded exact k-best, in score order.
    pub entries: Vec<PoolEntry>,
    pub complete: bool,
    pub certified: usize,
    pub expanded: usize,
    pub frontier_peak: usize,
    pub edges: usize,
    pub bound_states: usize,
    pub bound_steps: usize,
    pub stop: &'static str,
}

pub struct CandidatePoolInspector<'engine, 'data> {
    engine: &'engine CandidateEngine<'data>,
    upper: Vec<f64>,
}

impl<'engine, 'data> CandidatePoolInspector<'engine, 'data> {
    /// Prepare immutable base-gram upper bounds once, outside conversion.
    pub fn new(engine: &'engine CandidateEngine<'data>) -> Result<Self, &'static str> {
        if engine.scoring.has_user() {
            return Err("Pool inspection requires an empty personal profile");
        }
        Ok(Self {
            engine,
            upper: engine.scoring.lexical_upper_scores(),
        })
    }

    pub fn inspect(
        &self,
        source: &str,
        languages: EnabledLanguages,
        preceding: Option<&str>,
        correction: Option<CorrectionSensitivity>,
        options: PoolOptions,
    ) -> Result<CandidatePool, &'static str> {
        let options = options.validate()?;
        let cache = PrecedingTextCache::default();
        let native = self.engine.convert_with_cached_context(
            source,
            languages,
            false,
            &[],
            ConversionPreferences::default(),
            preceding,
            ConversionOptions {
                correction,
                reranker: None,
            },
            Some(&cache),
        );
        let mut result = self.enumerate(source, languages, preceding, correction, options, &cache);
        let mut entries: Vec<PoolEntry> = Vec::new();
        let mut indices = HashMap::new();
        for (rank, row) in native
            .iter()
            .filter(|row| {
                row.consumed_bytes == source.len() && row.language != CandidateLanguage::Literal
            })
            .enumerate()
        {
            indices.insert((row.language, row.text.clone()), entries.len());
            let mut original = entry(row.clone(), Vec::new(), Some(rank + 1), None);
            original.native_eligible = super::reranking::eligible(
                row.personal,
                row.verbatim,
                row.is_corrected(),
                row.completion,
                row.text.len(),
                self.engine
                    .config
                    .local_model_ranking
                    .model_candidate_token_limit
                    * 4,
            );
            entries.push(original);
        }
        for (rank, path) in result.rows.drain(..).enumerate() {
            let identity = (path.candidate.language, path.candidate.text.clone());
            if let Some(&index) = indices.get(&identity) {
                let row = &mut entries[index];
                row.k_best_rank = Some(rank + 1);
                row.k_best_score = Some(total(&path.candidate));
                row.trace_matches_candidate =
                    total(&path.candidate) + 1e-10 >= total(&row.candidate);
                row.tokens = path.tokens;
                // The exact graph can find a stronger derivation than the beam.
                // Do not attribute an exact trace to a different native score.
                if row.trace_matches_candidate {
                    row.candidate = path.candidate;
                }
            } else {
                indices.insert(identity, entries.len());
                entries.push(entry(path.candidate, path.tokens, None, Some(rank + 1)));
            }
        }
        entries.sort_by(|a, b| compare(&a.candidate, &b.candidate));
        select(
            &mut entries,
            options,
            self.engine
                .config
                .local_model_ranking
                .model_candidate_token_limit
                * 4,
        );
        Ok(CandidatePool {
            native,
            entries,
            complete: result.complete,
            certified: result.certified,
            expanded: result.expanded,
            frontier_peak: result.frontier_peak,
            edges: result.edges,
            bound_states: result.bound_states,
            bound_steps: result.bound_steps,
            stop: result.stop,
        })
    }

    fn enumerate(
        &self,
        source: &str,
        languages: EnabledLanguages,
        preceding: Option<&str>,
        correction: Option<CorrectionSensitivity>,
        options: PoolOptions,
        cache: &PrecedingTextCache,
    ) -> Enumeration {
        let input = Input::new(source);
        let length = input.len();
        let mut result = Enumeration {
            stop: "complete",
            ..Enumeration::default()
        };
        if length > MAX_UNITS {
            result.stop = "input-limit";
            return result;
        }
        if length == 0 {
            result.complete = true;
            return result;
        }
        let mut graph = vec![Vec::new(); length];
        for (start, edges) in graph.iter_mut().enumerate() {
            for language in Language::ALL
                .into_iter()
                .filter(|language| language.enabled(languages))
            {
                self.engine
                    .lookup
                    .visit(language, &input, start, length, |edge| {
                        if edge.missing == 0
                            && !edge.is_abbreviated()
                            && edge.correction_cost == 0.0
                        {
                            result.edges += 1;
                            if result.edges <= MAX_EDGES {
                                edges.push(edge);
                            }
                        }
                    });
            }
            if result.edges > MAX_EDGES {
                result.stop = "edge-limit";
                return result;
            }
        }
        // Backward Viterbi on optimistic edge scores. Every actual base lexical
        // transition is <= this edge maximum over all bigram/trigram histories.
        let mut suffix = vec![f64::NEG_INFINITY; length + 1];
        suffix[length] = 0.0;
        for start in (0..length).rev() {
            for edge in &graph[start] {
                let upper = self.upper[edge.word.ids.base.unwrap().0 as usize];
                suffix[start] = suffix[start].max(upper + suffix[edge.end]);
            }
        }
        if !suffix[0].is_finite() {
            result.complete = true;
            return result;
        }
        for edges in &mut graph {
            edges.sort_by(|a, b| {
                let bound = |edge: &Match<'_>| {
                    self.upper[edge.word.ids.base.unwrap().0 as usize] + suffix[edge.end]
                };
                bound(b).total_cmp(&bound(a))
            });
        }
        let field = self
            .engine
            .context
            .as_ref()
            .map_or_else(Default::default, |context| {
                context.history(preceding, &self.engine.scoring, Some(cache))
            });
        let mut scoring = self.engine.scoring.session(field);
        let personal = Lookup::personal(&[], self.engine.config);
        let maxima = super::start_competition::prepare(
            &input,
            length,
            languages,
            &self.engine.lookup,
            &personal,
            &mut scoring,
            correction.is_some()
                && languages.chinese
                && length >= 4
                && input
                    .spelling(Language::Chinese)
                    .iter()
                    .all(|&byte| byte != 0)
                && !source.chars().any(char::is_uppercase),
        );
        scoring.set_start_maxima(maxima);
        let mut frontier = BinaryHeap::new();
        let mut sequence = 0;
        let mut finished: HashMap<(CandidateLanguage, String), ExactPath> = HashMap::new();
        let start_cap = self
            .engine
            .config
            .statistical_scoring
            .sentence_start_reward_limit_bits;
        let bound_budget = options.search_budget.saturating_mul(10).min(2_000_000);
        let mut bounds = SuffixBounds {
            graph: &graph,
            suffix: &suffix,
            lexical: &self.upper,
            cache: HashMap::new(),
            remaining: bound_budget,
            start_cap,
        };
        let root = Node {
            end: 0,
            score: Scores::default(),
            context: Scores::default(),
            history: History::default(),
            mask: 0,
            output: String::new(),
            trace: None,
            refined: true,
        };
        frontier.push(Agenda {
            bound: f64::INFINITY,
            sequence,
            node: root,
        });
        let mut cutoff = f64::NEG_INFINITY;
        let mut stopped = false;
        while let Some(item) = frontier.peek() {
            if finished.len() >= options.k_best && item.bound < cutoff {
                break;
            }
            if result.expanded >= options.search_budget {
                result.stop = "expansion-limit";
                stopped = true;
                break;
            }
            let mut node = frontier.pop().unwrap().node;
            if !node.refined && node.end != length {
                let remaining = bounds.get(node.end, node.history, &mut scoring);
                let bound =
                    node.score.personalized + node.context.personalized + remaining + UPPER_SLACK;
                node.refined = true;
                sequence += 1;
                frontier.push(Agenda {
                    bound,
                    sequence,
                    node,
                });
                continue;
            }
            if node.end == length {
                let path = node.finish(source.len());
                let key = (path.candidate.language, path.candidate.text.clone());
                match finished.entry(key) {
                    std::collections::hash_map::Entry::Vacant(row) => {
                        row.insert(path);
                    }
                    std::collections::hash_map::Entry::Occupied(mut row) => {
                        let direct = row.get().candidate.lexical_tokens == 1
                            || path.candidate.lexical_tokens == 1;
                        if total(&path.candidate) > total(&row.get().candidate) {
                            row.insert(path);
                        } else if total(&path.candidate) == total(&row.get().candidate) {
                            row.get_mut()
                                .candidate
                                .confirmation_boundaries
                                .retain(|boundary| {
                                    path.candidate.confirmation_boundaries.contains(boundary)
                                });
                        }
                        if direct {
                            row.get_mut().candidate.lexical_tokens = 1;
                        }
                    }
                }
                if finished.len() >= options.k_best {
                    let mut scores: Vec<_> =
                        finished.values().map(|row| total(&row.candidate)).collect();
                    scores.sort_by(|a, b| b.total_cmp(a));
                    cutoff = scores[options.k_best - 1];
                    // Bound retained finished rows even when there are many ties.
                    if finished.len() > options.k_best * 2 {
                        let mut ordered: Vec<_> = finished.into_values().collect();
                        ordered.sort_by(|a, b| compare(&a.candidate, &b.candidate));
                        ordered.truncate(options.k_best);
                        finished = ordered
                            .into_iter()
                            .map(|row| ((row.candidate.language, row.candidate.text.clone()), row))
                            .collect();
                    }
                }
                continue;
            }
            result.expanded += 1;
            for &edge in &graph[node.end] {
                if !suffix[edge.end].is_finite() {
                    continue;
                }
                let surface = super::search::render(edge, input.source_span(node.end, edge.end));
                let space = node.end != 0
                    && (edge.word.language == Language::English
                        || node.history.last() == Some(Language::English));
                let output_start = node.output.len() + usize::from(space);
                if output_start + surface.len() > MAX_OUTPUT_BYTES
                    && !(node.end == 0 && edge.end == length)
                {
                    continue;
                }
                let (history, delta, context) = if node.end == 0 {
                    scoring.start(edge.word, 0, edge.end, false)
                } else {
                    let (history, delta) =
                        scoring.step(node.history, &WordScore::new(edge.word), 0, edge.end, false);
                    (
                        history,
                        delta,
                        history.start_adjustment(start_cap).unwrap_or(node.context),
                    )
                };
                let score = node.score + delta;
                let optimistic_context = if edge.end == length {
                    context
                } else {
                    history.context_upper(context, start_cap)
                };
                let bound = score.personalized
                    + optimistic_context.personalized
                    + suffix[edge.end]
                    + UPPER_SLACK;
                if finished.len() >= options.k_best && bound < cutoff {
                    continue;
                }
                if frontier.len() == MAX_FRONTIER {
                    result.stop = "frontier-limit";
                    stopped = true;
                    break;
                }
                let mut output = node.output.clone();
                if space {
                    output.push(' ');
                }
                output.push_str(&surface);
                let prior = self
                    .engine
                    .scoring
                    .unigram(edge.word)
                    .personalized
                    .max(f64::MIN_POSITIVE)
                    .log2();
                let structural_single = edge.word.language == Language::Chinese
                    && crate::han::single(&surface).is_some();
                let token = PoolToken {
                    text: surface.into_owned(),
                    language: language(edge.word.language.mask()),
                    source_start: input.source_end(node.end),
                    source_end: input.source_end(edge.end),
                    word_id: edge.word.ids.base.unwrap().0,
                    count: edge.word.count(),
                    unigram_bits: prior,
                    gram_bits: delta.personalized - prior,
                    context_bits: context.personalized - node.context.personalized,
                    spelling_bits: 0.0,
                    structural_single,
                    cuts: edge.cuts(node.end, &input),
                    output_start,
                };
                sequence += 1;
                frontier.push(Agenda {
                    bound,
                    sequence,
                    node: Node {
                        end: edge.end,
                        score,
                        context,
                        history,
                        mask: node.mask | edge.word.language.mask(),
                        output,
                        trace: Some(Rc::new(Trace {
                            previous: node.trace.clone(),
                            token,
                        })),
                        refined: false,
                    },
                });
                result.frontier_peak = result.frontier_peak.max(frontier.len());
            }
            if stopped {
                break;
            }
        }
        result.rows = finished.into_values().collect();
        result
            .rows
            .sort_by(|a, b| compare(&a.candidate, &b.candidate));
        result.rows.truncate(options.k_best);
        result.complete = !stopped;
        result.bound_states = bounds.cache.len();
        result.bound_steps = bound_budget - bounds.remaining;
        result.certified = if result.complete {
            result.rows.len()
        } else {
            // A frontier overflow may omit children of the last expanded node.
            // Do not certify a partial ordering using only the remaining heap.
            0
        };
        result
    }
}

fn language(mask: usize) -> CandidateLanguage {
    match mask {
        1 => CandidateLanguage::Chinese,
        2 => CandidateLanguage::English,
        _ => CandidateLanguage::Mixed,
    }
}

fn total(row: &Candidate) -> f64 {
    row.score_bits.unwrap_or_default() + row.context_adjustment
}

fn compare(a: &Candidate, b: &Candidate) -> Ordering {
    total(b)
        .total_cmp(&total(a))
        .then_with(|| a.language.cmp(&b.language))
        .then_with(|| a.text.cmp(&b.text))
}

fn entry(
    candidate: Candidate,
    tokens: Vec<PoolToken>,
    native_rank: Option<usize>,
    k_best_rank: Option<usize>,
) -> PoolEntry {
    let k_best_score = k_best_rank.map(|_| total(&candidate));
    let native_score = native_rank.map(|_| total(&candidate));
    let trace_matches_candidate = !tokens.is_empty();
    PoolEntry {
        candidate,
        tokens,
        native_rank,
        native_eligible: false,
        native_score,
        k_best_rank,
        k_best_score,
        trace_matches_candidate,
        eligible: false,
        structure_kept: false,
        quota_kept: false,
        selected: false,
        exclusion: "ineligible",
        blocked_by: Vec::new(),
    }
}

#[derive(Default)]
struct Enumeration {
    rows: Vec<ExactPath>,
    complete: bool,
    certified: usize,
    expanded: usize,
    frontier_peak: usize,
    edges: usize,
    bound_states: usize,
    bound_steps: usize,
    stop: &'static str,
}

struct ExactPath {
    candidate: Candidate,
    tokens: Vec<PoolToken>,
}

/// Memoized exact suffix values on the acyclic (position, word-history) graph.
/// If its separate work budget ends, fall back to the admissible lexical bound;
/// never treat an unfinished suffix calculation as an exact value or prune by it.
struct SuffixBounds<'graph, 'data> {
    graph: &'graph [Vec<Match<'data>>],
    suffix: &'graph [f64],
    lexical: &'graph [f64],
    cache: HashMap<(usize, History), f64>,
    remaining: usize,
    start_cap: f64,
}

impl SuffixBounds<'_, '_> {
    fn get(
        &mut self,
        position: usize,
        history: History,
        scoring: &mut ScoreSession<'_, '_>,
    ) -> f64 {
        if position == self.graph.len() {
            return 0.0;
        }
        let key = (position, history.base_suffix_key());
        if let Some(&value) = self.cache.get(&key) {
            return value;
        }
        let previous_start = history
            .start_adjustment(self.start_cap)
            .map_or(0.0, |score| score.personalized);
        let fallback = self.suffix[position]
            + if history.has_start() {
                self.start_cap - previous_start
            } else {
                0.0
            };
        if self.remaining == 0 || self.cache.len() >= 100_000 {
            return fallback;
        }
        let mut best = f64::NEG_INFINITY;
        for index in 0..self.graph[position].len() {
            if self.remaining == 0 {
                return fallback;
            }
            let edge = self.graph[position][index];
            if !self.suffix[edge.end].is_finite() {
                continue;
            }
            let optimistic = self.lexical[edge.word.ids.base.unwrap().0 as usize]
                + self.suffix[edge.end]
                + if history.has_start() {
                    self.start_cap - previous_start
                } else {
                    0.0
                };
            if optimistic + UPPER_SLACK < best {
                continue;
            }
            self.remaining -= 1;
            let (next, delta) =
                scoring.step(history, &WordScore::new(edge.word), 0, edge.end, false);
            let next_start = next
                .start_adjustment(self.start_cap)
                .map_or(0.0, |score| score.personalized);
            let remaining = self.get(edge.end, next, scoring);
            best = best.max(delta.personalized + next_start - previous_start + remaining);
        }
        self.cache.insert(key, best);
        best
    }
}

struct Trace {
    previous: Option<Rc<Trace>>,
    token: PoolToken,
}
struct Node {
    end: usize,
    score: Scores,
    context: Scores,
    history: History,
    mask: usize,
    output: String,
    trace: Option<Rc<Trace>>,
    refined: bool,
}

impl Node {
    fn finish(self, consumed_bytes: usize) -> ExactPath {
        let mut tokens = Vec::new();
        let mut trace = self.trace.as_deref();
        while let Some(node) = trace {
            tokens.push(node.token.clone());
            trace = node.previous.as_deref();
        }
        tokens.reverse();
        let source_boundaries = tokens
            .iter()
            .flat_map(|token| token.cuts.iter().copied())
            .collect();
        let mut confirmation_boundaries = Vec::new();
        for token in &tokens {
            if token.language != CandidateLanguage::Chinese {
                break;
            }
            if token.text.chars().count() == token.cuts.len()
                && token.text.chars().all(crate::han::is_han)
            {
                for (&source_bytes, (offset, ch)) in
                    token.cuts.iter().zip(token.text.char_indices())
                {
                    if confirmation_boundaries.len() == 8 {
                        break;
                    }
                    confirmation_boundaries.push(ConversionBoundary {
                        source_bytes,
                        output_bytes: token.output_start + offset + ch.len_utf8(),
                    });
                }
            } else if confirmation_boundaries.len() < 8 {
                confirmation_boundaries.push(ConversionBoundary {
                    source_bytes: token.source_end,
                    output_bytes: token.output_start + token.text.len(),
                });
            }
        }
        ExactPath {
            candidate: Candidate {
                text: self.output,
                language: language(self.mask),
                consumed_bytes,
                score_bits: Some(self.score.personalized),
                context_adjustment: self.context.personalized,
                reranking_bonus: 0.0,
                completion: false,
                lexical_tokens: tokens.len(),
                source_boundaries,
                confirmation_boundaries,
                personal: false,
                preferred: false,
                verbatim: false,
                correction: None,
                token_bonus: 0.0,
            },
            tokens,
        }
    }
}

struct Agenda {
    bound: f64,
    sequence: u64,
    node: Node,
}
impl PartialEq for Agenda {
    fn eq(&self, other: &Self) -> bool {
        self.sequence == other.sequence
    }
}
impl Eq for Agenda {}
impl PartialOrd for Agenda {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Agenda {
    fn cmp(&self, other: &Self) -> Ordering {
        self.bound
            .total_cmp(&other.bound)
            .then_with(|| other.sequence.cmp(&self.sequence))
    }
}

#[derive(Hash, PartialEq, Eq)]
struct Structure(CandidateLanguage, Vec<(usize, usize, Option<String>)>);

fn select(entries: &mut [PoolEntry], options: PoolOptions, byte_limit: usize) {
    let mut structures: HashMap<Structure, Vec<usize>> = HashMap::new();
    let mut multiword = 0;
    let mut selected = 0;
    for (index, row) in entries.iter_mut().enumerate() {
        let candidate = &row.candidate;
        let ordinary = super::reranking::eligible(
            candidate.personal,
            candidate.verbatim,
            candidate.is_corrected(),
            candidate.completion,
            candidate.text.len(),
            usize::MAX,
        );
        row.eligible = ordinary && candidate.text.len() <= byte_limit;
        if !ordinary {
            continue;
        }
        // Without a fixed lexical anchor, all homophone words/characters would
        // collapse into one all-wildcard key. Those are independent choices.
        if options.structure_limit != 0
            && row.trace_matches_candidate
            && row.tokens.len() >= 2
            && row.tokens.iter().any(|token| !token.structural_single)
        {
            let key = Structure(
                candidate.language,
                row.tokens
                    .iter()
                    .map(|token| {
                        (
                            token.source_start,
                            token.source_end,
                            if token.structural_single {
                                None
                            } else {
                                Some(token.text.clone())
                            },
                        )
                    })
                    .collect(),
            );
            let group = structures.entry(key).or_default();
            if group.len() >= options.structure_limit {
                row.exclusion = "structure";
                row.blocked_by = group.clone();
                continue;
            }
            group.push(index);
        }
        row.structure_kept = true;
        if !row.eligible {
            row.exclusion = "length";
            continue;
        }
        if row.trace_matches_candidate && row.tokens.len() >= 3 {
            if multiword >= options.multiword_limit {
                row.exclusion = "word-quota";
                continue;
            }
            multiword += 1;
        }
        row.quota_kept = true;
        if selected == options.pool_size {
            row.exclusion = "pool-limit";
            continue;
        }
        selected += 1;
        row.selected = true;
        row.exclusion = "selected";
    }
}
