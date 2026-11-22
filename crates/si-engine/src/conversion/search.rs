use std::borrow::Cow;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::rc::Rc;

use super::input::Input;
use super::lookup::{CorrectionBudget, Lookup, MIN_CORRECTION_BITS, Match};
use super::ranking::{Completions, Results};
use super::scoring::{History, ScoreSession, Scores, WordScore};
use super::{
    Candidate, CandidateLanguage, ConversionBoundary, ConversionPreferences, Correction,
    CorrectionKind, CorrectionSensitivity, EnabledLanguages, Language, MAX_OUTPUT_BYTES,
    PathPreference, SmallReranker, TokenPreference,
};
use crate::han;

const MAX_SEARCH_UNITS: usize = 128;
const BEAM_WIDTH: usize = 24;
const PREVIEW_BEAM_WIDTH: usize = 6;
const MAX_DERIVATIONS_PER_TEXT: usize = 2;
const COMPOSED_PREFIXES_PER_LANGUAGE: usize = 2;
const PERSONAL_EDGES_PER_SPAN: usize = 12;
const CORRECTION_BEAM_WIDTH: usize = 4;
const ORDINARY_FRONTIER_BEAMS: usize = 9;
const ABBREVIATION_BITS: f64 = 7.0;

#[allow(clippy::too_many_arguments)]
pub(super) fn run(
    input: &Input<'_>,
    languages: EnabledLanguages,
    lookup: &Lookup<'_>,
    scoring: ScoreSession<'_, '_>,
    preview: bool,
    personal: &Lookup<'_>,
    preferences: ConversionPreferences<'_>,
    correction: Option<CorrectionSensitivity>,
    reranking: Option<(&SmallReranker, &str, usize)>,
) -> Vec<Candidate> {
    let limit = input.len().min(MAX_SEARCH_UNITS);
    let correction_margin = correction.map(CorrectionSensitivity::margin);
    let correction_context_backoff = correction == Some(CorrectionSensitivity::HigherRecall);
    let mut correction = correction.is_some()
        && languages.chinese
        && limit == input.len()
        && limit >= 4
        && input
            .spelling(Language::Chinese)
            .iter()
            .all(|&byte| byte != 0)
        && !input.source_span(0, limit).chars().any(char::is_uppercase);
    let english_ends = if languages.english && !preferences.tokens.is_empty() {
        (0..limit)
            .map(|start| {
                let mut longest = 0;
                lookup.visit(Language::English, input, start, limit, |edge| {
                    if edge.missing == 0 {
                        longest = longest.max(edge.end);
                    }
                });
                longest
            })
            .collect()
    } else {
        Vec::new()
    };
    let has_user = scoring.has_user();
    let mut search = Search {
        input,
        limit,
        beam_width: if preview {
            PREVIEW_BEAM_WIDTH
        } else {
            BEAM_WIDTH
        },
        scoring,
        lattice: (0..=limit).map(|_| Frontier::default()).collect(),
        results: Results::default(),
        correction_floor: f64::NEG_INFINITY,
        correction_margin,
        correction_context_backoff,
        exact_suffixes: &[],
        preferences: TokenBonuses::new(preferences.tokens),
        path_preferences: PathBonuses::new(preferences.paths, input, limit),
        english_ends,
    };
    let allow_verbatim = languages.chinese && languages.english && limit == input.len();
    let (chinese_starts, exact_starts, exact_whole) = if allow_verbatim {
        exact_spans(input, lookup, personal)
    } else {
        (Vec::new(), Vec::new(), true)
    };
    let enabled = Language::ALL
        .into_iter()
        .filter(|language| language.enabled(languages));
    for language in enabled.clone() {
        let mut completions = Completions::default();
        lookup.visit(language, input, 0, input.len(), |edge| {
            if language == Language::English && edge.end == input.len() && edge.missing == 0 {
                correction = false;
            }
            search.seed(
                edge,
                &mut completions,
                has_user || !preferences.tokens.is_empty() || !preferences.paths.is_empty(),
                true,
            );
        });
        let mut seen = vec![0; limit + 1];
        personal.visit(language, input, 0, input.len(), |edge| {
            if edge.end == input.len() && edge.missing == 0 {
                correction = false;
            }
            let can_extend = allow_personal_edge(&mut seen, edge.end);
            search.seed(edge, &mut completions, false, can_extend);
        });
        for (candidate, effective_score) in completions.into_rows() {
            search.results.insert(candidate, effective_score);
        }
    }
    if !exact_whole && !exact_starts[0] {
        for &end in &chinese_starts {
            if let Some(edge) = verbatim(input, 0, end) {
                search.seed_verbatim(edge);
            }
        }
    }
    correction &= -MIN_CORRECTION_BITS > search.correction_floor;
    let exact_suffixes = if correction {
        lookup.exact_suffixes(input)
    } else {
        Vec::new()
    };
    search.exact_suffixes = &exact_suffixes;
    let mut correction_budget = CorrectionBudget::default();
    if correction {
        lookup.visit_corrections(
            input,
            0,
            limit,
            &mut correction_budget,
            &exact_suffixes,
            |edge| {
                search.seed(edge, &mut Completions::default(), false, true);
            },
        );
    }
    for start in 1..=limit {
        let frontier = std::mem::take(&mut search.lattice[start]);
        search.collect(start, &frontier);
        if start == limit || frontier.is_empty() {
            continue;
        }
        for language in enabled.clone() {
            let mut completions = Vec::new();
            lookup.visit(language, input, start, limit, |edge| {
                if edge.end == limit && edge.missing > 0 {
                    completions.push(edge);
                } else {
                    search.extend_completions(start, &frontier, language, &mut completions);
                    search.extend(start, &frontier, edge, None);
                }
            });
            search.extend_completions(start, &frontier, language, &mut completions);
            let mut seen = vec![0; limit + 1];
            personal.visit(language, input, start, limit, |edge| {
                if allow_personal_edge(&mut seen, edge.end) {
                    search.extend(start, &frontier, edge, None);
                }
            });
        }
        if correction && frontier.could_correct(search.correction_floor, correction_context_backoff)
        {
            lookup.visit_corrections(
                input,
                start,
                limit,
                &mut correction_budget,
                &exact_suffixes,
                |edge| {
                    search.extend(start, &frontier, edge, None);
                },
            );
        }
        if !exact_whole && exact_starts.get(start) == Some(&false) {
            for end in chinese_starts
                .iter()
                .copied()
                .chain(std::iter::once(limit))
                .filter(|&end| end > start)
            {
                if let Some(edge) = verbatim(input, start, end) {
                    search.extend(start, &frontier, edge, None);
                }
            }
        }
    }
    search.results.ranked(search.correction_floor, reranking)
}

