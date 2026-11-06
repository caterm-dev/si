#include "SIKenLM.h"
#include "upstream/lm/model.hh"
#include <cstring>
#include <limits>

using Model = lm::ngram::QuantArrayTrieModel;
using State = lm::ngram::State;

struct SIKenLMModel {
    Model value;
    SIKenLMModel(const char *path, const lm::ngram::Config &config) : value(path, config) {}
};

static_assert(sizeof(State) <= sizeof(SIKenLMState));

SIKenLMModel *SIKenLMOpen(const char *path) {
    try {
        lm::ngram::ModelType type;
        if (!lm::ngram::RecognizeBinary(path, type) || type != Model::kModelType) return nullptr;
        lm::ngram::Config config;
        config.load_method = util::LAZY;
        config.messages = nullptr;
        return new SIKenLMModel(path, config);
    } catch (...) {
        return nullptr;
    }
}

void SIKenLMClose(SIKenLMModel *model) { delete model; }

uint32_t SIKenLMIndex(const SIKenLMModel *model, const char *bytes, size_t length) {
    return model->value.GetVocabulary().Index(StringPiece(bytes, length));
}

static void Store(State state, SIKenLMState *destination) {
    state.ZeroRemaining();
    std::memset(destination, 0, sizeof(*destination));
    std::memcpy(destination, &state, sizeof(state));
}

void SIKenLMBeginSentence(const SIKenLMModel *model, SIKenLMState *state) {
    Store(model->value.BeginSentenceState(), state);
}

float SIKenLMAdvance(const SIKenLMModel *model, const SIKenLMState *state, uint32_t word, SIKenLMState *next) {
    if (!word || word >= model->value.GetVocabulary().Bound()) return std::numeric_limits<float>::quiet_NaN();
    State input{}, output{};
    std::memcpy(&input, state, sizeof(input));
    if (input.length >= model->value.Order()) return std::numeric_limits<float>::quiet_NaN();
    const float result = model->value.FullScore(input, word, output).prob;
    Store(output, next);
    return result;
}
