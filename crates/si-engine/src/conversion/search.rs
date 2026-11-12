use std::borrow::Cow;
use std::cmp::Ordering;

use super::input::Input;
use super::lookup::{Lookup, Match};
use super::ranking::{Completions, Results};
use super::scoring::{History, ScoreSession, Scores, Scoring};
use super::{Candidate, CandidateLanguage, EnabledLanguages, Language};

const MAX_SEARCH_UNITS: usize = 128;
const MAX_OUTPUT_BYTES: usize = 4_096;
const BEAM_WIDTH: usize = 24;
const MAX_DERIVATIONS_PER_TEXT: usize = 2;
const COMPOSED_PREFIXES_PER_BEAM: usize = 2;

pub(super) fn run(
    input: &Input<'_>,
    languages: EnabledLanguages,
    lookup: &Lookup<'_>,
    scoring: &Scoring<'_>,
) -> Vec<Candidate> {
    let limit = input.len().min(MAX_SEARCH_UNITS);
    let mut search = Search {
        input,
        limit,
        scoring: scoring.session(),
        lattice: (0..=limit).map(|_| Frontier::default()).collect(),
        results: Results::default(),
    };
    let enabled = Language::ALL
        .into_iter()
        .filter(|language| language.enabled(languages));
    for language in enabled.clone() {
        let mut completions = Completions::default();
        lookup.visit(language, input, 0, input.len(), |edge| {
            search.seed(edge, &mut completions, scoring.has_user());
        });
        for candidate in completions.into_rows() {
            search.results.insert(candidate);
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
        }
    }
    search.results.ranked()
}

struct Search<'input, 'model, 'data> {
    input: &'input Input<'input>,
    limit: usize,
    scoring: ScoreSession<'model, 'data>,
    lattice: Vec<Frontier>,
    results: Results,
}

impl Search<'_, '_, '_> {
    fn seed(&mut self, edge: Match<'_>, completions: &mut Completions, has_user: bool) {
        let mask = edge.word.language.mask();
        let (history, score) = self
            .scoring
            .step(History::default(), edge.word, edge.missing);
        if edge.missing != 0 && !completions.could_enter(score.personalized) {
            return;
        }
        let output = render(edge, self.input.source_span(0, edge.end));
        let candidate = Candidate {
            text: output.to_string(),
            language: candidate_language(mask),
            consumed_bytes: self.input.source_end(edge.end),
            score_bits: Some(score.personalized),
            completion: edge.missing != 0,
        };
        if candidate.completion {
            completions.insert(candidate);
            return;
        }
        self.results.insert(candidate);
        if edge.end >= self.limit || output.len() > MAX_OUTPUT_BYTES {
            return;
        }
        let path = Path {
            output: output.into_owned(),
            score,
            history,
            mask,
            constructed: false,
            completion: false,
        };
        let frontier = &mut self.lattice[edge.end];
        if has_user && edge.word.ids.base.is_some() {
            frontier
                .beam(Lane::Base, mask)
                .insert(path.clone(), Lane::Base, false);
        }
        frontier
            .beam(Lane::Personalized, mask)
            .insert(path, Lane::Personalized, false);
    }

    fn collect(&mut self, end: usize, frontier: &Frontier) {
        let whole = end == self.input.len();
        for (_, beam) in frontier.beams() {
            let mut seen = Vec::new();
            for path in beam.paths.iter().filter(|path| path.constructed) {
                if !whole {
                    if seen.contains(&path.output.as_str()) {
                        continue;
                    }
                    if seen.len() == COMPOSED_PREFIXES_PER_BEAM {
                        break;
                    }
                    seen.push(path.output.as_str());
                }
                self.results.insert(Candidate {
                    text: path.output.clone(),
                    language: candidate_language(path.mask),
                    consumed_bytes: self.input.source_end(end),
                    score_bits: Some(path.score.personalized),
                    completion: path.completion,
                });
            }
        }
    }

    fn extend(&mut self, start: usize, frontier: &Frontier, edge: Match<'_>) {
        let language = edge.word.language;
        let surface = render(edge, self.input.source_span(start, edge.end));
        let terminal = edge.end == self.limit;
        for (lane, beam) in frontier.beams() {
            if lane == Lane::Base && edge.word.ids.base.is_none() {
                continue;
            }
            for path in &beam.paths {
                let space =
                    language == Language::English || path.history.last() == Some(Language::English);
                if path.output.len() + surface.len() + usize::from(space) > MAX_OUTPUT_BYTES {
                    continue;
                }
                let (history, delta) = self.scoring.step(path.history, edge.word, edge.missing);
                let score = path.score + delta;
                let mask = path.mask | language.mask();
                let target = self.lattice[edge.end].beam(lane, mask);
                if !target.could_enter(score, lane) {
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
                        completion: edge.missing != 0,
                    },
                    lane,
                    terminal,
                );
            }
        }
    }
}

fn render<'a>(edge: Match<'a>, typed: &str) -> Cow<'a, str> {
    let text = edge.word.text;
    if edge.word.language == Language::English {
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

    fn score(self, scores: Scores) -> f64 {
        match self {
            Self::Base => scores.base,
            Self::Personalized => scores.personalized,
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
    completion: bool,
}

#[derive(Default)]
struct Beam {
    paths: Vec<Path>,
}

impl Beam {
    fn could_enter(&self, score: Scores, lane: Lane) -> bool {
        self.paths.len() < BEAM_WIDTH
            || lane.score(score) >= lane.score(self.paths.last().unwrap().score)
    }

    fn insert(&mut self, path: Path, lane: Lane, terminal: bool) {
        let compare = |left: &Path, right: &Path| {
            lane.score(right.score)
                .total_cmp(&lane.score(left.score))
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
        if position < BEAM_WIDTH {
            self.paths.insert(position, path);
            self.paths.truncate(BEAM_WIDTH);
        }
    }
}