fn correction_context(adjustment: Scores, backoff: bool) -> Scores {
    if backoff {
        const BACKOFF_COST_BITS: f64 = 2.0;
        Scores {
            base: adjustment.base.max(-BACKOFF_COST_BITS),
            personalized: adjustment.personalized.max(-BACKOFF_COST_BITS),
        }
    } else {
        adjustment
    }
}

fn exact_spans(
    input: &Input<'_>,
    lookup: &Lookup<'_>,
    personal: &Lookup<'_>,
) -> (Vec<usize>, Vec<bool>, bool) {
    let limit = input.len();
    let mut chinese_starts = Vec::new();
    let mut exact_starts = vec![false; limit];
    let mut reachable = vec![false; limit + 1];
    reachable[0] = true;
    for (start, exact) in exact_starts.iter_mut().enumerate() {
        for language in Language::ALL {
            let mut matched = false;
            for dictionary in [lookup, personal] {
                dictionary.visit(language, input, start, limit, |edge| {
                    if edge.missing == 0 && !edge.is_abbreviated() {
                        matched = true;
                        reachable[edge.end] |= reachable[start];
                    }
                });
            }
            if language == Language::Chinese && matched {
                chinese_starts.push(start);
            }
            *exact |= matched;
        }
    }
    (chinese_starts, exact_starts, reachable[limit])
}

fn allow_personal_edge(seen: &mut [usize], end: usize) -> bool {
    let Some(count) = seen.get_mut(end) else {
        return false;
    };
    *count += 1;
    *count <= PERSONAL_EDGES_PER_SPAN
}

fn verbatim<'a>(input: &'a Input<'a>, start: usize, end: usize) -> Option<Match<'a>> {
    let text = input.source_span(start, end);
    let spelling = &input.spelling(Language::English)[start..end];
    // Only allow word-sized literal runs; punctuation and aliases terminate them.
    (spelling.len() >= 2
        && spelling.iter().all(u8::is_ascii_alphabetic)
        && text.as_bytes().iter().all(u8::is_ascii_alphabetic))
    .then(|| Match::verbatim(text, end))
}

struct Search<'input, 'model, 'data, 'preferences> {
    input: &'input Input<'input>,
    limit: usize,
    beam_width: usize,
    scoring: ScoreSession<'model, 'data>,
    lattice: Vec<Frontier>,
    results: Results,
    correction_floor: f64,
    correction_margin: Option<f64>,
    correction_context_backoff: bool,
    exact_suffixes: &'input [bool],
    preferences: TokenBonuses<'preferences>,
    path_preferences: PathBonuses<'preferences>,
    english_ends: Vec<usize>,
}

struct TokenBonuses<'a>(HashMap<(Language, &'a str, &'a str), f64>);

type SpanBonuses<'a> = HashMap<(CandidateLanguage, &'a str), (f64, f64)>;

struct PathBonuses<'a> {
    spans: Vec<SpanBonuses<'a>>,
    last: usize,
}

