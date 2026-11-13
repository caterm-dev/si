use std::borrow::Cow;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::rc::Rc;

use super::input::Input;
use super::lookup::{Lookup, Match};
use super::ranking::{Completions, Results};
use super::scoring::{History, ScoreSession, Scores, Scoring};
use super::{
    Candidate, CandidateLanguage, ConversionBoundary, EnabledLanguages, Language, TokenPreference,
};
use crate::han;

const MAX_SEARCH_UNITS: usize = 128;
const MAX_OUTPUT_BYTES: usize = 4_096;
const BEAM_WIDTH: usize = 24;
const PREVIEW_BEAM_WIDTH: usize = 6;
const PREVIEW_SEARCH_UNITS: usize = 32;
const MAX_DERIVATIONS_PER_TEXT: usize = 2;
const COMPOSED_PREFIXES_PER_BEAM: usize = 2;
const PERSONAL_EDGES_PER_SPAN: usize = 12;
const ABBREVIATION_BITS: f64 = 7.0;

pub(super) fn run(
    input: &Input<'_>,
    languages: EnabledLanguages,
    lookup: &Lookup<'_>,
    scoring: &Scoring<'_>,
    preview: bool,
    personal: &Lookup<'_>,
    preferences: &[TokenPreference<'_>],
) -> Vec<Candidate> {
    let limit = if preview {
        input.len().min(PREVIEW_SEARCH_UNITS)
    } else {
        input.len().min(MAX_SEARCH_UNITS)
    };
    let mut search = Search {
        input,
        limit,
        beam_width: if preview {
            PREVIEW_BEAM_WIDTH
        } else {
            BEAM_WIDTH
        },
        scoring: scoring.session(),
        lattice: (0..=limit).map(|_| Frontier::default()).collect(),
        results: Results::default(),
        preferences: TokenBonuses::new(preferences),
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
            search.seed(
                edge,
                &mut completions,
                scoring.has_user() || !preferences.is_empty(),
                true,
            );
        });
        let mut seen = vec![0; limit];
        personal.visit(language, input, 0, input.len(), |edge| {
            let can_extend = allow_personal_edge(&mut seen, edge.end);
            search.seed(edge, &mut completions, false, can_extend);
        });
        for candidate in completions.into_rows() {
            search.results.insert(candidate);
        }
    }
    if !exact_whole && !exact_starts[0] {
        for &end in &chinese_starts {
            if let Some(edge) = verbatim(input, 0, end) {
                search.seed_verbatim(edge);
            }
        }
    }
    for start in 1..=limit {
        let frontier = std::mem::take(&mut search.lattice[start]);
        search.collect(start, &frontier);
        if start == limit || frontier.is_empty() {
            continue;
        }
        for language in enabled.clone() {
            lookup.visit(language, input, start, limit, |edge| {
                search.extend(start, &frontier, edge)
            });
            let mut seen = vec![0; limit + 1];
            personal.visit(language, input, start, limit, |edge| {
                if allow_personal_edge(&mut seen, edge.end) {
                    search.extend(start, &frontier, edge);
                }
            });
        }
        if !exact_whole && exact_starts.get(start) == Some(&false) {
            for end in chinese_starts
                .iter()
                .copied()
                .chain(std::iter::once(limit))
                .filter(|&end| end > start)
            {
                if let Some(edge) = verbatim(input, start, end) {
                    search.extend(start, &frontier, edge);
                }
            }
        }
    }
    search.results.ranked()
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
    preferences: TokenBonuses<'preferences>,
}

