#ifndef SI_RUST_H
#define SI_RUST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SIEngine SIEngine;
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
} SICandidateView;

/* UTF-8 paths. Grams is optional. NULL indicates resources could not be loaded. */
SIEngine *si_engine_open(const char *lexicon, const char *grams);
void si_engine_close(SIEngine *engine);
/* Profile I/O and index construction. Call away from the event handler.
   On success, close any non-NULL returned engine with si_engine_close. */
bool si_engine_load_user(const SIEngine *engine, const char *profile, SIEngine **out);
/* UTF-8 text with newlines separating observations. */
bool si_engine_ingest_user(const SIEngine *engine, const char *profile, const char *batch_id,
                           const uint8_t *text, size_t length);
bool si_engine_clear_user(const char *profile);

/* Language bits are 1 for Chinese and 2 for English. Offsets count UTF-8 bytes. */
SICandidates *si_engine_candidates(const SIEngine *engine, const uint8_t *text,
                                   size_t length, const uint8_t *preceding_text,
                                   size_t preceding_length, uint8_t languages, bool preview,
                                   const SIUserPhrase *phrases, size_t phrase_count,
                                   const SILearnedToken *tokens, size_t token_count,
                                   const SILearnedPath *paths, size_t path_count);
bool si_engine_has_english_word_prefix(const SIEngine *engine, const uint8_t *text,
                                       size_t length, size_t minimum);
size_t si_candidates_count(const SICandidates *results);
/* Borrowed candidate text is valid until si_candidates_free. */
bool si_candidates_get(const SICandidates *results, size_t index, SICandidateView *view);
void si_candidates_free(SICandidates *results);

#endif
