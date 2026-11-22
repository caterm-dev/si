use std::collections::{HashMap, HashSet};

use crate::conversion::{CorrectionKind, MAX_OUTPUT_BYTES};

use super::{Entry, Input, Language, Lexeme, Lookup, Match, lookup_syllable, matches_separators};

pub(in crate::conversion) const MIN_CORRECTION_BITS: f64 = 8.0;

const MAX_WORD_UNITS: usize = 48;
// A missing key can make the dictionary reading one unit longer than the window.
const _: () = assert!(MAX_WORD_UNITS + 1 < u64::BITS as usize);
const MAX_PROBES: usize = 384;
const MAX_TERMINALS: usize = 4_096;
const MAX_ROWS_PER_SPELLING: usize = 128;
const MAX_READING_FALLBACKS: usize = 16;

pub(super) struct CorrectionRows {
    preferred: Vec<usize>,
    other_readings: Vec<usize>,
}
const KEY_POSITIONS: [(usize, usize); 26] = key_positions();

#[derive(Clone, Copy)]
enum Edit {
    Missing,
    Replace,
    Swap,
}

impl Edit {
    fn lengths(self) -> (usize, usize) {
        match self {
            Self::Missing => (0, 1),
            Self::Replace => (1, 1),
            Self::Swap => (2, 2),
        }
    }

    fn kind(self) -> CorrectionKind {
        match self {
            Self::Missing => CorrectionKind::MissingKey,
            Self::Replace => CorrectionKind::NeighborKey,
            Self::Swap => CorrectionKind::AdjacentSwap,
        }
    }

    fn cost(self) -> f64 {
        match self {
            Self::Swap | Self::Missing => MIN_CORRECTION_BITS,
            Self::Replace => 11.0,
        }
    }
}

pub(in crate::conversion) struct CorrectionBudget {
    probes: usize,
    terminals: usize,
}

impl Default for CorrectionBudget {
    fn default() -> Self {
        Self {
            probes: 8_192,
            terminals: 32_768,
        }
    }
}

