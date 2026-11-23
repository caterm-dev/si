//! Stateless presentation ABI. Input strings are borrowed only for each call;
//! owned output rows contain indices and metadata, never borrowed text.

use std::borrow::Cow;
use std::ptr;

use si_engine::presentation::{self, Order, PresentationCandidate, PresentedCandidate};
use si_engine::{CandidateLanguage, EnabledLanguages};

const PREFERRED: u32 = 1;
const REMEMBERED: u32 = 1 << 1;
const PERSONAL: u32 = 1 << 2;
const PUNCTUATION: u32 = 1 << 3;
const COMPLETION: u32 = 1 << 4;
const VERBATIM: u32 = 1 << 5;
const CORRECTED: u32 = 1 << 6;
const CHINESE_SENTENCE: u32 = 1 << 7;

#[repr(C)]
pub struct SIPresentationCandidate {
    identity: *const u8,
    identity_bytes: usize,
    text: *const u8,
    text_bytes: usize,
    consumed_bytes: usize,
    lexical_tokens: usize,
    lexical_score: f64,
    statistical_score: f64,
    reranking_bonus: f64,
    flags: u32,
    language: u8,
    has_statistical_score: bool,
}

#[repr(C)]
#[derive(Default)]
pub struct SIPresentationRow {
    index: usize,
    lexical_tokens: usize,
    presentation_score: f64,
    remembered: bool,
    chinese_sentence: bool,
}

pub struct SIPresentationResult(Vec<SIPresentationRow>);

#[repr(C)]
pub struct SIPresentationLimits {
    ordinary: usize,
    words: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn si_presentation_limits() -> SIPresentationLimits {
    SIPresentationLimits {
        ordinary: presentation::ORDINARY_LIMIT,
        words: presentation::WORD_LIMIT,
    }
}

unsafe fn text<'a>(pointer: *const u8, len: usize) -> Option<&'a str> {
    if len == 0 {
        return Some("");
    }
    if pointer.is_null() || len > isize::MAX as usize {
        return None;
    }
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(pointer, len) }).ok()
}

unsafe fn rows<'a>(
    pointer: *const SIPresentationCandidate,
    count: usize,
) -> Option<Vec<PresentationCandidate<'a>>> {
    if count == 0 {
        return Some(Vec::new());
    }
    if pointer.is_null() || count > isize::MAX as usize / size_of::<SIPresentationCandidate>() {
        return None;
    }
    let rows = unsafe { std::slice::from_raw_parts(pointer, count) };
    rows.iter()
        .map(|row| {
            if !row.lexical_score.is_finite()
                || !row.reranking_bonus.is_finite()
                || (row.has_statistical_score && !row.statistical_score.is_finite())
            {
                return None;
            }
            let identity = unsafe { text(row.identity, row.identity_bytes) }?;
            let text = unsafe { text(row.text, row.text_bytes) }?;
            let language = match row.language {
                0 => CandidateLanguage::Literal,
                1 => CandidateLanguage::Chinese,
                2 => CandidateLanguage::English,
                3 => CandidateLanguage::Mixed,
                _ => return None,
            };
            Some(PresentationCandidate {
                identity: Cow::Borrowed(identity),
                text,
                language,
                consumed_bytes: (row.consumed_bytes != usize::MAX).then_some(row.consumed_bytes),
                lexical_tokens: row.lexical_tokens,
                lexical_score: row.lexical_score,
                statistical_score: row.has_statistical_score.then_some(row.statistical_score),
                reranking_bonus: row.reranking_bonus,
                preferred: row.flags & PREFERRED != 0,
                remembered: row.flags & REMEMBERED != 0,
                personal: row.flags & PERSONAL != 0,
                punctuation: row.flags & PUNCTUATION != 0,
                completion: row.flags & COMPLETION != 0,
                verbatim: row.flags & VERBATIM != 0,
                corrected: row.flags & CORRECTED != 0,
                chinese_sentence: row.flags & CHINESE_SENTENCE != 0,
            })
        })
        .collect()
}

impl From<PresentedCandidate> for SIPresentationRow {
    fn from(row: PresentedCandidate) -> Self {
        Self {
            index: row.index,
            lexical_tokens: row.lexical_tokens,
            presentation_score: row.presentation_score,
            remembered: row.remembered,
            chinese_sentence: row.chinese_sentence,
        }
    }
}

/// # Safety
/// Nonempty input and row buffers must be live for this call. No input is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_presentation_merge(
    input: *const u8,
    input_bytes: usize,
    languages: u8,
    coverage_order: bool,
    candidates: *const SIPresentationCandidate,
    count: usize,
) -> *mut SIPresentationResult {
    let (Some(input), Some(rows)) =
        (unsafe { (text(input, input_bytes), rows(candidates, count)) })
    else {
        return ptr::null_mut();
    };
    let order = if coverage_order {
        Order::CoverageAdjusted
    } else {
        Order::Statistical
    };
    let selected = presentation::merge(
        input,
        EnabledLanguages {
            chinese: languages & 1 != 0,
            english: languages & 2 != 0,
        },
        &rows,
        order,
    );
    Box::into_raw(Box::new(SIPresentationResult(
        selected.into_iter().map(Into::into).collect(),
    )))
}

