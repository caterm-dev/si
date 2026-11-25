import CSIRust

/// Client-owned transient Rust preparation. The C ABI synchronizes cache access;
/// immutable requests may share it without sharing any composition state.
public final class PrecedingTextCache: @unchecked Sendable {
    let handle = si_preceding_text_cache_new()

    public init() {}

    deinit { si_preceding_text_cache_free(handle) }
}
