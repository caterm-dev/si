"""Evaluate frozen challenge tracks/categories without rewriting a trained model's code identity."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import time

import numpy as np
import torch

from ..benchmark import synchronize
from ..runtime import load_checkpoint, rank_candidates, select_device
from ..settings import file_hash, read_json, write_json
from .build import validate


def load_suite(root, split):
    if split not in ('dev', 'test'):
        raise ValueError('Select dev or test')
    root = Path(root)
    manifest = read_json(root / 'manifest.json')
    if manifest.get('schema_version') != 1:
        raise ValueError('Unsupported challenge manifest')
    for name in (split + '.jsonl', 'provenance.json', 'overlap-audit.json'):
        if file_hash(root / name) != manifest['files'][name]:
            raise ValueError('Challenge file modified: ' + name)
    rows = [json.loads(line) for line in (root / (split + '.jsonl')).read_text().splitlines()]
    if not rows or any(row['split'] != split for row in rows):
        raise ValueError('Incorrect challenge split')
    validate(rows)
    return rows, read_json(root / 'provenance.json'), file_hash(root / 'manifest.json')


def summarize(rows):
    count = len(rows)
    if not count:
        return {'cases': 0}
    available = sum(row['gold_in_pool'] for row in rows)
    groups = defaultdict(list)
    for row in rows:
        groups[row['family_id']].append(row['correct'])
    return {
        'cases': count, 'anchors': len({r['anchor_id'] for r in rows}), 'families': len(groups),
        'top1_accuracy': sum(r['correct'] for r in rows) / count,
        'baseline_top1_accuracy': sum(r['baseline_correct'] for r in rows) / count,
        'top1_delta': sum(int(r['correct']) - int(r['baseline_correct']) for r in rows) / count,
        'top_k_accuracy': {str(k): sum(r['gold_rank'] is not None and r['gold_rank'] <= k for r in rows) / count
                           for k in (1, 3, 5, 10, 27)},
        'mrr': sum(1 / r['gold_rank'] if r['gold_rank'] else 0 for r in rows) / count,
        'candidate_recall': available / count,
        'top1_when_gold_available': sum(r['correct'] for r in rows) / available if available else None,
        'macro_family_top1': sum(sum(values) / len(values) for values in groups.values()) / len(groups),
        'all_correct_families': sum(all(values) for values in groups.values()),
        'correct_to_wrong': sum(r['baseline_correct'] and not r['correct'] for r in rows),
        'wrong_to_correct': sum(not r['baseline_correct'] and r['correct'] for r in rows),
        'empty_pools': sum(r['empty_pool'] for r in rows),
        'abstentions': sum(r['abstained'] for r in rows),
        'policy_failures': sum(not r['policy_pass'] for r in rows),
    }


def evaluate_suite(checkpoint, suite, output, split='test', device_name='mps', threads=4):
    output = Path(output)
    if output.exists():
        raise FileExistsError('Report exists; choose --output NEW_PATH')
    if threads <= 0:
        raise ValueError('Thread count must be positive')
    rows, provenance, suite_hash = load_suite(suite, split)
    torch.set_num_threads(threads)
    device = select_device(device_name)
    payload, model, tokenizer = load_checkpoint(checkpoint, device)
    scoring = payload['config']['scoring']
    results, timings = [], []
    for index, row in enumerate(rows):
        pool = row['candidates']
        if pool:
            synchronize(device)
            start = time.perf_counter()
            scored = rank_candidates(model, tokenizer, row['context'], pool, device,
                                     scoring['batch_size'], scoring['length_penalty'], scoring['max_candidates'])
            synchronize(device)
            elapsed = (time.perf_counter() - start) * 1000
            timings.append(elapsed)
        else:
            scored = {'order': [], 'scores': [], 'abstained': False}
            elapsed = None
        gold = {i for i, text in enumerate(pool) if text in row['references']}
        top = scored['order'][0] if pool else None
        rank = next((i + 1 for i, candidate in enumerate(scored['order']) if candidate in gold), None)
        policy = (('expected_abstained' not in row or row['expected_abstained'] == scored['abstained'])
                  and ('expected_gold_in_pool' not in row or row['expected_gold_in_pool'] == bool(gold))
                  and (not row.get('expected_original_order') or scored['order'] == list(range(len(pool)))))
        results.append({key: row[key] for key in ('id', 'anchor_id', 'family_id', 'category', 'track', 'diagnostic', 'overlap')})
        results[-1].update(correct=top in gold, baseline_correct=0 in gold, gold_in_pool=bool(gold),
                           gold_rank=rank, empty_pool=not pool, predicted_index=top,
                           abstained=scored['abstained'], policy_pass=policy, latency_ms=elapsed,
                           order=scored['order'], scores=scored['scores'])
        if (index + 1) % 100 == 0:
            print(json.dumps({'event': 'challenge-progress', 'cases': index + 1, 'total': len(rows)}), flush=True)
    tracks = sorted({row['track'] for row in results})
    categories = sorted({row['category'] for row in results if not row['diagnostic']})
    clean = [r for r in results if not r['diagnostic'] and r['overlap']['status'] == 'clear']
    audit_id = provenance.get('overlap_dataset_id')
    # A clear audit against a different dataset must not be described as clean for this model.
    if audit_id != payload['dataset_id']:
        clean = []
    report = {
        'schema_version': 1, 'kind': 'si-candidate-challenge', 'split': split,
        'suite_manifest_sha256': suite_hash, 'checkpoint_sha256': file_hash(checkpoint),
        'checkpoint_step': payload['step'], 'model_dataset_id': payload['dataset_id'],
        'overlap_audit_matches_model_dataset': audit_id == payload['dataset_id'],
        'device': str(device), 'threads': threads, 'torch_version': str(torch.__version__),
        'clean_by_track': {track: summarize([r for r in clean if r['track'] == track]) for track in tracks
                           if any(r['track'] == track for r in clean)},
        'all_by_track': {track: summarize([r for r in results if r['track'] == track]) for track in tracks},
        'clean_by_category': {category: {track: summarize([r for r in clean if r['category'] == category and r['track'] == track])
                                        for track in ('controlled', 'decoder')}
                              for category in categories},
        'latency_ms': {'p50': float(np.percentile(timings, 50)), 'p95': float(np.percentile(timings, 95))} if timings else None,
        'cases': results,
        'note': 'Use clean controlled/decoder tracks separately; synthetic ordering is not an engine baseline. '
                'Derived context/phrase/alias variants are correlated. Diagnostics are not primary quality metrics. '
                'Offline timing includes the first cold case; it is not host-app latency. '
                'AI-assisted labels have not received independent human annotation review.',
    }
    write_json(output, report)
    return {key: value for key, value in report.items() if key not in ('cases', 'clean_by_category')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', required=True, type=Path)
    parser.add_argument('--suite', type=Path, default=Path(__file__).resolve().parent / 'chinese-v1')
    parser.add_argument('--split', choices=('dev', 'test'), default='test')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', choices=('cpu', 'mps', 'cuda', 'auto'), default='mps')
    parser.add_argument('--threads', type=int, default=4)
    args = parser.parse_args()
    print(json.dumps(evaluate_suite(args.checkpoint, args.suite, args.output, args.split, args.device, args.threads), indent=2))