impl<'a> PathBonuses<'a> {
    fn new(preferences: &[PathPreference<'a>], input: &Input<'_>, limit: usize) -> Self {
        if preferences.is_empty() {
            return Self {
                spans: Vec::new(),
                last: 0,
            };
        }
        let mut rows = vec![HashMap::new(); limit + 1];
        let mut last = 0;
        for item in preferences
            .iter()
            .take(5_000)
            .filter(|item| item.frequency.is_finite() && item.contextual.is_finite())
        {
            if let Some(end) = input
                .position(item.consumed_bytes)
                .filter(|&end| end <= limit)
            {
                rows[end].insert(
                    (item.language, item.text),
                    (
                        item.frequency.clamp(0.0, 32.0),
                        item.contextual.clamp(0.0, 12.0),
                    ),
                );
                last = last.max(end);
            }
        }
        Self { spans: rows, last }
    }

    fn adjustment(&self, end: usize, mask: usize, output: &str, token_bonus: f64) -> f64 {
        self.spans
            .get(end)
            .and_then(|rows| rows.get(&(candidate_language(mask), output)))
            .map_or(token_bonus, |&(frequency, contextual)| {
                token_bonus.max(frequency) + contextual
            })
    }

    fn could_adjust(&self, end: usize) -> bool {
        self.last != 0 && end <= self.last
    }

    fn continuation_bonus(&self, end: usize, mask: usize, output: &str) -> f64 {
        if end >= self.last {
            return 0.0;
        }
        self.spans[end + 1..=self.last]
            .iter()
            .flat_map(|rows| rows.iter())
            .filter_map(|(&(language, text), &(frequency, contextual))| {
                let same_languages = match language {
                    CandidateLanguage::Chinese => mask == 1,
                    CandidateLanguage::English => mask == 2,
                    CandidateLanguage::Mixed => true,
                    CandidateLanguage::Literal => false,
                };
                (same_languages && text.len() > output.len() && text.starts_with(output))
                    .then_some(frequency + contextual)
            })
            .fold(0.0, f64::max)
    }
}

impl<'a> TokenBonuses<'a> {
    fn new(preferences: &[TokenPreference<'a>]) -> Self {
        Self(
            preferences
                .iter()
                .take(5_000)
                .filter_map(|item| {
                    let language = match item.language {
                        CandidateLanguage::Chinese => Language::Chinese,
                        CandidateLanguage::English => Language::English,
                        _ => return None,
                    };
                    (item.bonus.is_finite() && item.bonus > 0.0)
                        .then_some(((language, item.spelling, item.text), item.bonus.min(32.0)))
                })
                .collect(),
        )
    }

    fn get(&self, edge: Match<'_>, input: &Input<'_>, start: usize, output: &str) -> f64 {
        if self.0.is_empty()
            || edge.word.personal.is_some()
            || edge.word.verbatim
            || (edge.word.language == Language::Chinese && han::single(output).is_some())
        {
            return 0.0;
        }
        let source = input.source_span(start, edge.end).to_lowercase();
        let spelling = if edge.word.language == Language::Chinese {
            source
                .replace("u:", "v")
                .replace('ü', "v")
                .replace("u\u{0308}", "v")
        } else {
            source
        };
        self.0
            .get(&(edge.word.language, &spelling, output))
            .copied()
            .unwrap_or(0.0)
    }
}

impl Search<'_, '_, '_, '_> {
    fn seed_verbatim(&mut self, edge: Match<'_>) {
        let (history, score) = self
            .scoring
            .step(History::default(), &WordScore::new(edge.word), 0);
        let mask = Language::English.mask();
        let path = Path {
            output: edge.word.text.to_owned(),
            score,
            context_adjustment: Scores::default(),
            history,
            mask,
            constructed: false,
            lexical_tokens: 0,
            completion: false,
            personal: false,
            verbatim: true,
            token_sum: 0.0,
            units: edge.end,
            adjustment: 0.0,
            search_adjustment: 0.0,
            english_end: 0,
            splits_english: false,
            confirmation_ambiguous: false,
            corrected: false,
            abbreviated: false,
            trace: Rc::new(Trace {
                previous: None,
                details: Rc::new(EdgeDetails::new(edge, self.input, 0)),
                output_start: 0,
                space: false,
            }),
        };
        self.lattice[edge.end]
            .beam(Lane::Personalized, mask, true)
            .insert(path, Lane::Personalized, false, self.beam_width);
    }

