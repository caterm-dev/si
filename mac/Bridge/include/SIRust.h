#ifndef SI_RUST_H
#define SI_RUST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SIEngine SIEngine;
typedef struct SIRanking SIRanking;
typedef struct SICandidates SICandidates;

typedef struct SIUserPhrase {
    const uint8_t *spelling;
    size_t spelling_bytes;
    const uint8_t *text;
    size_t text_bytes;
    uint8_t language;
    bool pinned;
} SIUserPhrase;

typedef struct SILearnedToken {
    const uint8_t *spelling;
    size_t spelling_bytes;
    const uint8_t *text;
    size_t text_bytes;
    uint8_t language;
    double bonus;
} SILearnedToken;

typedef struct SILearnedPath {
    size_t consumed_bytes;
    const uint8_t *text;
    size_t text_bytes;
    uint8_t language;
    double frequency;
    double contextual;
} SILearnedPath;

typedef struct SIConversionBoundary {
    size_t source_bytes;
    size_t output_bytes;
} SIConversionBoundary;

typedef struct SICandidateView {
    const uint8_t *text;
    size_t text_bytes;
    size_t consumed_bytes;
    size_t lexical_tokens;
    double score_bits;
    double context_adjustment;
    uint8_t language;
    bool completion;
    const size_t *source_boundaries;
    size_t source_boundary_count;
    const SIConversionBoundary *confirmation_boundaries;
    size_t confirmation_boundary_count;
    bool personal;
    bool preferred;
    bool verbatim;
    double token_bonus;
    double model_score; /* NaN if the candidate was not scored. */
    bool neural_only;
} SICandidateView;

/* UTF-8 paths. Grams is optional. NULL indicates resources could not be loaded. */
SIEngine *si_engine_open(const char *lexicon, const char *grams);
void si_engine_close(SIEngine *engine);
/* Profile I/O and index construction. Call away from the event handler.
   On success, release any non-NULL outputs with the matching close/free functions. */
typedef struct SIUserEntryView {
    const uint8_t *text;
    size_t text_bytes;
    const uint8_t *reading;
    size_t reading_bytes;
    uint32_t index; /* UINT32_MAX means no reading. */
    uint64_t count;
} SIUserEntryView;
/* Returned slices borrow engine. Edits compare the exact old entry under the profile lock. */
bool si_engine_user_entry(const SIEngine *engine, size_t offset, SIUserEntryView *view);
bool si_engine_edit_user_entry(const char *profile, const SIUserEntryView *old_entry,
                               const SIUserEntryView *new_entry);
bool si_engine_load_user(const SIEngine *engine, const char *profile, SIEngine **out);
/* Concatenated UTF-8 submissions with their exclusive end offsets in bytes. */
bool si_engine_ingest_user(const SIEngine *engine, const char *profile, const char *batch_id,
                           const uint8_t *text, size_t length, const size_t *ends, size_t count);
bool si_engine_clear_user(const char *profile);

/* Configure off (0), conservative (1), or higher recall (2).
   Call with exclusive access away from the event handler. Suggestions require
   explicit selection. Existing engines default to off. */
bool si_engine_set_correction(SIEngine *engine, uint8_t mode);

typedef struct SICorrectionView {
    uint8_t kind; /* 2 missing, 3 neighboring, 4 adjacent swap */
    size_t word_start_bytes;
    size_t word_end_bytes;
} SICorrectionView;
/* Returns false for ordinary candidates and leaves the view untouched. */
bool si_candidates_get_correction(const SICandidates *results, size_t index, SICorrectionView *view);

/* Language bits are 1 for Chinese and 2 for English. Offsets count UTF-8 bytes. */
SICandidates *si_engine_candidates(const SIEngine *engine, const uint8_t *text,
                                   size_t length, const uint8_t *preceding_text,
                                   size_t preceding_length, uint8_t languages, bool preview,
                                   const SIUserPhrase *phrases, size_t phrase_count,
                                   const SILearnedToken *tokens, size_t token_count,
                                   const SILearnedPath *paths, size_t path_count);
/* Per-query mode, using the same values as si_engine_set_correction. */
SICandidates *si_engine_candidates_for_mode(const SIEngine *engine, const uint8_t *text,
                                   size_t length, const uint8_t *preceding_text,
                                   size_t preceding_length, uint8_t languages, bool preview,
                                   const SIUserPhrase *phrases, size_t phrase_count,
                                   const SILearnedToken *tokens, size_t token_count,
                                   const SILearnedPath *paths, size_t path_count, uint8_t mode);
/* Immutable local model bundle. Call open off the event path. */
SIRanking *si_ranking_open(const char *directory, bool use_pinyin_model);
void si_ranking_close(SIRanking *ranking);
SICandidates *si_engine_ranked_candidates_for_mode(const SIEngine *engine, const SIRanking *ranking,
                                   const uint8_t *text, size_t length, const uint8_t *preceding_text,
                                   size_t preceding_length, uint8_t languages, bool preview,
                                   const SIUserPhrase *phrases, size_t phrase_count,
                                   const SILearnedToken *tokens, size_t token_count,
                                   const SILearnedPath *paths, size_t path_count, uint8_t mode);
bool si_engine_has_english_word_prefix(const SIEngine *engine, const uint8_t *text,
                                       size_t length, size_t minimum);
size_t si_candidates_count(const SICandidates *results);
/* Borrowed candidate text is valid until si_candidates_free. */
bool si_candidates_get(const SICandidates *results, size_t index, SICandidateView *view);
void si_candidates_free(SICandidates *results);

#endif
