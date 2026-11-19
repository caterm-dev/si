"""Local neural candidate generation and features for the offline ranking pool."""

import math
import re
import unicodedata

FEATURE_GROUPS = {
    'candidate_sources': ['from_si_engine', 'from_pinyin_model', 'pinyin_model_beam_rank'],
    'neural_reranker': ['reranker_logp_sum', 'reranker_logp_mean', 'reranker_context_gain'],
}
LANGUAGE_CODES = {'zh-Hans': 0, 'en': 1, 'mixed': 2}


def candidate_language(text):
    names = [unicodedata.name(char, '') for char in text]
    han = any(name.startswith(('CJK UNIFIED IDEOGRAPH', 'CJK COMPATIBILITY IDEOGRAPH')) or char == '〇'
              for name, char in zip(names, text))
    latin = any(name.startswith('LATIN ') and char.isalpha() for name, char in zip(names, text))
    if han:
        return 'mixed' if latin else 'zh-Hans'
    if latin:
        return 'en'
    return None


def printable(text):
    return (bool(text.strip()) and len(text.encode('utf-8', errors='surrogatepass')) <= 4096
            and not any(unicodedata.category(char) in ('Cc', 'Cs') for char in text))


def merge_row(row, rust_names, generate, score):
    """Merge by exact text and language; reveal references only when attaching labels."""
    pool = {}
    for candidate in row['candidates']:
        key = (candidate['language'], candidate['text'])
        pool[key] = [candidate['features'], 1, 0, None]
    language_index = rust_names.index('candidate_language')
    enabled = set(row['languages'])
    if {'zh-Hans', 'en'} <= enabled:
        enabled.add('mixed')
    if 'zh-Hans' in enabled:
        for rank, output in enumerate(generate(row['input'], row['context'], row.get('syllable_paths', ())), 1):
            language = candidate_language(output)
            if output == row['input'] or language not in enabled or not printable(output):
                continue
            key = (language, output)
            if key not in pool:
                features = [None] * len(rust_names)
                features[language_index] = LANGUAGE_CODES[language]
                pool[key] = [features, 0, 0, None]
            if pool[key][3] is None:
                pool[key][2:] = [1, rank]
    surfaces = list(dict.fromkeys(text for _, text in pool))
    context_available = row.get('context_available', bool(row['context']))
    scores = score(row['context'] if context_available else None, surfaces)
    candidates = []
    for (language, text), (features, from_si, from_pinyin, rank) in pool.items():
        candidates.append({'language': language, 'text': text, 'label': int(text in row['references']),
                           'features': [*features, from_si, from_pinyin, rank, *scores[text]]})
    return {**row, 'candidates': candidates}


class NeuralModels:
    def __init__(self, pinyin_path, reranker_path, device, beam_size):
        import torch
        from llm.pinyin_to_text import runtime as pinyin
        from llm.reranker_small import runtime as reranker

        torch.set_num_threads(4)
        self.device = pinyin.select_device(device)
        self.torch_version = str(torch.__version__)
        self.convert = pinyin.candidates
        self.rank = reranker.rank_candidates
        config, self.pinyin, self.pinyin_tokenizer = pinyin.load_checkpoint(pinyin_path, self.device)
        scoring, self.reranker, self.reranker_tokenizer = reranker.load_checkpoint(reranker_path, self.device)
        self.beam_size = beam_size
        self.pinyin_penalty = config['config']['decoding']['length_penalty']
        self.reranker_settings = scoring['config']['scoring']
        self.contextual = self.pinyin.config.get('source_format') == pinyin.CONTEXTUAL_PINYIN
        self.metadata = {
            'device': str(self.device), 'torch': self.torch_version, 'beam_size': self.beam_size,
            'pinyin_source_format': self.pinyin.config.get('source_format', 'spelling'),
            'pinyin_length_penalty': self.pinyin_penalty,
            'reranker_baseline_length_penalty': self.reranker_settings['length_penalty'],
            'pinyin_dataset_id': config.get('dataset_id'), 'reranker_dataset_id': scoring.get('dataset_id'),
            'pinyin_tokenizer_digest': config['tokenizer_digest'], 'reranker_tokenizer_digest': scoring['tokenizer_digest'],
        }

    def generate(self, spelling, context, syllable_paths):
        spelling = unicodedata.normalize('NFC', spelling).lower().replace('u:', 'ü').replace('v', 'ü')
        if not re.fullmatch(r"[a-zü]+(?:'[a-zü]+)*'?", spelling):
            return []
        if self.contextual:
            # Syllable paths are observed source metadata, never derived from references.
            if not syllable_paths:
                return []
            kwargs = {'context': context, 'syllable_paths': syllable_paths}
        else:
            kwargs = {}
        return self.convert(self.pinyin, self.pinyin_tokenizer, spelling.replace("'", ''), self.device,
                            self.beam_size, self.pinyin_penalty, **kwargs)['model_candidates']

    def score(self, context, texts):
        scores = dict.fromkeys(texts, (None, None, None))
        lengths = {text: len(self.reranker_tokenizer.encode(text)) - 2 for text in texts if printable(text)}
        eligible = [text for text, size in lengths.items() if 0 < size <= self.reranker.config['context']]
        if not eligible:
            return scores

        def logp(history):
            # Keep the same context truncation across the pool. The model still
            # evaluates bounded batches internally, regardless of the pool size.
            result = self.rank(self.reranker, self.reranker_tokenizer, history, eligible, self.device,
                               batch_size=self.reranker_settings['batch_size'], max_candidates=64 + self.beam_size)
            return result['scores']

        conditioned = logp(context or '')
        unconditional = logp('') if context else conditioned
        for text, total, prior in zip(eligible, conditioned, unconditional, strict=True):
            if total is None or prior is None:
                continue
            if not math.isfinite(total) or not math.isfinite(prior):
                raise ValueError('Nonfinite reranker feature')
            scores[text] = (total, total / lengths[text], total - prior if context is not None else None)
        return scores
