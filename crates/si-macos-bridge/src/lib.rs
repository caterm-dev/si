//! C ABI for the macOS Swift client. Candidate engines and their backing data are immutable.

use std::ffi::{CStr, c_char};
use std::path::Path;
use std::ptr::{self, NonNull};
use std::sync::Arc;

use si_engine::resources::EngineResources;
use si_engine::resources::user::{UserLearningConfig, UserModelStore};
use si_engine::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionBoundary, ConversionPreferences,
    EnabledLanguages, PathPreference, PersonalPhrase, TokenPreference,
};

struct OwnedResources(NonNull<(Arc<EngineResources>, Option<EngineResources>)>);

impl Drop for OwnedResources {
    fn drop(&mut self) {
        // SAFETY: this uniquely owns the stable allocation created by SIEngine::new.
        unsafe { drop(Box::from_raw(self.0.as_ptr())) };
    }
}

pub struct SIEngine {
    decoder: CandidateEngine<'static>,
    // Field drop order keeps the resources alive until after the decoder drops.
    resources: OwnedResources,
}

impl SIEngine {
    fn new(base: Arc<EngineResources>, user: Option<EngineResources>) -> Self {
        let resources = OwnedResources(NonNull::from(Box::leak(Box::new((base, user)))));
        // SAFETY: the allocation outlives the decoder and its data is immutable.
        let (base, user) = unsafe { resources.0.as_ref() };
        Self {
            decoder: CandidateEngine::new(base, user.as_ref()),
            resources,
        }
    }

    fn base(&self) -> &Arc<EngineResources> {
        // SAFETY: the resource allocation stays live for the engine's lifetime.
        &unsafe { self.resources.0.as_ref() }.0
    }
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
pub struct SILearnedPath {
    consumed_bytes: usize,
    text: *const u8,
    text_bytes: usize,
    language: u8,
    frequency: f64,
    contextual: f64,
}

#[repr(C)]
pub struct SICandidateView {
    text: *const u8,
    text_bytes: usize,
    consumed_bytes: usize,
    lexical_tokens: usize,
    score_bits: f64,
    context_adjustment: f64,
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
    Box::into_raw(Box::new(SIEngine::new(Arc::new(resources), None)))
}

unsafe fn user_store(profile: *const c_char) -> Option<UserModelStore> {
    if profile.is_null() {
        return None;
    }
    let path = unsafe { CStr::from_ptr(profile) }.to_str().ok()?;
    Some(UserModelStore::new(path))
}

#[repr(C)]
pub struct SIUserEntryView {
    text: *const u8,
    text_bytes: usize,
    reading: *const u8,
    reading_bytes: usize,
    index: u32,
    count: u64,
}

/// # Safety
/// Engine must be live and view writable. Returned byte slices borrow the engine.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_user_entry(
    engine: *const SIEngine,
    offset: usize,
    view: *mut SIUserEntryView,
) -> bool {
    let (Some(engine), Some(view)) = (unsafe { (engine.as_ref(), view.as_mut()) }) else {
        return false;
    };
    let resources = unsafe { engine.resources.0.as_ref() };
    let Some(word) = resources
        .1
        .as_ref()
        .and_then(|r| r.lexicon().words().nth(offset))
    else {
        return false;
    };
    *view = SIUserEntryView {
        text: word.text.as_ptr(),
        text_bytes: word.text.len(),
        reading: word.reading.map_or(ptr::null(), |r| r.key.as_ptr()),
        reading_bytes: word.reading.map_or(0, |r| r.key.len()),
        index: word.reading.map_or(u32::MAX, |r| r.index.0),
        count: word.count,
    };
    true
}

unsafe fn owned_entry(view: &SIUserEntryView) -> Option<si_engine::resources::user::UserEntry> {
    if view.text.is_null()
        || view.text_bytes == 0
        || view.text_bytes > 4096
        || view.reading_bytes > 256
    {
        return None;
    }
    let text =
        std::str::from_utf8(unsafe { std::slice::from_raw_parts(view.text, view.text_bytes) })
            .ok()?
            .to_owned();
    let reading = if view.index == u32::MAX {
        None
    } else {
        if view.reading.is_null() || view.reading_bytes == 0 {
            return None;
        }
        Some((
            view.index,
            unsafe { std::slice::from_raw_parts(view.reading, view.reading_bytes) }.to_vec(),
        ))
    };
    Some(si_engine::resources::user::UserEntry {
        text,
        reading,
        count: view.count,
    })
}

/// # Safety
/// Profile is a UTF-8 C string; optional entry pointers and their byte slices must be live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_edit_user_entry(
    profile: *const c_char,
    old: *const SIUserEntryView,
    new: *const SIUserEntryView,
) -> bool {
    let Some(store) = (unsafe { user_store(profile) }) else {
        return false;
    };
    let old = match unsafe { old.as_ref() } {
        Some(v) => match unsafe { owned_entry(v) } {
            Some(v) => Some(v),
            None => return false,
        },
        None => None,
    };
    let new = match unsafe { new.as_ref() } {
        Some(v) => match unsafe { owned_entry(v) } {
            Some(v) => Some(v),
            None => return false,
        },
        None => None,
    };
    store.edit_entry(old.as_ref(), new.as_ref()).is_ok()
}