struct TokenBonuses<'a>(HashMap<(Language, &'a str, &'a str), f64>);

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
        let (history, score) = self.scoring.step(History::default(), edge.word, 0);
        let mask = Language::English.mask();
        let path = Path {
            output: edge.word.text.to_owned(),
            score,
            history,
            mask,
            constructed: false,
            lexical_tokens: 0,
            completion: false,
            personal: false,
            last_personal: false,
            verbatim: true,
            token_sum: 0.0,
            units: edge.end,
            trace: Rc::new(Trace {
                previous: None,
                details: Rc::new(EdgeDetails::new(edge, self.input, 0)),
                output_start: 0,
            }),
        };
        self.lattice[edge.end]
            .beam(Lane::Personalized, mask)
            .insert(path, Lane::Personalized, false, self.beam_width);
    }

    fn seed(
        &mut self,
        edge: Match<'_>,
        completions: &mut Completions,
        has_user: bool,
        can_extend: bool,
    ) {
        let mask = edge.word.language.mask();
        let (history, mut score) = self
            .scoring
            .step(History::default(), edge.word, edge.missing);
        if edge.is_abbreviated() {
            score.base -= ABBREVIATION_BITS;
            score.personalized -= ABBREVIATION_BITS;
        }
        let personal = edge.word.personal.is_some();
        if edge.missing != 0 && !personal && !completions.could_enter(score.personalized) {
            return;
        }
        let output = render(edge, self.input.source_span(0, edge.end));
        let details = Rc::new(EdgeDetails::new(edge, self.input, 0));
        let candidate = Candidate {
            text: output.to_string(),
            language: candidate_language(mask),
            consumed_bytes: self.input.source_end(edge.end),
            score_bits: Some(score.personalized),
            completion: edge.missing != 0,
            lexical_tokens: 1,
            source_boundaries: details.cuts.clone(),
            confirmation_boundaries: details.confirmation.clone().unwrap_or_default(),
            personal,
            preferred: edge.word.personal == Some(true)
                && edge.missing == 0
                && edge.end == self.input.len(),
            verbatim: false,
            token_bonus: 0.0,
        };
        if candidate.completion && !personal {
            completions.insert(candidate);
            return;
        }
        self.results.insert(candidate);
        if !can_extend || edge.end >= self.limit || output.len() > MAX_OUTPUT_BYTES {
            return;
        }
        let token_sum = self.preferences.get(edge, self.input, 0, &output) * edge.end as f64;
        let path = Path {
            output: output.into_owned(),
            score,
            history,
            mask,
            constructed: false,
            lexical_tokens: 1,
            completion: false,
            personal,
            last_personal: personal,
            verbatim: false,
            token_sum,
            units: edge.end,
            trace: Rc::new(Trace {
                previous: None,
                details,
                output_start: 0,
            }),
        };
        let frontier = &mut self.lattice[edge.end];
        if has_user && edge.word.ids.base.is_some() {
            frontier.beam(Lane::Base, mask).insert(
                path.clone(),
                Lane::Base,
                false,
                self.beam_width,
            );
        }
        frontier.beam(Lane::Personalized, mask).insert(
            path,
            Lane::Personalized,
            false,
            self.beam_width,
        );
    }

    fn collect(&mut self, end: usize, frontier: &Frontier) {
        let whole = end == self.input.len();
        for (_, beam) in frontier.beams() {
            let mut seen = Vec::new();
            for path in beam
                .paths
                .iter()
                .filter(|path| path.constructed && (!path.verbatim || (whole && path.mask == 3)))
            {
                if !whole {
                    if seen.contains(&path.output.as_str()) {
                        continue;
                    }
                    if seen.len() == COMPOSED_PREFIXES_PER_BEAM {
                        break;
                    }
                    seen.push(path.output.as_str());
                }
                let (source_boundaries, confirmation_boundaries) = path.trace.boundaries();
                self.results.insert(Candidate {
                    text: path.output.clone(),
                    language: candidate_language(path.mask),
                    consumed_bytes: self.input.source_end(end),
                    score_bits: Some(path.score.personalized),
                    completion: path.completion,
                    lexical_tokens: path.lexical_tokens,
                    source_boundaries,
                    confirmation_boundaries,
                    personal: path.personal,
                    preferred: false,
                    verbatim: path.verbatim,
                    token_bonus: path.token_bonus(),
                });
            }
        }
    }

    fn extend(&mut self, start: usize, frontier: &Frontier, edge: Match<'_>) {
        let language = edge.word.language;
        let surface = render(edge, self.input.source_span(start, edge.end));
        let terminal = edge.end == self.limit;
        let details = Rc::new(EdgeDetails::new(edge, self.input, start));
        let personal = edge.word.personal.is_some();
        let token_sum =
            self.preferences.get(edge, self.input, start, &surface) * (edge.end - start) as f64;
        for (lane, beam) in frontier.beams() {
            if lane == Lane::Base && edge.word.ids.base.is_none() {
                continue;
            }
            for path in &beam.paths {
                if edge.word.verbatim
                    && (path.verbatim || path.mask & Language::Chinese.mask() == 0)
                {
                    continue;
                }
                let verbatim = path.verbatim || edge.word.verbatim;
                let space = !verbatim
                    && !personal
                    && !path.last_personal
                    && (language == Language::English
                        || path.history.last() == Some(Language::English));
                if path.output.len() + surface.len() + usize::from(space) > MAX_OUTPUT_BYTES {
                    continue;
                }
                let (history, mut delta) = self.scoring.step(path.history, edge.word, edge.missing);
                if edge.is_abbreviated() {
                    delta.base -= ABBREVIATION_BITS;
                    delta.personalized -= ABBREVIATION_BITS;
                }
                let score = path.score + delta;
                let mask = path.mask | language.mask();
                let target = self.lattice[edge.end].beam(lane, mask);
                let token_sum = if verbatim || personal || path.personal {
                    0.0
                } else {
                    path.token_sum + token_sum
                };
                let bonus = token_sum / edge.end as f64;
                if !target.could_enter(lane.score(score, bonus), lane, self.beam_width) {
                    continue;
                }
                let mut output =
                    String::with_capacity(path.output.len() + surface.len() + usize::from(space));
                output.push_str(&path.output);
                if space {
                    output.push(' ');
                }
                output.push_str(&surface);
                target.insert(
                    Path {
                        output,
                        score,
                        history,
                        mask,
                        constructed: true,
                        lexical_tokens: path.lexical_tokens + 1,
                        completion: edge.missing != 0,
                        personal: personal || path.personal,
                        last_personal: personal,
                        verbatim,
                        token_sum,
                        units: edge.end,
                        trace: Rc::new(Trace {
                            previous: Some(Rc::clone(&path.trace)),
                            details: Rc::clone(&details),
                            output_start: path.output.len() + usize::from(space),
                        }),
                    },
                    lane,
                    terminal,
                    self.beam_width,
                );
            }
        }
    }
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
}

