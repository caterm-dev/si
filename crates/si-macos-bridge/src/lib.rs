//! C ABI for the macOS Swift client. The engine and its backing data are immutable.

use std::ffi::{CStr, c_char};
use std::path::Path;
use std::ptr::{self, NonNull};

use si_engine::resources::EngineResources;
use si_engine::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionBoundary, EnabledLanguages,
    PersonalPhrase, TokenPreference,
};

struct OwnedResources(NonNull<EngineResources>);

impl Drop for OwnedResources {
    fn drop(&mut self) {
        // SAFETY: the owner was allocated with Box::into_raw and is unique.
        unsafe { drop(Box::from_raw(self.0.as_ptr())) };
    }
}

pub struct SIEngine {
    decoder: CandidateEngine<'static>,
    // Rust drops fields in declaration order, so the borrows end before freeing the allocation.
    _resources: OwnedResources,
}

pub struct SICandidates(Vec<Candidate>);

#[repr(C)]
pub struct SIUserPhrase {
    spelling: *const u8,
    spelling_bytes: usize,
    text: *const u8,
    text_bytes: usize,
    language: u8,
    pinned: bool,
}

#[repr(C)]
pub struct SILearnedToken {
    spelling: *const u8,
    spelling_bytes: usize,
    text: *const u8,
    text_bytes: usize,
    language: u8,
    bonus: f64,
}

#[repr(C)]
pub struct SICandidateView {
    text: *const u8,
    text_bytes: usize,
    consumed_bytes: usize,
    lexical_tokens: usize,
    score_bits: f64,
    language: u8,
    completion: bool,
    source_boundaries: *const usize,
    source_boundary_count: usize,
    confirmation_boundaries: *const ConversionBoundary,
    confirmation_boundary_count: usize,
    personal: bool,
    preferred: bool,
    verbatim: bool,
    token_bonus: f64,
}

/// # Safety
/// The lexicon path must be a valid NUL-terminated UTF-8 string. Grams may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_open(
    lexicon: *const c_char,
    grams: *const c_char,
) -> *mut SIEngine {
    if lexicon.is_null() {
        return ptr::null_mut();
    }
    let Ok(lexicon) = (unsafe { CStr::from_ptr(lexicon) }).to_str() else {
        return ptr::null_mut();
    };
    let grams = if grams.is_null() {
        None
    } else {
        let Ok(grams) = (unsafe { CStr::from_ptr(grams) }).to_str() else {
            return ptr::null_mut();
        };
        Some(Path::new(grams))
    };
    let Ok(resources) = EngineResources::open(Path::new(lexicon), grams) else {
        return ptr::null_mut();
    };
    let resources = OwnedResources(NonNull::from(Box::leak(Box::new(resources))));
    // SAFETY: the allocation is stable and the owner is kept until after the decoder drops.
    let decoder = CandidateEngine::new(unsafe { resources.0.as_ref() }, None);
    Box::into_raw(Box::new(SIEngine {
        decoder,
        _resources: resources,
    }))
}

/// # Safety
/// The handle must be null or returned by si_engine_open, with no outstanding calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_close(engine: *mut SIEngine) {
    if !engine.is_null() {
        unsafe { drop(Box::from_raw(engine)) };
    }
}