impl<'a> Lookup<'a> {
    pub(in crate::conversion) fn prepare_corrections(
        &mut self,
        unigram: impl Fn(Lexeme<'a>) -> f64,
    ) {
        if self.correction_order.is_some() {
            return;
        }
        let mut correction_order = HashMap::new();
        for rows in self.entries[Language::Chinese as usize]
            .chunk_by(|left, right| left.spelling == right.spelling)
            .filter(|rows| {
                rows.len() > MAX_ROWS_PER_SPELLING && rows[0].spelling.len() <= MAX_WORD_UNITS + 1
            })
        {
            let mut priorities: Vec<_> = rows
                .iter()
                .enumerate()
                .filter(|(_, row)| row.word.text.len() <= MAX_OUTPUT_BYTES)
                .map(|(index, row)| (index, unigram(row.word), syllable_ends(row.reading)))
                .collect();
            let compare = |left: &(usize, f64, u64), right: &(usize, f64, u64)| {
                right.1.total_cmp(&left.1).then(left.0.cmp(&right.0))
            };
            let mut readings = HashMap::new();
            for &row in &priorities {
                let best = readings.entry(row.2).or_insert(row);
                if compare(&row, best).is_lt() {
                    *best = row;
                }
            }
            if priorities.len() > MAX_ROWS_PER_SPELLING {
                priorities.select_nth_unstable_by(MAX_ROWS_PER_SPELLING, compare);
                priorities.truncate(MAX_ROWS_PER_SPELLING);
            }
            priorities.sort_unstable_by(compare);
            let ordinary_readings: HashSet<_> =
                priorities.iter().map(|&(_, _, ends)| ends).collect();
            let mut other_readings: Vec<_> = readings
                .into_iter()
                .filter_map(|(ends, row)| (!ordinary_readings.contains(&ends)).then_some(row))
                .collect();
            other_readings.sort_unstable_by(compare);
            other_readings.truncate(MAX_READING_FALLBACKS);
            correction_order.insert(
                rows[0].spelling.to_vec(),
                CorrectionRows {
                    preferred: priorities.into_iter().map(|(index, _, _)| index).collect(),
                    other_readings: other_readings
                        .into_iter()
                        .map(|(index, _, _)| index)
                        .collect(),
                },
            );
        }
        self.correction_order = Some(correction_order);
    }

    pub(in crate::conversion) fn exact_suffixes(&self, input: &Input<'_>) -> Vec<bool> {
        let limit = input.len();
        let spelling = input.spelling(Language::Chinese);
        let dictionary = self.entries[Language::Chinese as usize].as_slice();
        let mut prefixes = self.prefixes[Language::Chinese as usize].query(dictionary);
        let mut reachable = vec![false; limit + 1];
        reachable[limit] = true;
        for start in (0..limit).rev() {
            let mut rows = dictionary;
            for (depth, &byte) in spelling[start..].iter().enumerate() {
                rows = prefixes.matching(rows, depth, byte);
                if rows.is_empty() {
                    break;
                }
                let length = depth + 1;
                let end = start + length;
                if reachable[end] && rows[0].spelling.len() == length {
                    let mut separators = input.separators(start, end).peekable();
                    if separators.peek().is_none()
                        || rows
                            .iter()
                            .take_while(|row| row.spelling.len() == length)
                            .any(|row| matches_separators(row.reading, separators.clone()))
                    {
                        reachable[start] = true;
                        break;
                    }
                }
            }
        }
        reachable
    }

    pub(in crate::conversion) fn visit_corrections<'lookup>(
        &'lookup self,
        input: &Input<'_>,
        start: usize,
        limit: usize,
        budget: &mut CorrectionBudget,
        exact_suffixes: &[bool],
        mut emit: impl FnMut(Match<'a>),
    ) {
        let window_end = limit.min(start + MAX_WORD_UNITS);
        if window_end - start < 2 {
            return;
        }
        let Some(last_end) = exact_suffixes[start + 2..=window_end]
            .iter()
            .rposition(|&reachable| reachable)
            .map(|offset| offset + 2)
        else {
            return;
        };
        let later_positions = limit - start - 1;
        // Reserve a share for later positions so early ambiguous spans cannot
        // exhaust the budget before the search reaches an error near the end.
        let probe_limit = MAX_PROBES.min(budget.probes.saturating_sub(later_positions * 8));
        let terminal_limit =
            MAX_TERMINALS.min(budget.terminals.saturating_sub(later_positions * 64));
        if probe_limit == 0 || terminal_limit == 0 {
            return;
        }
        let spelling = &input.spelling(Language::Chinese)[start..window_end];
        let mut rows = self.entries[Language::Chinese as usize].as_slice();
        let mut prefixes = self.prefixes[Language::Chinese as usize].query(rows);
        let mut probes = probe_limit;
        let mut terminals = terminal_limit;
        let mut matches: Vec<Match<'a>> = Vec::new();
        let mut seen = HashMap::new();
        // A missing key can end an edited word without consuming the next
        // input letter, so still visit the position at the last endpoint.
        for (position, &typed) in spelling.iter().take(last_end + 1).enumerate() {
            if typed == 0 || rows.is_empty() || probes == 0 || terminals == 0 {
                break;
            }

            // Explicit multi-byte umlaut aliases are atomic source units.
            let key = input.single_letter_key(start + position);
            let swapped = if key == Some(typed)
                && let Some(&next) = spelling.get(position + 1)
                && next != typed
                && input.single_letter_key(start + position + 1) == Some(next)
            {
                let swapped = prefixes.matching(rows, position, next);
                Some(prefixes.matching(swapped, position + 1, typed))
            } else {
                None
            };

            let mut follow = |edit: Edit, mut rows: &'lookup [Entry<'a>]| {
                let (source_len, reading_len) = edit.lengths();
                let mut consumed = position + source_len;
                let mut depth = position + reading_len;
                while consumed <= last_end && !rows.is_empty() && probes > 0 && terminals > 0 {
                    probes -= 1;
                    let terminal = rows.partition_point(|row| row.spelling.len() == depth);
                    if consumed >= 2 && depth >= 2 && exact_suffixes[start + consumed] {
                        let offsets = if terminal > MAX_ROWS_PER_SPELLING {
                            self.correction_order
                                .as_ref()
                                .and_then(|order| order.get(rows[0].spelling.as_ref()))
                        } else {
                            None
                        };
                        let preferred_len = offsets
                            .map_or(terminal.min(MAX_ROWS_PER_SPELLING), |rows| {
                                rows.preferred.len()
                            });
                        let preferred = (0..preferred_len)
                            .map(|index| offsets.map_or(index, |rows| rows.preferred[index]));
                        let fallback = offsets
                            .into_iter()
                            .flat_map(|rows| rows.other_readings.iter().copied());
                        let separators = input.separators(start, start + consumed);
                        let mut found = false;
                        for (index, offset) in preferred.chain(fallback).enumerate() {
                            if terminals == 0 || (found && index >= preferred_len) {
                                break;
                            }
                            terminals -= 1;
                            let row = &rows[offset];
                            if row.word.text.len() <= MAX_OUTPUT_BYTES
                                && aligned(row.reading, separators.clone(), position, edit)
                            {
                                found = true;
                                let end = start + consumed;
                                let cost = edit.cost();
                                let index = matches.len();
                                let existing =
                                    *seen.entry((end, std::ptr::from_ref(row))).or_insert(index);
                                if existing < index {
                                    if cost < matches[existing].correction_cost {
                                        matches[existing].correction_cost = cost;
                                        matches[existing].correction_kind = Some(edit.kind());
                                    }
                                } else {
                                    matches.push(Match {
                                        end,
                                        word: row.word,
                                        missing: 0,
                                        reading: row.reading,
                                        abbreviated: false,
                                        correction_cost: cost,
                                        correction_kind: Some(edit.kind()),
                                    });
                                }
                            }
                        }
                    }
                    if consumed == last_end {
                        break;
                    }
                    let Some(&byte) = spelling.get(consumed).filter(|&&byte| byte != 0) else {
                        break;
                    };
                    rows = prefixes.matching(&rows[terminal..], depth, byte);
                    consumed += 1;
                    depth += 1;
                }
            };

            if let Some(swapped) = swapped {
                follow(Edit::Swap, swapped);
            }

            let exact = rows.partition_point(|row| row.spelling.len() == position);
            let mut remaining = &rows[exact..];
            let mut exact_branch = &remaining[..0];
            while let Some(first) = remaining.first() {
                let letter = first.spelling[position];
                let length = remaining.partition_point(|row| row.spelling[position] == letter);
                let (branch, tail) = remaining.split_at(length);
                if typed == letter {
                    exact_branch = branch;
                }
                if key.is_some_and(|key| neighboring(key, letter)) && typed != letter {
                    follow(Edit::Replace, branch);
                }
                follow(Edit::Missing, branch);
                remaining = tail;
            }
            rows = exact_branch;
        }
        budget.probes -= probe_limit - probes;
        budget.terminals -= terminal_limit - terminals;
        for edge in matches {
            emit(edge);
        }
    }
}

