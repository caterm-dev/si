#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SIKenLMModel SIKenLMModel;
typedef struct {
    uint64_t storage[8];
} SIKenLMState;

SIKenLMModel *SIKenLMOpen(const char *path);
void SIKenLMClose(SIKenLMModel *model);
uint32_t SIKenLMIndex(const SIKenLMModel *model, const char *bytes, size_t length);
void SIKenLMBeginSentence(const SIKenLMModel *model, SIKenLMState *state);
float SIKenLMAdvance(const SIKenLMModel *model, const SIKenLMState *state, uint32_t word, SIKenLMState *next);

#ifdef __cplusplus
}
#endif
