//! Request-local maxima for competing sentence openings, before lexical beam pruning.

use std::collections::HashMap;

use super::input::Input;
use super::lookup::{CorrectionBudget, Lookup, Match};
use super::scoring::{ScoreSession, StartHistory, StartSpan};
use super::{EnabledLanguages, Language, MAX_OUTPUT_BYTES};

const MAX_STATES: usize = 8_192;
const MAX_TRANSITIONS: usize = 65_536;

#[derive(Clone, Copy, Eq, Hash, PartialEq)]
struct State {
    opening: StartHistory,
    last: Option<Language>,
    mask: usize,
    corrected: bool,
    abbreviated: bool,
}

/// Compare enabled dictionary paths over the same consumed source span. The
/// shared global probability denominator cancels, leaving count / maximum count.
/// If the bounded traversal cannot finish, disable opening rewards for the
/// unfinished spans instead of using a partial maximum. Earlier completed
/// spans remain valid even when a pending suffix exceeds the traversal budget.
pub(super) fn prepare<'data>(
    input: &Input<'_>,
    limit: usize,
    languages: EnabledLanguages,
    lookup: &Lookup<'data>,
    personal: &Lookup<'_>,
    scoring: &mut ScoreSession<'_, '_>,
    mut correction: bool,
) -> HashMap<StartSpan, u64> {
    let Some(opening) = scoring.initial_start() else {
        return HashMap::new();
    };
    let enabled = || {
        Language::ALL
            .into_iter()
            .filter(|language| language.enabled(languages))
    };
    if correction {
        for language in enabled() {
            lookup.visit(language, input, 0, input.len(), |edge| {
                if language == Language::English && edge.end == input.len() && edge.missing == 0 {
                    correction = false;
                }
            });
            personal.visit(language, input, 0, input.len(), |edge| {
                if edge.end == input.len() && edge.missing == 0 {
                    correction = false;
                }
            });
        }
    }
    let suffixes = if correction {
        lookup.correction_suffixes(input)
    } else {
        Vec::new()
    };
    let mut correction_budget = CorrectionBudget::default();
    let mut states: Vec<HashMap<State, usize>> = (0..=limit).map(|_| HashMap::new()).collect();
    states[0].insert(
        State {
            opening,
            last: None,
            mask: 0,
            corrected: false,
            abbreviated: false,
        },
        0,
    );
    let mut maxima = HashMap::<StartSpan, u64>::new();
    let mut state_count = 1;
    let mut transitions = 0;
    let mut cutoff = None;
    for start in 0..=limit {
        if cutoff.is_some_and(|end| start >= end) {
            break;
        }
        let incoming = std::mem::take(&mut states[start]);
        if incoming.is_empty() || (start == limit && start != 0) {
            continue;
        }
        let mut edges = Vec::new();
        let mut overflow = false;
        let mut emit = |edge: Match<'data>| {
            if edges.len() >= MAX_TRANSITIONS {
                overflow = true;
            } else {
                edges.push(edge);
            }
        };
        let end_limit = if start == 0 { input.len() } else { limit };
        for language in enabled() {
            lookup.visit(language, input, start, end_limit, &mut emit);
        }
        if correction
            && incoming
                .keys()
                .any(|state| !state.corrected && !state.abbreviated && matches!(state.mask, 0 | 1))
        {
            lookup.visit_corrections(
                input,
                start,
                limit,
                &mut correction_budget,
                &suffixes,
                &mut emit,
            );
        }
        if overflow {
            maxima.retain(|span, _| span.end <= start);
            return maxima;
        }
        let mut by_word = HashMap::new();
        for (index, edge) in edges.iter().enumerate() {
            if let Some(id) = edge.word.ids.base {
                by_word.entry(id).or_insert_with(Vec::new).push(index);
            }
        }
        for (state, bytes) in incoming {
            let mut indices: Vec<_> = match scoring.final_start_words(state.opening) {
                Some(words) => words
                    .flat_map(|id| by_word.get(&id).into_iter().flatten().copied())
                    .collect(),
                None => (0..edges.len()).collect(),
            };
            indices.sort_unstable();
            for index in indices {
                let edge = &edges[index];
                transitions += 1;
                if transitions > MAX_TRANSITIONS {
                    maxima.retain(|span, _| span.end <= start);
                    return maxima;
                }
                let corrected = state.corrected || edge.correction_cost > 0.0;
                if corrected
                    && (state.corrected && edge.correction_cost > 0.0
                        || state.abbreviated
                        || !matches!(state.mask, 0 | 1)
                        || edge.word.language != Language::Chinese
                        || edge.is_abbreviated())
                {
                    continue;
                }
                let bytes = bytes
                    + edge.word.text.len()
                    + usize::from(
                        state.last.is_some()
                            && (state.last == Some(Language::English)
                                || edge.word.language == Language::English),
                    );
                if start != 0 && bytes > MAX_OUTPUT_BYTES {
                    continue;
                }
                let opening = scoring.advance_start(state.opening, edge.word.ids.base);
                maxima
                    .entry(StartSpan {
                        end: edge.end,
                        completion: edge.missing > 0,
                        corrected,
                    })
                    .and_modify(|value| *value = (*value).max(opening.count))
                    .or_insert(opening.count);
                if edge.end >= limit
                    || edge.missing > 0
                    || bytes > MAX_OUTPUT_BYTES
                    || (opening.remaining == 0 && opening.count == 0)
                {
                    continue;
                }
                let next = State {
                    opening,
                    last: Some(edge.word.language),
                    mask: state.mask | edge.word.language.mask(),
                    corrected,
                    abbreviated: state.abbreviated || edge.is_abbreviated(),
                };
                match states[edge.end].entry(next) {
                    std::collections::hash_map::Entry::Occupied(mut entry) => {
                        *entry.get_mut() = (*entry.get()).min(bytes);
                    }
                    std::collections::hash_map::Entry::Vacant(entry) => {
                        state_count += 1;
                        if state_count > MAX_STATES {
                            cutoff = Some(cutoff.map_or(edge.end, |end: usize| end.min(edge.end)));
                            continue;
                        }
                        entry.insert(bytes);
                    }
                }
            }
        }
    }
    if let Some(end) = cutoff {
        maxima.retain(|span, _| span.end <= end);
    }
    maxima
}