    fn seed(
        &mut self,
        edge: Match<'_>,
        completions: &mut Completions,
        has_user: bool,
        can_extend: bool,
    ) {
        let corrected = edge.correction_cost > 0.0;
        let mask = edge.word.language.mask();
        let (history, mut score, context_adjustment) = self.scoring.start(edge.word, edge.missing);
        let context_adjustment = correction_context(
            context_adjustment,
            corrected && self.correction_context_backoff,
        );
        if edge.is_abbreviated() {
            score.base -= ABBREVIATION_BITS;
            score.personalized -= ABBREVIATION_BITS;
        }
        score.base -= edge.correction_cost;
        score.personalized -= edge.correction_cost;
        if corrected
            && edge.end < self.limit
            && !self.lattice[edge.end].corrected.could_enter(
                score.personalized + context_adjustment.personalized,
                Lane::Personalized,
                CORRECTION_BEAM_WIDTH,
                true,
            )
        {
            return;
        }
        let personal = edge.word.personal.is_some();
        let output = render(edge, self.input.source_span(0, edge.end));
        let direct_adjustment = if personal || corrected {
            0.0
        } else {
            self.path_preferences
                .adjustment(edge.end, mask, &output, 0.0)
        } + context_adjustment.personalized;
        if edge.missing != 0
            && !personal
            && !completions.could_enter(score.personalized + direct_adjustment)
        {
            return;
        }
        let effective_score = score.personalized + direct_adjustment;
        if corrected && effective_score <= self.correction_floor {
            return;
        }
        if let Some(margin) = self.correction_margin
            && !corrected
            && !personal
            && mask == Language::Chinese.mask()
            && edge.end == self.input.len()
            && edge.missing == 0
            && !edge.is_abbreviated()
        {
            let exact_score = effective_score - context_adjustment.personalized.min(0.0);
            self.correction_floor = self.correction_floor.max(exact_score + margin);
        }
        let details = Rc::new(EdgeDetails::new(edge, self.input, 0));
        if !corrected || edge.end == self.input.len() {
            let candidate = Candidate {
                text: output.to_string(),
                language: candidate_language(mask),
                consumed_bytes: self.input.source_end(edge.end),
                score_bits: Some(score.personalized),
                context_adjustment: context_adjustment.personalized,
                reranking_bonus: 0.0,
                completion: edge.missing != 0,
                lexical_tokens: 1,
                source_boundaries: details.cuts.clone(),
                confirmation_boundaries: details.confirmation.clone().unwrap_or_default(),
                personal,
                preferred: edge.word.personal == Some(true)
                    && edge.missing == 0
                    && edge.end == self.input.len(),
                verbatim: false,
                correction: details.correction(0),
                token_bonus: 0.0,
            };
            if candidate.completion && !personal {
                completions.insert(candidate, direct_adjustment);
                return;
            }
            self.results.insert(candidate, effective_score);
        }
        if !can_extend || edge.end >= self.limit || output.len() > MAX_OUTPUT_BYTES {
            return;
        }
        let token_sum = if corrected {
            0.0
        } else {
            self.preferences.get(edge, self.input, 0, &output) * edge.end as f64
        };
        let adjustment = if personal || corrected {
            0.0
        } else {
            self.path_preferences
                .adjustment(edge.end, mask, &output, token_sum / edge.end as f64)
        };
        let search_adjustment = if personal || corrected {
            adjustment
        } else {
            adjustment.max(
                self.path_preferences
                    .continuation_bonus(edge.end, mask, &output),
            )
        };
        let path = Path {
            output: output.into_owned(),
            score,
            context_adjustment,
            history,
            mask,
            constructed: false,
            lexical_tokens: 1,
            completion: false,
            personal,
            verbatim: false,
            token_sum,
            units: edge.end,
            adjustment,
            search_adjustment,
            english_end: if !personal && edge.word.language == Language::English {
                self.english_end(0)
            } else {
                0
            },
            splits_english: edge.is_abbreviated() && edge.end < self.english_end(0),
            confirmation_ambiguous: false,
            corrected,
            abbreviated: edge.is_abbreviated(),
            trace: Rc::new(Trace {
                previous: None,
                details,
                output_start: 0,
                space: false,
            }),
        };
        let frontier = &mut self.lattice[edge.end];
        if corrected {
            frontier
                .corrected
                .insert(path, Lane::Personalized, false, CORRECTION_BEAM_WIDTH);
            return;
        }
        if has_user && edge.word.ids.base.is_some() {
            frontier.beam(Lane::Base, mask, false).insert(
                path.clone(),
                Lane::Base,
                false,
                self.beam_width,
            );
        }
        frontier.beam(Lane::Personalized, mask, personal).insert(
            path,
            Lane::Personalized,
            false,
            self.beam_width,
        );
    }

    fn collect(&mut self, end: usize, frontier: &Frontier) {
        let whole = end == self.input.len();
        for mask in 1..=3 {
            let mut paths: Vec<_> = Lane::ALL
                .into_iter()
                .map(|lane| &frontier.lanes[lane as usize][mask - 1])
                .chain(std::iter::once(&frontier.private[mask - 1]))
                .chain((whole && mask == 1).then_some(&frontier.corrected))
                .flat_map(|beam| &beam.paths)
                .filter(|path| path.constructed && (!path.verbatim || (whole && mask == 3)))
                .collect();
            if !whole {
                paths.sort_by(|left, right| compare_paths(left, right, Lane::Personalized, false));
            }
            let mut seen = Vec::new();
            for path in paths {
                let effective_score = path.score.personalized
                    + path.context_adjustment.personalized
                    + path.adjustment;
                if path.corrected && effective_score <= self.correction_floor {
                    continue;
                }
                if !whole {
                    if seen.contains(&path.output.as_str()) {
                        continue;
                    }
                    if seen.len() == COMPOSED_PREFIXES_PER_LANGUAGE {
                        break;
                    }
                    seen.push(path.output.as_str());
                }
                let (source_boundaries, confirmation_boundaries) = path.trace.boundaries(
                    !path.confirmation_ambiguous
                        && !path.personal
                        && !path.verbatim
                        && !path.corrected,
                );
                self.results.insert(
                    Candidate {
                        text: path.output.clone(),
                        language: candidate_language(mask),
                        consumed_bytes: self.input.source_end(end),
                        score_bits: Some(path.score.personalized),
                        context_adjustment: path.context_adjustment.personalized,
                        reranking_bonus: 0.0,
                        completion: path.completion,
                        lexical_tokens: path.lexical_tokens,
                        source_boundaries,
                        confirmation_boundaries,
                        personal: path.personal,
                        preferred: false,
                        verbatim: path.verbatim,
                        correction: path.corrected.then(|| path.trace.correction()).flatten(),
                        token_bonus: path.token_bonus(),
                    },
                    effective_score,
                );
            }
        }
    }

