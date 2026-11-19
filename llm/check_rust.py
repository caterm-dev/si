"""Compare local Rust inference bundles with their trusted PyTorch checkpoints."""

import argparse
import json
from pathlib import Path
import subprocess
import time

import torch

from .pinyin_to_text import runtime as pinyin
from .reranker_small import runtime as reranker


def predict(binary, mode, bundle, cases):
    payload = ''.join(json.dumps(case, ensure_ascii=False) + '\n' for case in cases)
    result = subprocess.run([binary, mode, bundle], input=payload, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f'{mode} Rust inference failed: {result.stderr.strip()}')
    return [json.loads(line) for line in result.stdout.splitlines()]


def verify(binary, pinyin_bundle, pinyin_checkpoint, reranker_bundle, reranker_checkpoint):
    torch.set_num_threads(4)
    cpu = torch.device('cpu')
    config, model, tokenizer = pinyin.load_checkpoint(pinyin_checkpoint, cpu)
    contextual = model.config.get('source_format') == pinyin.CONTEXTUAL_PINYIN
    if contextual:
        generation = [
            {'input': 'fangan', 'context': '先定个', 'syllable_paths': ['fang an', 'fan gan', 'fang an'], 'beam_size': 5},
            {'input': 'fangan', 'context': '表达一点', 'syllable_paths': ['fan gan', 'fang an'], 'beam_size': 8},
            {'input': 'nihao', 'context': '🙂' * 96, 'syllable_paths': ['ni hao'], 'beam_size': 5},
            {'input': 'nihao', 'context': '', 'beam_size': 5},
        ]
    else:
        generation = [{'input': spelling, 'beam_size': beam}
                      for spelling, beam in [('nihao', 5), ('shijie', 8), ('lüse', 5), ('fangan', 8),
                                             ('zzzz', 3), ('a' * 49, 3), ('', 3)]]
    penalty = config['config']['decoding']['length_penalty']
    py_generation = [pinyin.candidates(model, tokenizer, case['input'], cpu, case['beam_size'], penalty,
                                       context=case.get('context'), syllable_paths=case.get('syllable_paths', ()))
                     for case in generation]
    rust_generation = predict(binary, 'generate', pinyin_bundle, generation)
    for i, (expected, actual) in enumerate(zip(py_generation, rust_generation, strict=True)):
        if actual != expected:
            raise ValueError(f'Generation candidates or ordering differ on fixture {i}')

    config, model, tokenizer = reranker.load_checkpoint(reranker_checkpoint, cpu)
    ranking = [
        {'context': '', 'candidates': ['我们开会', '我们开慧', 'Swift API', '🙂𠀀']},
        {'context': '今天下午，', 'candidates': ['开会', '开慧', '开会', 'meet']},
        {'context': '🙂' * 100 + '先写下', 'candidates': ['行', '行', '行得通', '好'], 'length_penalty': 0.6},
        {'context': '你会选', 'candidates': ['是', '时', '事', '十']},
        {'context': '仅返回原顺序', 'candidates': ['我' * (model.config['context'] + 1), '我们']},
        {'context': '', 'candidates': []},
    ]
    penalty = config['config']['scoring']['length_penalty']
    py_ranking = [reranker.rank_candidates(model, tokenizer, case['context'], case['candidates'], cpu,
                                           length_penalty=case.get('length_penalty', penalty)) for case in ranking]
    actual = predict(binary, 'rank', reranker_bundle, ranking)
    errors = []
    for i, (expected, result) in enumerate(zip(py_ranking, actual, strict=True)):
        if (result['order'], result['abstained'], result['context_tokens_used']) != (
                expected['order'], expected['abstained'], expected.get('context_tokens_used', 0)):
            raise ValueError(f'Score order, abstention or context differs on fixture {i}')
        for left, right in zip(result['scores'], expected['scores'], strict=True):
            if left is None or right is None:
                if left is not right:
                    raise ValueError(f'Score availability differs on fixture {i}')
                continue
            error = abs(left - right)
            if error > 0.005 + 1e-4 * abs(right):
                raise ValueError(f'Numeric score differs on fixture {i}')
            errors.append(error)
    return {'generation_queries': len(generation), 'ranking_queries': len(ranking),
            'candidate_scores': len(errors), 'max_absolute_score_error': max(errors)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['binary', 'pinyin-bundle', 'pinyin-checkpoint', 'reranker-bundle', 'reranker-checkpoint']:
        parser.add_argument(f'--{key}', type=Path, required=True)
    started = time.perf_counter()
    print(json.dumps(verify(**vars(parser.parse_args())), sort_keys=True))
    print(f'Parity check elapsed: {time.perf_counter() - started:.2f}s')


if __name__ == '__main__':
    main()