/// # Safety
/// Row buffers must be live for this call. Returned indices refer to input rows.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_presentation_shortlist(
    candidates: *const SIPresentationCandidate,
    count: usize,
) -> *mut SIPresentationResult {
    let Some(rows) = (unsafe { rows(candidates, count) }) else {
        return ptr::null_mut();
    };
    let selected = presentation::shortlist(&rows)
        .into_iter()
        .map(|index| SIPresentationRow {
            index,
            ..Default::default()
        })
        .collect();
    Box::into_raw(Box::new(SIPresentationResult(selected)))
}

/// # Safety
/// Row buffers must be live. SIZE_MAX means the pool is empty or invalid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_presentation_statistical_leader(
    candidates: *const SIPresentationCandidate,
    count: usize,
) -> usize {
    unsafe { rows(candidates, count) }
        .and_then(|rows| presentation::statistical_leader(&rows))
        .unwrap_or(usize::MAX)
}

/// # Safety
/// A nonempty spelling must point to live UTF-8 bytes. Invalid UTF-8 earns no reward.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_presentation_coverage_bonus(
    spelling: *const u8,
    spelling_bytes: usize,
    literal: bool,
    verbatim: bool,
) -> f64 {
    unsafe { text(spelling, spelling_bytes) }.map_or(0.0, |spelling| {
        presentation::coverage_bonus(spelling, literal, verbatim)
    })
}

/// # Safety
/// The handle must be null or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_presentation_count(result: *const SIPresentationResult) -> usize {
    unsafe { result.as_ref() }.map_or(0, |result| result.0.len())
}

/// # Safety
/// The handle must be live and the output writable. Output contains no borrows.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_presentation_get(
    result: *const SIPresentationResult,
    index: usize,
    out: *mut SIPresentationRow,
) -> bool {
    let (Some(row), Some(out)) =
        (unsafe { (result.as_ref().and_then(|r| r.0.get(index)), out.as_mut()) })
    else {
        return false;
    };
    *out = SIPresentationRow { ..*row };
    true
}

/// # Safety
/// The handle must be null or uniquely owned, from a presentation call above.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_presentation_free(result: *mut SIPresentationResult) {
    if !result.is_null() {
        unsafe {
            drop(Box::from_raw(result));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(identity: &str, text: &str, language: u8) -> SIPresentationCandidate {
        SIPresentationCandidate {
            identity: identity.as_ptr(),
            identity_bytes: identity.len(),
            text: text.as_ptr(),
            text_bytes: text.len(),
            consumed_bytes: usize::MAX,
            lexical_tokens: 1,
            lexical_score: -10.0,
            statistical_score: -10.0,
            reranking_bonus: 0.0,
            flags: 0,
            language,
            has_statistical_score: true,
        }
    }

    #[test]
    fn explicit_lengths_preserve_embedded_nul_and_output_indices() {
        let input = "source\0É";
        let rows = [
            candidate("en:word", "word", 2),
            candidate("literal:source\0É", input, 0),
        ];
        // SAFETY: all descriptors and backing string literals live through each call.
        unsafe {
            let result = si_presentation_merge(
                input.as_ptr(),
                input.len(),
                3,
                false,
                rows.as_ptr(),
                rows.len(),
            );
            assert!(!result.is_null());
            assert_eq!(si_presentation_count(result), 2);
            let mut row = SIPresentationRow::default();
            assert!(si_presentation_get(result, 1, &mut row));
            assert_eq!(row.index, 1);
            assert!(!si_presentation_get(result, 2, &mut row));
            assert!(!si_presentation_get(result, 0, ptr::null_mut()));
            si_presentation_free(result);
            assert_eq!(
                si_presentation_statistical_leader(ptr::null(), 0),
                usize::MAX
            );
            let empty = si_presentation_shortlist(ptr::null(), 0);
            assert!(!empty.is_null());
            assert_eq!(si_presentation_count(empty), 0);
            si_presentation_free(empty);
            si_presentation_free(ptr::null_mut());
        }
    }

    #[test]
    fn invalid_utf8_buffers_scores_and_languages_fail_without_partial_results() {
        let input = b"source";
        let mut row = candidate("en:word", "word", 2);
        // SAFETY: supplied pointers either identify live buffers or are intentionally
        // null, which the API validates before dereferencing.
        unsafe {
            assert!(
                si_presentation_merge(input.as_ptr(), input.len(), 3, false, ptr::null(), 1)
                    .is_null()
            );
            row.language = 255;
            assert!(si_presentation_shortlist(&row, 1).is_null());
            row.language = 2;
            row.lexical_score = f64::NAN;
            assert!(si_presentation_shortlist(&row, 1).is_null());
            row.lexical_score = 0.0;
            let invalid = [0xff];
            row.text = invalid.as_ptr();
            row.text_bytes = 1;
            assert!(si_presentation_shortlist(&row, 1).is_null());
            assert_eq!(
                si_presentation_coverage_bonus(invalid.as_ptr(), invalid.len(), false, false),
                0.0
            );
        }
    }
}
