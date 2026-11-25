//! Bounded written-text paths, keeping the best path for each caller-defined terminal history.

use std::cmp::Ordering;

use super::{Segment, Segmenter};
use crate::text_boundaries::{Part, parts};

const MAX_STATES: usize = 8_192;
const MAX_TRANSITIONS: usize = 65_536;

struct State<H> {
    history: H,
    score: f64,
    // Reverse lexicographic cuts retain the single-path segmenter's longer-final-edge ties.
    cuts: Vec<usize>,
}

impl<H> State<H> {
    fn compare(&self, other: &Self) -> Ordering {
        other
            .score
            .total_cmp(&self.score)
            .then_with(|| self.cuts.iter().rev().cmp(other.cuts.iter().rev()))
    }
}

impl Segmenter<'_> {
    /// Maximize, rather than sum, path scores sharing a terminal history. The caller
    /// truncates the sorted distinct histories to K. None requests single-path fallback.
    pub(crate) fn histories<H: Clone + Eq>(
        &self,
        text: &str,
        empty: H,
        mut advance: impl FnMut(H, &Segment) -> H,
    ) -> Option<Vec<(f64, H)>> {
        let mut frontier = vec![State {
            history: empty.clone(),
            score: 0.0,
            cuts: Vec::new(),
        }];
        let mut states = 1;
        let mut transitions = 0;
        for part in parts(text) {
            let part = match part {
                Part::Wrapper => continue,
                Part::SentenceBoundary | Part::Gap => {
                    frontier.sort_by(State::compare);
                    frontier.truncate(1);
                    frontier[0].history = empty.clone();
                    continue;
                }
                Part::Text(part) => part,
            };
            let offset = part.as_ptr() as usize - text.as_ptr() as usize;
            let mut positions: Vec<Vec<State<H>>> = (0..=part.len()).map(|_| Vec::new()).collect();
            positions[0] = frontier;
            for (start, _) in part.char_indices() {
                if positions[start].is_empty() {
                    continue;
                }
                let previous = std::mem::take(&mut positions[start]);
                let mut edges = Vec::new();
                self.visit_edges(part, start, false, false, |len, kind, score| {
                    let range = start..start + len;
                    edges.push((
                        Segment {
                            kind: self.resolved_kind(&part[range], kind),
                            range: offset + start..offset + start + len,
                        },
                        score,
                    ));
                });
                for state in &previous {
                    for (segment, score) in &edges {
                        transitions += 1;
                        if transitions > MAX_TRANSITIONS {
                            return None;
                        }
                        let history = advance(state.history.clone(), segment);
                        let mut cuts = state.cuts.clone();
                        cuts.push(segment.range.start);
                        let next = State {
                            history,
                            score: state.score + score,
                            cuts,
                        };
                        let destination = &mut positions[segment.range.end - offset];
                        if let Some(old) = destination
                            .iter_mut()
                            .find(|old| old.history == next.history)
                        {
                            if next.compare(old).is_lt() {
                                *old = next;
                            }
                        } else {
                            states += 1;
                            if states > MAX_STATES {
                                return None;
                            }
                            destination.push(next);
                        }
                    }
                }
            }
            frontier = std::mem::take(&mut positions[part.len()]);
        }
        frontier.sort_by(State::compare);
        Some(
            frontier
                .into_iter()
                .map(|row| (row.score, row.history))
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::segmentation::SegmentKind;
    use si_lexicon::{IndexId, Lexicon, WordId};

    #[test]
    fn duplicate_prefix_paths_do_not_consume_terminal_history_slots_or_add_probability() {
        let mut lexicon = Lexicon::new();
        for (text, reading, count) in [
            ("最好", "zui'hao", 1_000),
            ("最", "zui", 900),
            ("好", "hao", 900),
            ("多种", "duo'zhong", 100),
            ("多", "duo", 80),
            ("种", "zhong", 80),
            ("几棵", "ji'ke", 100),
            ("几", "ji", 80),
            ("棵", "ke", 80),
        ] {
            lexicon
                .add_reading(IndexId(0), reading.as_bytes(), text, count)
                .unwrap();
        }
        let segmenter = Segmenter::new(&lexicon);
        let histories = |text| {
            segmenter
                .histories(text, Vec::<WordId>::new(), |mut h, s| {
                    match s.kind {
                        SegmentKind::Word(id) => {
                            h.push(id);
                            if h.len() > 2 {
                                h.remove(0);
                            }
                        }
                        SegmentKind::Space => {}
                        _ => h.clear(),
                    }
                    h
                })
                .unwrap()
        };
        let rows = histories("最好多种几棵");
        let recognized: Vec<_> = rows.iter().filter(|(_, h)| h.len() == 2).take(3).collect();
        let words = |h: &[WordId]| {
            h.iter()
                .map(|&id| lexicon.word(id).unwrap().text)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            recognized.iter().map(|(_, h)| words(h)).collect::<Vec<_>>(),
            [vec!["多种", "几棵"], vec!["种", "几棵"], vec!["几", "棵"]]
        );
        let best = &recognized[0];
        let tail = histories("多种几棵");
        let prefix = histories("最好");
        assert!((best.0 - tail[0].0 - prefix[0].0).abs() < 1e-12);
    }

    #[test]
    fn dense_terminal_histories_obey_the_search_budget() {
        let mut lexicon = Lexicon::new();
        for length in 1..=7 {
            lexicon
                .add_reading(
                    IndexId(0),
                    vec![b'j'; length].as_slice(),
                    &"甲".repeat(length),
                    100,
                )
                .unwrap();
        }
        let segmenter = Segmenter::new(&lexicon);
        let rows = segmenter.histories(&"甲".repeat(96), Vec::<WordId>::new(), |mut h, s| {
            if let SegmentKind::Word(id) = s.kind {
                h.push(id);
                if h.len() > 4 {
                    h.remove(0);
                }
            } else {
                h.clear();
            }
            h
        });
        assert!(rows.is_none());
    }
}