/// # Safety
/// The engine must be live, profile must be a UTF-8 C string, and out must be writable.
/// On success, a non-null output is owned by the caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_load_user(
    engine: *const SIEngine,
    profile: *const c_char,
    out: *mut *mut SIEngine,
) -> bool {
    let (Some(engine), Some(store), Some(out)) =
        (unsafe { (engine.as_ref(), user_store(profile), out.as_mut()) })
    else {
        return false;
    };
    let Ok(user) = store.load() else {
        return false;
    };
    *out = user.map_or(ptr::null_mut(), |user| {
        Box::into_raw(Box::new(SIEngine::new(
            Arc::clone(engine.base()),
            Some(user),
        )))
    });
    true
}

/// # Safety
/// The engine must be live. Profile and batch ID must be UTF-8 C strings.
/// Text must point to len initialized UTF-8 bytes and ends to count initialized byte offsets.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_ingest_user(
    engine: *const SIEngine,
    profile: *const c_char,
    batch_id: *const c_char,
    text: *const u8,
    len: usize,
    ends: *const usize,
    count: usize,
) -> bool {
    let (Some(engine), Some(store)) = (unsafe { (engine.as_ref(), user_store(profile)) }) else {
        return false;
    };
    if batch_id.is_null()
        || text.is_null()
        || len == 0
        || ends.is_null()
        || !(1..=32).contains(&count)
        || len > count * 4096
    {
        return false;
    }
    let Ok(batch_id) = (unsafe { CStr::from_ptr(batch_id) }).to_str() else {
        return false;
    };
    let Ok(text) = std::str::from_utf8(unsafe { std::slice::from_raw_parts(text, len) }) else {
        return false;
    };
    let ends = unsafe { std::slice::from_raw_parts(ends, count) };
    let mut start = 0;
    let mut submissions = Vec::with_capacity(count);
    for &end in ends {
        let Some(submission) = text
            .get(start..end)
            .filter(|text| (1..=4096).contains(&text.len()))
        else {
            return false;
        };
        submissions.push(submission);
        start = end;
    }
    if start != len {
        return false;
    }
    let lexicon = engine.base().lexicon();
    store
        .ingest(
            lexicon,
            batch_id,
            submissions.into_iter().flat_map(str::lines).map(Ok),
        )
        .is_ok()
        && store.learn(lexicon, &UserLearningConfig::default()).is_ok()
}

/// # Safety
/// Profile must be a valid UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_clear_user(profile: *const c_char) -> bool {
    unsafe { user_store(profile) }.is_some_and(|store| store.clear().is_ok())
}

/// # Safety
/// The handle must be null or returned by si_engine_open or si_engine_load_user, with no outstanding calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_close(engine: *mut SIEngine) {
    if !engine.is_null() {
        unsafe { drop(Box::from_raw(engine)) };
    }
}

/// # Safety
/// The handle must be live. Each nonempty byte slice and array must
/// point to initialized memory for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_engine_candidates(
    engine: *const SIEngine,
    text: *const u8,
    len: usize,
    preceding_text: *const u8,
    preceding_len: usize,
    languages: u8,
    preview: bool,
    phrases: *const SIUserPhrase,
    phrase_count: usize,
    tokens: *const SILearnedToken,
    token_count: usize,
    paths: *const SILearnedPath,
    path_count: usize,
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
    let preceding_text = if preceding_len == 0 || preceding_text.is_null() {
        ""
    } else {
        std::str::from_utf8(unsafe { std::slice::from_raw_parts(preceding_text, preceding_len) })
            .unwrap_or_default()
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
    let tokens = if token_count == 0 {
        &[]
    } else if tokens.is_null() || token_count > 5_000 {
        return ptr::null_mut();
    } else {
        unsafe { std::slice::from_raw_parts(tokens, token_count) }
    };
    let tokens: Vec<_> = tokens
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
    let paths = if path_count == 0 {
        &[]
    } else if paths.is_null() || path_count > 5_000 {
        return ptr::null_mut();
    } else {
        unsafe { std::slice::from_raw_parts(paths, path_count) }
    };
    let paths: Vec<_> = paths
        .iter()
        .filter_map(|row| {
            if row.text.is_null() || row.text_bytes > 512 {
                return None;
            }
            let text = std::str::from_utf8(unsafe {
                std::slice::from_raw_parts(row.text, row.text_bytes)
            })
            .ok()?;
            let language = match row.language {
                1 => CandidateLanguage::Chinese,
                2 => CandidateLanguage::English,
                3 => CandidateLanguage::Mixed,
                _ => return None,
            };
            Some(PathPreference {
                consumed_bytes: row.consumed_bytes,
                text,
                language,
                frequency: row.frequency,
                contextual: row.contextual,
            })
        })
        .collect();
    let rows = engine.decoder.convert_with_context(
        text,
        languages,
        preview,
        &phrases,
        ConversionPreferences {
            tokens: &tokens,
            paths: &paths,
        },
        preceding_text,
    );
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
            context_adjustment: candidate.context_adjustment,
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
