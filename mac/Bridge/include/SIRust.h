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
    double reranking_bonus;
} SICandidateView;

/* UTF-8 paths. Grams is optional. NULL indicates resources could not be loaded. */
SIEngine *si_engine_open(const char *lexicon, const char *grams);
/* Optional local model. Call with exclusive access before publishing the engine. */
bool si_engine_load_reranker(SIEngine *engine, const char *directory);
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
/* Up to 32 nonempty UTF-8 submissions totaling at most 128 KiB, with exclusive byte end offsets. */
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

/* Language bits are 1 for Chinese and 2 for English. Offsets count UTF-8 bytes.
   A null preceding_text means unavailable. A nonnull zero-length prefix confirms field start. */
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
                                   const SILearnedPath *paths, size_t path_count, uint8_t mode,
                                   bool rerank);
bool si_engine_has_english_word_prefix(const SIEngine *engine, const uint8_t *text,
                                       size_t length, size_t minimum);
size_t si_candidates_count(const SICandidates *results);
/* Borrowed candidate text is valid until si_candidates_free. */
bool si_candidates_get(const SICandidates *results, size_t index, SICandidateView *view);
void si_candidates_free(SICandidates *results);

/* Stateless platform-independent presentation policy; no engine handle needed.
   All strings are borrowed UTF-8 with explicit byte lengths (embedded NUL allowed).
   Identity includes language, punctuation identity and consumed span. Comparison
   keys use canonical Unicode equivalence; committed text remains byte-exact.
   consumed_bytes is SIZE_MAX for whole input, otherwise an exact UTF-8 source
   boundary in merge. Shortlist/leader need only consistently ordered source spans.
   Scores must be finite. Flags below describe semantic evidence, not UI layout. */
enum {
    SI_PRESENTATION_PREFERRED = 1,
    SI_PRESENTATION_REMEMBERED = 1 << 1,
    SI_PRESENTATION_PERSONAL = 1 << 2,
    SI_PRESENTATION_PUNCTUATION = 1 << 3,
    SI_PRESENTATION_COMPLETION = 1 << 4,
    SI_PRESENTATION_VERBATIM = 1 << 5,
    SI_PRESENTATION_CORRECTED = 1 << 6,
    SI_PRESENTATION_CHINESE_SENTENCE = 1 << 7
};
typedef struct SIPresentationCandidate {
    const uint8_t *identity;
    size_t identity_bytes;
    const uint8_t *text;
    size_t text_bytes;
    size_t consumed_bytes;
    size_t lexical_tokens;
    double lexical_score;
    double statistical_score;
    double reranking_bonus;
    uint32_t flags;
    uint8_t language; /* 0 literal, 1 Chinese, 2 English, 3 mixed */
    bool has_statistical_score;
} SIPresentationCandidate;
typedef struct SIPresentationRow {
    size_t index;
    size_t lexical_tokens;
    double presentation_score;
    bool remembered;
    bool chinese_sentence;
} SIPresentationRow;
typedef struct SIPresentationLimits { size_t ordinary; size_t words; } SIPresentationLimits;
typedef struct SIPresentationResult SIPresentationResult;
SIPresentationLimits si_presentation_limits(void);
/* Language mask: Chinese=1, English=2. NULL means invalid input. Non-NULL
   results are owned and must be freed; rows reference original input indices. */
SIPresentationResult *si_presentation_merge(const uint8_t *input, size_t input_bytes,
    uint8_t languages, bool coverage_order, const SIPresentationCandidate *candidates, size_t count);
SIPresentationResult *si_presentation_shortlist(const SIPresentationCandidate *candidates, size_t count);
/* SIZE_MAX means empty or invalid. Does not include character-model rewards. */
size_t si_presentation_statistical_leader(const SIPresentationCandidate *candidates, size_t count);
double si_presentation_coverage_bonus(const uint8_t *spelling, size_t spelling_bytes, bool literal, bool verbatim);
size_t si_presentation_count(const SIPresentationResult *result);
bool si_presentation_get(const SIPresentationResult *result, size_t index, SIPresentationRow *out);
void si_presentation_free(SIPresentationResult *result);

#endif
