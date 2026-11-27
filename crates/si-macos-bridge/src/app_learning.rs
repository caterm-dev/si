use std::ffi::{CStr, c_char};
use std::path::PathBuf;
use std::sync::Arc;

use crate::SIEngine;
use si_engine::resources::{AppLearningConfig, EngineResources, user::app::AppLearningSession};

#[unsafe(no_mangle)]
pub extern "C" fn si_app_learning_snapshot_byte_limit() -> usize {
    AppLearningConfig::default().max_snapshot_bytes()
}

pub struct SIAppLearning {
    base: Arc<EngineResources>,
    session: AppLearningSession,
}

/// # Safety
/// Engine must be live; directory and bundle must be valid UTF-8 C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_app_learning_open(
    engine: *const SIEngine,
    directory: *const c_char,
    bundle: *const c_char,
) -> *mut SIAppLearning {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return std::ptr::null_mut();
    };
    if directory.is_null() || bundle.is_null() {
        return std::ptr::null_mut();
    }
    let (Ok(directory), Ok(bundle)) = (unsafe {
        (
            CStr::from_ptr(directory).to_str(),
            CStr::from_ptr(bundle).to_str(),
        )
    }) else {
        return std::ptr::null_mut();
    };
    let Ok(session) = AppLearningSession::open(PathBuf::from(directory), bundle.to_owned()) else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(SIAppLearning {
        base: engine.base().clone(),
        session,
    }))
}

/// # Safety
/// Handle must be null or uniquely owned with no outstanding calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_app_learning_close(handle: *mut SIAppLearning) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// # Safety
/// Handle must be exclusive. Text/ends are readable buffers, or null for an empty snapshot.
/// Offsets are UTF-8 bytes. Returns -1 on error, 0 when unchanged, 1 when published.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_app_learning_observe(
    handle: *mut SIAppLearning,
    text: *const u8,
    len: usize,
    ends: *const usize,
    count: usize,
) -> i32 {
    let Some(handle) = (unsafe { handle.as_mut() }) else {
        return -1;
    };
    if len > handle.session.max_snapshot_bytes() {
        return 0;
    }
    if count == 0 {
        return if len == 0 {
            handle
                .session
                .observe(handle.base.lexicon(), &[])
                .map(i32::from)
                .unwrap_or(-1)
        } else {
            -1
        };
    }
    // Every nonempty paragraph consumes at least one byte; this is buffer validation, not a count quota.
    if text.is_null() || ends.is_null() || count > len {
        return -1;
    }
    let Ok(text) = (unsafe { std::str::from_utf8(std::slice::from_raw_parts(text, len)) }) else {
        return -1;
    };
    let mut start = 0;
    let mut paragraphs = Vec::with_capacity(count);
    for &end in unsafe { std::slice::from_raw_parts(ends, count) } {
        let Some(paragraph) = text.get(start..end).filter(|s| !s.is_empty()) else {
            return -1;
        };
        paragraphs.push(paragraph);
        start = end;
    }
    if start != len {
        return -1;
    }
    match handle.session.observe(handle.base.lexicon(), &paragraphs) {
        Ok(changed) => i32::from(changed),
        Err(_) => -1,
    }
}
