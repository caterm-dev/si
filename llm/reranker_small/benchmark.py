"""Evaluate fixed candidate pools and report improvements, regressions and recall ceiling."""

import argparse
import json
from pathlib import Path
import time

import numpy as np
import torch

from llm.pinyin_to_text.common import read_jsonl
from .runtime import load_checkpoint, rank_candidates, select_device
from .settings import file_hash, read_json, write_json


def synchronize(device):
    if device.type == 'mps':
        torch.mps.synchronize()
    elif device.type == 'cuda':
        torch.cuda.synchronize()


def benchmark(checkpoint_path, cases_path, provenance_path, output, device_name='mps', threads=4):
    output = Path(output)
    if output.exists():
        raise FileExistsError('Report exists; choose a new report path')
    declaration = read_json(provenance_path)
    if declaration.get('schema_version') != 1 or any(not isinstance(declaration.get(key), str)
            or not declaration[key].strip() for key in ('license', 'origin', 'revision')):
        raise ValueError('Benchmark requires origin, license and revision declarations')
    if threads <= 0:
        raise ValueError('Thread count must be positive')
    torch.set_num_threads(threads)
    device = select_device(device_name)
    checkpoint, model, tokenizer = load_checkpoint(checkpoint_path, device)
    settings = checkpoint['config']['scoring']
    cases = []
    timings = []
    seen = set()
    for row in read_jsonl(cases_path):
        identity = row.get('id')
        references = row.get('references')
        candidates = row.get('candidates')
        if (not isinstance(identity, str) or not identity or identity in seen
                or not isinstance(references, list) or not references
                or not all(isinstance(text, str) and text for text in references)
                or not isinstance(candidates, list) or not candidates):
            raise ValueError('Invalid benchmark case or repeated case ID')
        seen.add(identity)
        synchronize(device)
        start = time.perf_counter()
        result = rank_candidates(model, tokenizer, row.get('context', ''), candidates, device,
                                 settings['batch_size'], settings['length_penalty'], settings['max_candidates'])
        synchronize(device)
        timings.append((time.perf_counter() - start) * 1000)
        gold = {index for index, text in enumerate(candidates) if text in references}
        top = result['order'][0]
        rank = next((index + 1 for index, candidate in enumerate(result['order']) if candidate in gold), None)
        cases.append({'id': identity, 'predicted_index': top, 'correct': top in gold,
                      'baseline_correct': 0 in gold, 'gold_in_pool': bool(gold),
                      'reciprocal_rank': 1 / rank if rank else 0, 'abstained': result['abstained']})
    if not cases:
        raise ValueError('Benchmark has no cases')
    count = len(cases)
    in_pool = sum(row['gold_in_pool'] for row in cases)
    report = {
        'schema_version': 1, 'kind': 'candidate-ranking-evaluation', 'cases': cases,
        'checkpoint_sha256': file_hash(checkpoint_path), 'benchmark_sha256': file_hash(cases_path),
        'provenance_sha256': file_hash(provenance_path), 'provenance': declaration,
        'top1_accuracy': sum(row['correct'] for row in cases) / count,
        'baseline_top1_accuracy': sum(row['baseline_correct'] for row in cases) / count,
        'mrr': sum(row['reciprocal_rank'] for row in cases) / count,
        'candidate_recall': in_pool / count,
        'top1_when_gold_available': sum(row['correct'] for row in cases) / in_pool if in_pool else None,
        'correct_to_wrong': sum(row['baseline_correct'] and not row['correct'] for row in cases),
        'wrong_to_correct': sum(not row['baseline_correct'] and row['correct'] for row in cases),
        'abstentions': sum(row['abstained'] for row in cases),
        'device': str(device), 'threads': threads,
        'latency_ms': {'p50': float(np.percentile(timings, 50)), 'p95': float(np.percentile(timings, 95))},
        'note': 'Offline supplied-pool evaluation, including the first/cold case. No host latency claim. '
                'Declaration does not prove independence or absence of training overlap.',
    }
    write_json(output, report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', required=True, type=Path)
    parser.add_argument('--benchmark', required=True, type=Path)
    parser.add_argument('--provenance', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', choices=('auto', 'cpu', 'mps', 'cuda'), default='mps')
    parser.add_argument('--threads', type=int, default=4)
    args = parser.parse_args()
    print(json.dumps(benchmark(args.checkpoint, args.benchmark, args.provenance, args.output,
                               args.device, args.threads), ensure_ascii=False, indent=2))