fn syllable_ends(reading: &str) -> u64 {
    let mut end = 0;
    let mut ends = 0;
    for syllable in reading.split('\'') {
        end += lookup_syllable(syllable).len();
        ends |= 1 << end;
    }
    ends
}

fn aligned(
    reading: &str,
    separators: impl Iterator<Item = usize> + Clone,
    position: usize,
    edit: Edit,
) -> bool {
    let mut separators = separators.peekable();
    let unseparated = separators.peek().is_none();
    // The caller has already matched the whole normalized reading against
    // the edit. With one syllable and no separator, no boundary can be crossed.
    if unseparated && !reading.as_bytes().contains(&b'\'') {
        return true;
    }
    let (source_len, reading_len) = edit.lengths();
    let source_stop = position + source_len;
    let reading_stop = position + reading_len;
    let mut syllable_start = 0;
    let mut edit_fits = false;
    for syllable in reading.split('\'') {
        let syllable_end = syllable_start + lookup_syllable(syllable).len();
        edit_fits |= position >= syllable_start
            && reading_stop <= syllable_end
            && position < syllable_end
            && (syllable_end - syllable_start + source_len > reading_len);
        if unseparated && edit_fits {
            return true;
        }
        if let Some(separator) = separators.peek().copied() {
            let before_edit = separator <= position && separator == syllable_end;
            let after_edit =
                separator >= source_stop && separator + reading_len == syllable_end + source_len;
            if before_edit || after_edit {
                separators.next();
            }
        }
        syllable_start = syllable_end;
    }
    edit_fits && separators.next().is_none()
}

const fn key_positions() -> [(usize, usize); 26] {
    let rows: [&[u8]; 3] = [b"qwertyuiop", b"asdfghjkl", b"zxcvbnm"];
    let mut positions = [(0, 0); 26];
    let mut row = 0;
    while row < rows.len() {
        let mut column = 0;
        while column < rows[row].len() {
            positions[(rows[row][column] - b'a') as usize] = (row, column * 2 + row);
            column += 1;
        }
        row += 1;
    }
    positions
}

fn neighboring(left: u8, right: u8) -> bool {
    if !right.is_ascii_lowercase() {
        return false;
    }
    let (lr, lc) = KEY_POSITIONS[(left - b'a') as usize];
    let (rr, rc) = KEY_POSITIONS[(right - b'a') as usize];
    left != right && lr.abs_diff(rr) <= 1 && lc.abs_diff(rc) <= 2
}

#[cfg(test)]
mod tests {
    use super::syllable_ends;

    #[test]
    fn normalized_aliases_share_one_boundary_pattern() {
        assert_eq!(syllable_ends("lü'se"), syllable_ends("lv'se"));
        assert_eq!(syllable_ends("lu:'se"), syllable_ends("lv'se"));
        assert_eq!(syllable_ends("jv'e"), syllable_ends("ju'e"));
        assert_ne!(syllable_ends("xi'an"), syllable_ends("xian"));
    }
}
