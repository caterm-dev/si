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

/* Language bits are 1 for Chinese and 2 for English. Offsets count UTF-8 bytes. */
SICandidates *si_engine_candidates(const SIEngine *engine, const uint8_t *text,
                                   size_t length, uint8_t languages, bool preview,
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