    fn extend_completions(
        &mut self,
        start: usize,
        frontier: &Frontier,
        language: Language,
        completions: &mut Vec<Match<'_>>,
    ) {
        if completions.is_empty() {
            return;
        }
        let bounds = self.scoring.completion_bounds(
            frontier
                .beams()
                .flat_map(|(_, beam)| beam.paths.iter())
                .filter(|path| !path.corrected)
                .map(|path| path.history),
        );
        let mut bounded: Vec<_> = completions
            .drain(..)
            .enumerate()
            .map(|(order, edge)| {
                let upper = self.scoring.completion_upper_bits(
                    &bounds,
                    &WordScore::new(edge.word),
                    edge.missing,
                );
                (order, edge, upper)
            })
            .collect();
        let prefixes = self.completion_prefixes(frontier, language);
        if let Some(cutoff) = prefixes
            .as_ref()
            .map(|prefixes| prefixes.required[0])
            .filter(|cutoff| cutoff.is_finite())
        {
            bounded.sort_unstable_by(|a, b| b.2.total_cmp(&a.2));
            bounded.truncate(bounded.partition_point(|entry| entry.2 >= cutoff));
            // Only the eligibility scan changes order. Insertion order carries
            // confirmation-boundary evidence for equal-scoring lexical paths.
            bounded.sort_unstable_by_key(|entry| entry.0);
        }
        for (_, edge, upper) in bounded {
            let paths = prefixes
                .as_ref()
                .and_then(|prefixes| prefixes.eligible(upper));
            self.extend(
                start,
                frontier,
                edge,
                Some(CompletionPruning { upper, paths }),
            );
        }
    }

    fn completion_prefixes(
        &self,
        frontier: &Frontier,
        language: Language,
    ) -> Option<CompletionPrefixes> {
        if !self.preferences.0.is_empty() || self.path_preferences.could_adjust(self.limit) {
            return None;
        }
        let terminal = &self.lattice[self.limit];
        let mut max_context = [0.0_f64; ORDINARY_FRONTIER_BEAMS];
        let mut minimum_adjusted = [f64::NEG_INFINITY; ORDINARY_FRONTIER_BEAMS];
        for (destination, (lane, beam)) in
            terminal.beams().take(ORDINARY_FRONTIER_BEAMS).enumerate()
        {
            if beam.paths.len() == self.beam_width {
                let last = beam.paths.last().expect("full beam has a last path");
                minimum_adjusted[destination] =
                    lane.score(last.score + last.context_adjustment, last.search_adjustment);
                for path in &beam.paths {
                    max_context[destination] =
                        max_context[destination].max(lane.score(path.context_adjustment, 0.0));
                }
            }
        }
        let mut prefixes = Vec::new();
        for (source, (lane, beam)) in frontier.beams().take(ORDINARY_FRONTIER_BEAMS).enumerate() {
            for (index, path) in beam.paths.iter().enumerate() {
                let private = path.verbatim || path.personal;
                let mask_index = (path.mask | language.mask()) - 1;
                let destination = if private { 6 } else { 3 * lane as usize } + mask_index;
                let context = if private {
                    Scores::default()
                } else {
                    path.context_adjustment
                };
                max_context[destination] = max_context[destination].max(lane.score(context, 0.0));
                prefixes.push((
                    destination,
                    source,
                    index,
                    lane.score(path.score + context, 0.0),
                ));
            }
        }
        let mut required: Vec<_> = prefixes
            .into_iter()
            .map(|(destination, source, index, prefix)| {
                // Full beams are ordered by the adjusted score. It can only rise
                // at the cutoff. The old eligibility gate uses the raw score, so
                // subtract the largest possible adjustment for any path here.
                (
                    minimum_adjusted[destination] - max_context[destination] - prefix,
                    source,
                    index,
                )
            })
            .collect();
        if required.iter().all(|entry| !entry.0.is_finite()) {
            return None;
        }
        // Within each destination this visits the highest-scoring prefixes
        // first. The per-word suffix of this list is below its beam floors.
        required.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
        let mut paths = [0; ORDINARY_FRONTIER_BEAMS];
        let mut masks = vec![paths];
        let mut scores = Vec::with_capacity(required.len());
        for (score, source, index) in required {
            paths[source] |= 1 << index;
            scores.push(score);
            masks.push(paths);
        }
        Some(CompletionPrefixes {
            required: scores,
            masks,
        })
    }