/// # Safety
/// The handle must be live. Each nonempty byte slice and the phrase array must
/// point to initialized memory for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_candidates(
    engine: *const SIEngine,
    text: *const u8,
    len: usize,
    languages: u8,
    preview: bool,
    phrases: *const SIUserPhrase,
    phrase_count: usize,
    preferences: *const SILearnedToken,
    preference_count: usize,
) -> *mut SICandidates {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return ptr::null_mut();
    };
    let bytes = if len == 0 {
        &[]
    } else if text.is_null() {
        return ptr::null_mut();
    } else {
        unsafe { std::slice::from_raw_parts(text, len) }
    };
    let Ok(text) = std::str::from_utf8(bytes) else {
        return ptr::null_mut();
    };
    let languages = EnabledLanguages {
        chinese: languages & 1 != 0,
        english: languages & 2 != 0,
    };
    let phrases = if phrase_count == 0 {
        &[]
    } else if phrases.is_null() || phrase_count > 1_000 {
        return ptr::null_mut();
    } else {
        unsafe { std::slice::from_raw_parts(phrases, phrase_count) }
    };
    let phrases: Vec<_> = phrases
        .iter()
        .filter_map(|row| {
            if row.spelling.is_null()
                || row.text.is_null()
                || row.spelling_bytes > 64
                || row.text_bytes > 1_024
            {
                return None;
            }
            let spelling = std::str::from_utf8(unsafe {
                std::slice::from_raw_parts(row.spelling, row.spelling_bytes)
            })
            .ok()?;
            let text = std::str::from_utf8(unsafe {
                std::slice::from_raw_parts(row.text, row.text_bytes)
            })
            .ok()?;
            let language = match row.language {
                1 => CandidateLanguage::Chinese,
                2 => CandidateLanguage::English,
                _ => return None,
            };
            Some(PersonalPhrase {
                spelling,
                text,
                language,
                pinned: row.pinned,
            })
        })
        .collect();
    let preferences = if preference_count == 0 {
        &[]
    } else if preferences.is_null() || preference_count > 5_000 {
        return ptr::null_mut();
    } else {
        unsafe { std::slice::from_raw_parts(preferences, preference_count) }
    };
    let preferences: Vec<_> = preferences
        .iter()
        .filter_map(|row| {
            if row.spelling.is_null()
                || row.text.is_null()
                || row.spelling_bytes > 128
                || row.text_bytes > 512
            {
                return None;
            }
            let spelling = std::str::from_utf8(unsafe {
                std::slice::from_raw_parts(row.spelling, row.spelling_bytes)
            })
            .ok()?;
            let text = std::str::from_utf8(unsafe {
                std::slice::from_raw_parts(row.text, row.text_bytes)
            })
            .ok()?;
            let language = match row.language {
                1 => CandidateLanguage::Chinese,
                2 => CandidateLanguage::English,
                _ => return None,
            };
            Some(TokenPreference {
                spelling,
                text,
                language,
                bonus: row.bonus,
            })
        })
        .collect();
    let rows = engine
        .decoder
        .convert(text, languages, preview, &phrases, &preferences);
    Box::into_raw(Box::new(SICandidates(rows)))
}

/// # Safety
/// The handle must be live. For nonzero length, text must point to that many initialized bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_has_english_word_prefix(
    engine: *const SIEngine,
    text: *const u8,
    len: usize,
    minimum: usize,
) -> bool {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return false;
    };
    if text.is_null() || len == 0 {
        return false;
    }
    let text = unsafe { std::slice::from_raw_parts(text, len) };
    std::str::from_utf8(text)
        .is_ok_and(|text| engine.decoder.has_english_word_prefix(text, minimum))
}

/// # Safety
/// A non-null handle must identify live results.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_candidates_count(results: *const SICandidates) -> usize {
    unsafe { results.as_ref() }.map_or(0, |results| results.0.len())
}

/// # Safety
/// A non-null handle must identify live results. View must be writable.
/// The text pointer in the view is borrowed until the results are freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_candidates_get(
    results: *const SICandidates,
    index: usize,
    view: *mut SICandidateView,
) -> bool {
    let Some(candidate) = unsafe { results.as_ref() }.and_then(|results| results.0.get(index))
    else {
        return false;
    };
    if view.is_null() {
        return false;
    }
    let language = match candidate.language {
        CandidateLanguage::Literal => 0,
        CandidateLanguage::Chinese => 1,
        CandidateLanguage::English => 2,
        CandidateLanguage::Mixed => 3,
    };
    unsafe {
        view.write(SICandidateView {
            text: candidate.text.as_ptr(),
            text_bytes: candidate.text.len(),
            consumed_bytes: candidate.consumed_bytes,
            lexical_tokens: candidate.lexical_tokens,
            score_bits: candidate.score_bits.unwrap_or(0.0),
            language,
            completion: candidate.completion,
            source_boundaries: candidate.source_boundaries.as_ptr(),
            source_boundary_count: candidate.source_boundaries.len(),
            confirmation_boundaries: candidate.confirmation_boundaries.as_ptr(),
            confirmation_boundary_count: candidate.confirmation_boundaries.len(),
            personal: candidate.personal,
            preferred: candidate.preferred,
            verbatim: candidate.verbatim,
            token_bonus: candidate.token_bonus,
        });
    }
    true
}

/// # Safety
/// The handle must be null or returned by si_engine_candidates, with no outstanding borrows.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_candidates_free(results: *mut SICandidates) {
    if !results.is_null() {
        unsafe { drop(Box::from_raw(results)) };
    }
}
