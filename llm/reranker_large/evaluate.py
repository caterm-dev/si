"""Bounded ranking, reference/teacher metrics, latency and Rust parity checks."""

import json
import math
from pathlib import Path
import statistics
import subprocess
import time

import torch

from llm.reranker_small.data import load_bundle
from llm.reranker_small.runtime import load_checkpoint, rank_candidates, select_device
from .data import load_pools, manifest_at
from .scoring import suffix, validate_pool
from .settings import file_hash, write_json


@torch.inference_mode()
def predict(model, tokenizer, row, config, device):
    if not validate_pool(row, tokenizer, config):
        return dict(scores=[None] * len(row['candidates']), order=list(range(len(row['candidates']))),
                    abstained=True, context_tokens_used=0)
    context = suffix(row.get('context', ''), tokenizer, config['scoring']['context_tokens'])
    return rank_candidates(model, tokenizer, context, [c['text'] for c in row['candidates']], device,
                           config['scoring']['batch_size'], 1.0, config['scoring']['max_candidates'])


def synchronize(device):
    if device.type == 'mps':
        torch.mps.synchronize()
    elif device.type == 'cuda':
        torch.cuda.synchronize()


def evaluate(checkpoint_path, lm_data, pools_path, output, split='validation', device_name='mps', threads=4):
    if Path(output).exists():
        raise FileExistsError('Choose a new evaluation report')
    if split not in ('validation', 'test') or threads <= 0:
        raise ValueError('Evaluate a held-out split with positive threads')
    torch.set_num_threads(threads)
    device = select_device(device_name)
    checkpoint, model, tokenizer = load_checkpoint(checkpoint_path, device)
    config = checkpoint['config']
    lm_manifest, _, _ = load_bundle(lm_data, config, (split,))
    if checkpoint['dataset_id'] != lm_manifest['dataset_id']:
        raise ValueError('Evaluation dataset differs from checkpoint')
    pool_manifest = manifest_at(pools_path, 'si-student-pools')
    _, data = load_pools(pools_path, config, lm_manifest, tokenizer, (split,), scored=bool(pool_manifest['teacher']))
    totals, timings = dict(queries=0, abstentions=0, reviewed=0, top1=0, mrr=0.0,
                          teacher_scored=0, teacher_agreement=0), []
    for i in range(len(data[split])):
        row = data[split][i]
        synchronize(device)
        start = time.perf_counter()
        prediction = predict(model, tokenizer, row, config, device)
        synchronize(device)
        timings.append((time.perf_counter() - start) * 1000)
        totals['queries'] += 1
        totals['abstentions'] += int(prediction['abstained'])
        references = row.get('reference_indices', [])
        if references:
            rank = next(j + 1 for j, index in enumerate(prediction['order']) if index in references)
            totals['reviewed'] += 1
            totals['top1'] += int(rank == 1)
            totals['mrr'] += 1 / rank
        if 'teacher_scores' in row and not prediction['abstained']:
            scores = row['teacher_scores']
            best = max(scores)
            totals['teacher_scored'] += 1
            totals['teacher_agreement'] += int(scores[prediction['order'][0]] == best)
    report = dict(schema_version=1, kind='si-student-ranking-evaluation', split=split,
        checkpoint_sha256=file_hash(checkpoint_path), pool_dataset_id=pool_manifest['dataset_id'],
        counts=totals, reviewed_top1=totals['top1'] / totals['reviewed'] if totals['reviewed'] else None,
        reviewed_mrr=totals['mrr'] / totals['reviewed'] if totals['reviewed'] else None,
        teacher_agreement=totals['teacher_agreement'] / totals['teacher_scored'] if totals['teacher_scored'] else None,
        device=str(device), threads=threads, latency_ms=latency(timings),
        note='Supplied pools; references only when explicitly reviewed. Teacher agreement is not accuracy. '
             'Abstentions retain input pool order. Timing includes the first cold request and excludes host/UI/search.')
    write_json(output, report)
    return report


def latency(samples):
    ordered = sorted(samples)
    return dict(n=len(samples), p50=statistics.median(samples),
                p95=ordered[math.ceil(len(samples) * .95) - 1])


def rust_check(checkpoint_path, bundle, binary, output, repeats=40, threads=4):
    if Path(output).exists() or repeats < 2 or threads <= 0:
        raise ValueError('Choose a fresh report, positive threads and at least two repeats')
    torch.set_num_threads(threads)
    checkpoint, model, tokenizer = load_checkpoint(checkpoint_path, torch.device('cpu'))
    config = checkpoint['config']
    cases = [dict(context=context, candidates=pool) for context, pool in [
        ('', ['开会', '开慧']), ('今天下午我们一起', ['开会', '开慧', '开会', 'meet']),
        ('🙂' * 50 + '今天下午', ['你好', '您好', 'Swift API', '𠀀'])]]
    # ASCII-only long cases exceed the production limit and must abstain.
    oversized = 'a' * (config['model']['context'] + 1)
    parity_cases = cases + [dict(context='', candidates=[oversized, 'hi'])]
    request = lambda c: dict(context=suffix(c['context'], tokenizer, config['scoring']['context_tokens']),
                             candidates=c['candidates'], length_penalty=1.0)
    proc = subprocess.Popen([str(Path(binary).resolve()), 'rank', str(Path(bundle).resolve())],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    errors, samples = [], []
    try:
        def call(case):
            proc.stdin.write(json.dumps(request(case), ensure_ascii=False) + '\n')
            proc.stdin.flush()
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError('Rust scorer exited before returning a result')
            return json.loads(line)
        for case in parity_cases:
            q = request(case)
            expected = rank_candidates(model, tokenizer, q['context'], q['candidates'], torch.device('cpu'),
                                       config['scoring']['batch_size'], 1.0, max_candidates=12)
            actual = call(case)
            if actual['order'] != expected['order'] or actual['abstained'] != expected['abstained']:
                raise ValueError('Rust/Python candidate order or abstention differs')
            for a, b in zip(actual['scores'], expected['scores'], strict=True):
                if a is None or b is None:
                    if a is not b:
                        raise ValueError('Rust/Python score availability differs')
                else:
                    errors.append(abs(a - b))
                    if abs(a - b) > .005 + 1e-4 * abs(b):
                        raise ValueError('Rust/Python score mismatch')
        for case in cases:
            if any(len(tokenizer.encode(c)) - 2 > config['scoring']['candidate_tokens'] for c in case['candidates']):
                continue
            for _ in range(5):
                call(case)
            for _ in range(repeats):
                start = time.perf_counter()
                call(case)
                samples.append((time.perf_counter() - start) * 1000)
    finally:
        proc.stdin.close()
        proc.terminate()
        proc.wait(timeout=10)
        proc.stdout.close()
    report = dict(kind='si-student-rust-parity-and-latency', checkpoint_sha256=file_hash(checkpoint_path),
        binary_sha256=file_hash(binary), bundle_sha256=file_hash(Path(bundle) / 'model.json'),
        parity_queries=len(parity_cases), max_absolute_error=max(errors, default=0),
        latency_ms=latency(samples) if samples else None,
        note='Synthetic warmed resident Rust CLI round trips including JSON transport; no host timing or quality claim.')
    write_json(output, report)
    return report