    fn extend(
        &mut self,
        start: usize,
        frontier: &Frontier,
        edge: Match<'_>,
        pruning: Option<CompletionPruning<'_>>,
    ) {
        let edge_is_corrected = edge.correction_cost > 0.0;
        let language = edge.word.language;
        let surface = render(edge, self.input.source_span(start, edge.end));
        let terminal = edge.end == self.limit;
        let details = std::cell::OnceCell::new();
        let word_score = WordScore::new(edge.word);
        let personal = edge.word.personal.is_some();
        let english_end = self.english_end(start);
        let token_sum = if edge_is_corrected {
            0.0
        } else {
            self.preferences.get(edge, self.input, start, &surface) * (edge.end - start) as f64
        };
        let exact_chinese_continuation = language == Language::Chinese
            && !personal
            && !edge.word.verbatim
            && !edge.is_abbreviated()
            && edge.missing == 0
            && self.exact_suffixes.get(edge.end) == Some(&true);
        for (source, (lane, beam)) in frontier.beams().enumerate() {
            if std::ptr::eq(beam, &frontier.corrected) && !exact_chinese_continuation {
                continue;
            }
            if edge_is_corrected
                && !std::ptr::eq(beam, &frontier.lanes[Lane::Personalized as usize][0])
            {
                continue;
            }
            if lane == Lane::Base && edge.word.ids.base.is_none() {
                continue;
            }
            let allowed = pruning
                .as_ref()
                .and_then(|pruning| pruning.paths)
                .map_or(u32::MAX, |paths| paths.get(source).copied().unwrap_or(0));
            let mut remaining = allowed & ((1u32 << beam.paths.len()) - 1);
            while remaining != 0 {
                let index = remaining.trailing_zeros() as usize;
                remaining &= remaining - 1;
                let path = &beam.paths[index];
                if edge.word.verbatim
                    && (path.verbatim || path.mask & Language::Chinese.mask() == 0)
                {
                    continue;
                }
                let corrected = path.corrected || edge_is_corrected;
                if corrected
                    && (lane == Lane::Base
                        || path.corrected && edge_is_corrected
                        || path.mask != Language::Chinese.mask()
                        || path.personal
                        || path.verbatim
                        || path.abbreviated
                        || !exact_chinese_continuation)
                {
                    continue;
                }
                let verbatim = path.verbatim || edge.word.verbatim;
                let has_personal = personal || path.personal;
                let private = verbatim || has_personal;
                let strip_spaces = private && !path.verbatim && !path.personal;
                let space = !private
                    && (language == Language::English
                        || path.history.last() == Some(Language::English));
                let output_start = path.output.len() + usize::from(space)
                    - if strip_spaces {
                        path.trace.inserted_spaces()
                    } else {
                        0
                    };
                if output_start + surface.len() > MAX_OUTPUT_BYTES {
                    continue;
                }
                let context_adjustment = if private {
                    Scores::default()
                } else {
                    correction_context(
                        path.context_adjustment,
                        corrected && self.correction_context_backoff,
                    )
                };
                let mask = path.mask | language.mask();
                let splits_english = !private
                    && (path.splits_english
                        || start < path.english_end
                        || (edge.is_abbreviated() && edge.end < english_end));
                let token_sum = if private || splits_english || corrected {
                    0.0
                } else {
                    path.token_sum + token_sum
                };
                let bonus = token_sum / edge.end as f64;
                let has_path_preferences = !private
                    && !corrected
                    && lane == Lane::Personalized
                    && self.path_preferences.could_adjust(edge.end);
                if let Some(upper) = pruning.as_ref().map(|pruning| pruning.upper)
                    && !has_path_preferences
                    && !self.lattice[edge.end]
                        .target(lane, mask, private)
                        .could_enter(
                            lane.score(
                                path.score
                                    + Scores {
                                        base: upper,
                                        personalized: upper,
                                    }
                                    + context_adjustment,
                                bonus,
                            ),
                            lane,
                            self.beam_width,
                            false,
                        )
                {
                    continue;
                }
                if corrected {
                    // The lexical probability is at most one. Even that
                    // optimistic path must pay the edit cost.
                    let upper_bound = (path.score.personalized - edge.correction_cost)
                        + context_adjustment.personalized;
                    if upper_bound <= self.correction_floor
                        || !self.lattice[edge.end].corrected.could_enter(
                            upper_bound,
                            Lane::Personalized,
                            CORRECTION_BEAM_WIDTH,
                            true,
                        )
                    {
                        continue;
                    }
                }
                let (history, mut delta) =
                    self.scoring.step(path.history, &word_score, edge.missing);
                if edge.is_abbreviated() {
                    delta.base -= ABBREVIATION_BITS;
                    delta.personalized -= ABBREVIATION_BITS;
                }
                delta.base -= edge.correction_cost;
                delta.personalized -= edge.correction_cost;
                if corrected
                    && path.score.personalized
                        + context_adjustment.personalized
                        + delta.personalized
                        <= self.correction_floor
                {
                    continue;
                }
                let score = path.score + delta;
                let frontier = &mut self.lattice[edge.end];
                let (target, width) = if corrected {
                    (&mut frontier.corrected, CORRECTION_BEAM_WIDTH)
                } else {
                    (frontier.beam(lane, mask, private), self.beam_width)
                };
                if !has_path_preferences
                    && !target.could_enter(
                        lane.score(score + context_adjustment, bonus),
                        lane,
                        width,
                        corrected,
                    )
                {
                    continue;
                }
                let mut output = String::with_capacity(output_start + surface.len());
                if strip_spaces {
                    path.trace.copy_without_spaces(&path.output, &mut output);
                } else {
                    output.push_str(&path.output);
                }
                if space {
                    output.push(' ');
                }
                output.push_str(&surface);
                let adjustment = if has_path_preferences {
                    self.path_preferences
                        .adjustment(edge.end, mask, &output, bonus)
                } else {
                    bonus
                };
                let search_adjustment = if has_path_preferences && edge.missing == 0 {
                    adjustment.max(
                        self.path_preferences
                            .continuation_bonus(edge.end, mask, &output),
                    )
                } else {
                    adjustment
                };
                let abbreviated = path.abbreviated || edge.is_abbreviated();
                if let Some(margin) = self.correction_margin
                    && terminal
                    && !self.exact_suffixes.is_empty()
                    && mask != 3
                    && !corrected
                    && !private
                    && !abbreviated
                    && edge.missing == 0
                {
                    let effective_score =
                        score.personalized + context_adjustment.personalized + adjustment;
                    let exact_score = effective_score - context_adjustment.personalized.min(0.0);
                    self.correction_floor = self.correction_floor.max(exact_score + margin);
                }
                target.insert(
                    Path {
                        output,
                        score,
                        context_adjustment,
                        history,
                        mask,
                        constructed: true,
                        lexical_tokens: path.lexical_tokens + 1,
                        completion: edge.missing != 0,
                        personal: has_personal,
                        verbatim,
                        token_sum,
                        units: edge.end,
                        adjustment,
                        search_adjustment,
                        english_end: if language == Language::English && !private && !splits_english
                        {
                            english_end
                        } else {
                            0
                        },
                        splits_english,
                        confirmation_ambiguous: path.confirmation_ambiguous,
                        corrected,
                        abbreviated,
                        trace: Rc::new(Trace {
                            previous: Some(Rc::clone(&path.trace)),
                            details: Rc::clone(details.get_or_init(|| {
                                Rc::new(EdgeDetails::new(edge, self.input, start))
                            })),
                            output_start,
                            space,
                        }),
                    },
                    lane,
                    terminal,
                    width,
                );
            }
        }
    }