impl Frontier {
    fn beam(&mut self, lane: Lane, mask: usize) -> &mut Beam {
        &mut self.lanes[lane as usize][mask - 1]
    }

    fn beams(&self) -> impl Iterator<Item = (Lane, &Beam)> {
        Lane::ALL.into_iter().flat_map(|lane| {
            self.lanes[lane as usize]
                .iter()
                .map(move |beam| (lane, beam))
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
    history: History,
    mask: usize,
    constructed: bool,
    lexical_tokens: usize,
    completion: bool,
    trace: Rc<Trace>,
    personal: bool,
    last_personal: bool,
    verbatim: bool,
    token_sum: f64,
    units: usize,
}

impl Path {
    fn token_bonus(&self) -> f64 {
        self.token_sum / self.units as f64
    }
}

struct EdgeDetails {
    cuts: Vec<usize>,
    confirmation: Option<Vec<ConversionBoundary>>,
}

impl EdgeDetails {
    fn new(edge: Match<'_>, input: &Input<'_>, start: usize) -> Self {
        let cuts = edge.cuts(start, input);
        let confirmation = if edge.word.language == Language::Chinese
            && !edge.is_abbreviated()
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
        Self { cuts, confirmation }
    }
}

struct Trace {
    previous: Option<Rc<Trace>>,
    details: Rc<EdgeDetails>,
    output_start: usize,
}

impl Trace {
    fn boundaries(&self) -> (Vec<usize>, Vec<ConversionBoundary>) {
        let mut nodes = Vec::new();
        let mut current = Some(self);
        while let Some(node) = current {
            nodes.push(node);
            current = node.previous.as_deref();
        }
        let mut cuts = Vec::new();
        let mut confirmation = Vec::new();
        let mut leading = true;
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
    fn could_enter(&self, score: f64, lane: Lane, width: usize) -> bool {
        self.paths.len() < width
            || self
                .paths
                .last()
                .is_some_and(|last| score >= lane.score(last.score, last.token_bonus()))
    }

    fn insert(&mut self, path: Path, lane: Lane, terminal: bool, width: usize) {
        let compare = |left: &Path, right: &Path| {
            lane.score(right.score, right.token_bonus())
                .total_cmp(&lane.score(left.score, left.token_bonus()))
                .then_with(|| left.output.cmp(&right.output))
                .then_with(|| left.completion.cmp(&right.completion))
        };
        let equivalent = self.paths.iter().position(|current| {
            current.output == path.output && (terminal || current.history == path.history)
        });
        let weakest_derivation = || {
            self.paths
                .iter()
                .enumerate()
                .filter(|(_, current)| current.output == path.output)
                .map(|(index, _)| index)
                .nth(MAX_DERIVATIONS_PER_TEXT - 1)
        };
        if let Some(index) = equivalent.or_else(weakest_derivation) {
            if compare(&path, &self.paths[index]) != Ordering::Less {
                return;
            }
            self.paths.remove(index);
        }
        let position = self
            .paths
            .partition_point(|current| compare(current, &path) != Ordering::Greater);
        if position < width {
            self.paths.insert(position, path);
            self.paths.truncate(width);
        }
    }
}