    fn english_end(&self, start: usize) -> usize {
        self.english_ends.get(start).copied().unwrap_or(0)
    }
}

type PrefixMask = [u32; ORDINARY_FRONTIER_BEAMS];

struct CompletionPrefixes {
    required: Vec<f64>,
    masks: Vec<PrefixMask>,
}

impl CompletionPrefixes {
    fn eligible(&self, upper: f64) -> Option<&PrefixMask> {
        let count = self.required.partition_point(|required| *required <= upper);
        (count != self.required.len()).then(|| &self.masks[count])
    }
}

struct CompletionPruning<'a> {
    upper: f64,
    paths: Option<&'a PrefixMask>,
}

fn render<'a>(edge: Match<'a>, typed: &str) -> Cow<'a, str> {
    let text = edge.word.text;
    if edge.word.language == Language::English
        && edge.word.personal.is_none()
        && !edge.word.verbatim
    {
        if typed.bytes().any(|byte| byte.is_ascii_uppercase())
            && !typed.bytes().any(|byte| byte.is_ascii_lowercase())
        {
            return Cow::Owned(text.to_uppercase());
        }
        if typed.as_bytes().first().is_some_and(u8::is_ascii_uppercase) {
            let first = text.chars().next().expect("nonempty dictionary text");
            let mut capitalized: String = first.to_uppercase().collect();
            capitalized.push_str(&text[first.len_utf8()..]);
            return Cow::Owned(capitalized);
        }
    }
    Cow::Borrowed(text)
}

fn candidate_language(mask: usize) -> CandidateLanguage {
    match mask {
        1 => CandidateLanguage::Chinese,
        2 => CandidateLanguage::English,
        _ => CandidateLanguage::Mixed,
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Lane {
    Base,
    Personalized,
}

impl Lane {
    const ALL: [Self; 2] = [Self::Base, Self::Personalized];

    fn score(self, scores: Scores, bonus: f64) -> f64 {
        match self {
            Self::Base => scores.base,
            Self::Personalized => scores.personalized + bonus,
        }
    }
}

#[derive(Default)]
struct Frontier {
    lanes: [[Beam; 3]; 2],
    private: [Beam; 3],
    corrected: Beam,
}

impl Frontier {
    fn target(&self, lane: Lane, mask: usize, private: bool) -> &Beam {
        if private {
            &self.private[mask - 1]
        } else {
            &self.lanes[lane as usize][mask - 1]
        }
    }

    fn beam(&mut self, lane: Lane, mask: usize, private: bool) -> &mut Beam {
        if private {
            &mut self.private[mask - 1]
        } else {
            &mut self.lanes[lane as usize][mask - 1]
        }
    }

    fn beams(&self) -> impl Iterator<Item = (Lane, &Beam)> {
        Lane::ALL
            .into_iter()
            .flat_map(|lane| {
                self.lanes[lane as usize]
                    .iter()
                    .map(move |beam| (lane, beam))
            })
            .chain(self.private.iter().map(|beam| (Lane::Personalized, beam)))
            .chain(std::iter::once((Lane::Personalized, &self.corrected)))
    }

    fn could_correct(&self, floor: f64, context_backoff: bool) -> bool {
        // A lexical continuation contributes a log probability at most zero.
        // Corrected paths carry their initial context but no preference bonus.
        self.lanes[Lane::Personalized as usize][0]
            .paths
            .iter()
            .any(|path| {
                !path.abbreviated
                    && path.score.personalized
                        + correction_context(path.context_adjustment, context_backoff).personalized
                        - MIN_CORRECTION_BITS
                        > floor
            })
    }

    fn is_empty(&self) -> bool {
        self.beams().all(|(_, beam)| beam.paths.is_empty())
    }
}

#[derive(Clone)]
struct Path {
    output: String,
    score: Scores,
    context_adjustment: Scores,
    history: History,
    mask: usize,
    constructed: bool,
    lexical_tokens: usize,
    completion: bool,
    trace: Rc<Trace>,
    personal: bool,
    verbatim: bool,
    token_sum: f64,
    units: usize,
    adjustment: f64,
    search_adjustment: f64,
    english_end: usize,
    splits_english: bool,
    confirmation_ambiguous: bool,
    corrected: bool,
    abbreviated: bool,
}

impl Path {
    fn token_bonus(&self) -> f64 {
        self.token_sum / self.units as f64
    }
}

struct EdgeDetails {
    cuts: Vec<usize>,
    confirmation: Option<Vec<ConversionBoundary>>,
    correction_kind: Option<CorrectionKind>,
}

impl EdgeDetails {
    fn new(edge: Match<'_>, input: &Input<'_>, start: usize) -> Self {
        let cuts = edge.cuts(start, input);
        let confirmation = if edge.word.language == Language::Chinese
            && !edge.is_abbreviated()
            && edge.correction_cost == 0.0
            && edge.missing == 0
            && edge.word.personal.is_none()
        {
            let output = edge.word.text;
            if output.chars().count() == cuts.len() && output.chars().all(han::is_han) {
                Some(
                    cuts.iter()
                        .copied()
                        .zip(
                            output
                                .char_indices()
                                .map(|(offset, ch)| offset + ch.len_utf8()),
                        )
                        .take(8)
                        .map(|(source_bytes, output_bytes)| ConversionBoundary {
                            source_bytes,
                            output_bytes,
                        })
                        .collect(),
                )
            } else {
                Some(vec![ConversionBoundary {
                    source_bytes: input.source_end(edge.end),
                    output_bytes: output.len(),
                }])
            }
        } else {
            None
        };
        Self {
            cuts,
            confirmation,
            correction_kind: edge.correction_kind,
        }
    }

    fn correction(&self, word_start_bytes: usize) -> Option<Correction> {
        Some(Correction {
            kind: self.correction_kind?,
            word_start_bytes,
            word_end_bytes: *self.cuts.last().expect("conversion edges consume source"),
        })
    }
}

struct Trace {
    previous: Option<Rc<Trace>>,
    details: Rc<EdgeDetails>,
    output_start: usize,
    space: bool,
}

impl Trace {
    fn correction(&self) -> Option<Correction> {
        std::iter::successors(Some(self), |node| node.previous.as_deref()).find_map(|node| {
            let start = node
                .previous
                .as_ref()
                .and_then(|previous| previous.details.cuts.last().copied())
                .unwrap_or_default();
            node.details.correction(start)
        })
    }

    fn inserted_spaces(&self) -> usize {
        std::iter::successors(Some(self), |node| node.previous.as_deref())
            .filter(|node| node.space)
            .count()
    }

    fn copy_without_spaces(&self, original: &str, output: &mut String) {
        let spaces: Vec<_> = std::iter::successors(Some(self), |node| node.previous.as_deref())
            .filter(|node| node.space)
            .map(|node| node.output_start - 1)
            .collect();
        let mut start = 0;
        for end in spaces.into_iter().rev() {
            output.push_str(&original[start..end]);
            start = end + 1;
        }
        output.push_str(&original[start..]);
    }

    fn boundaries(&self, include_confirmation: bool) -> (Vec<usize>, Vec<ConversionBoundary>) {
        let mut nodes = Vec::new();
        let mut current = Some(self);
        while let Some(node) = current {
            nodes.push(node);
            current = node.previous.as_deref();
        }
        let mut cuts = Vec::new();
        let mut confirmation = Vec::new();
        let mut leading = include_confirmation;
        for node in nodes.into_iter().rev() {
            cuts.extend(&node.details.cuts);
            if let Some(aligned) = node.details.confirmation.as_ref().filter(|_| leading) {
                confirmation.extend(aligned.iter().take(8 - confirmation.len()).map(|boundary| {
                    ConversionBoundary {
                        source_bytes: boundary.source_bytes,
                        output_bytes: node.output_start + boundary.output_bytes,
                    }
                }));
            } else {
                leading = false;
            }
        }
        (cuts, confirmation)
    }
}

#[derive(Default)]
struct Beam {
    paths: Vec<Path>,
}

impl Beam {
    fn could_enter(&self, score: f64, lane: Lane, width: usize, corrected: bool) -> bool {
        self.paths.len() < width
            || self.paths.last().is_some_and(|last| {
                let last_score = if corrected {
                    last.score + last.context_adjustment
                } else {
                    last.score
                };
                score >= lane.score(last_score, last.search_adjustment)
            })
    }

    fn insert(&mut self, path: Path, lane: Lane, terminal: bool, width: usize) {
        let equivalent = self.paths.iter().position(|current| {
            current.output == path.output
                && (terminal
                    || (current.history == path.history
                        && current.english_end == path.english_end
                        && current.splits_english == path.splits_english
                        && current.personal == path.personal
                        && current.verbatim == path.verbatim))
        });
        if let Some(index) = equivalent {
            let current = &mut self.paths[index];
            if path.mask == 1
                && !path.corrected
                && compare_paths(&path, current, lane, true) == Ordering::Equal
                && !current.confirmation_ambiguous
                && !Rc::ptr_eq(&path.trace, &current.trace)
                && (path.confirmation_ambiguous
                    || path.trace.boundaries(true).1 != current.trace.boundaries(true).1)
            {
                current.confirmation_ambiguous = true;
            }
        }
        let weakest_derivation = || {
            self.paths
                .iter()
                .enumerate()
                .filter(|(_, current)| current.output == path.output)
                .map(|(index, _)| index)
                .nth(MAX_DERIVATIONS_PER_TEXT - 1)
        };
        if let Some(index) = equivalent.or_else(weakest_derivation) {
            if compare_paths(&path, &self.paths[index], lane, true) != Ordering::Less {
                return;
            }
            self.paths.remove(index);
        }
        let position = self.paths.partition_point(|current| {
            compare_paths(current, &path, lane, true) != Ordering::Greater
        });
        if position < width {
            self.paths.insert(position, path);
            self.paths.truncate(width);
        }
    }
}

fn compare_paths(left: &Path, right: &Path, lane: Lane, for_search: bool) -> Ordering {
    let score = |path: &Path| {
        lane.score(
            path.score + path.context_adjustment,
            if for_search {
                path.search_adjustment
            } else {
                path.adjustment
            },
        )
    };
    score(right)
        .total_cmp(&score(left))
        .then_with(|| left.output.cmp(&right.output))
        .then_with(|| left.completion.cmp(&right.completion))
}
