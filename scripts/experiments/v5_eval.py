#!/usr/bin/env python3
"""Evaluate experimental LightGBM models with the original V5 pool construction."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

from v5_score_ablation import INDICES, METRICS, NAMES, VARIANTS, evaluate_row, rank_pools
from v5_probability_audit import ROOT, pipeline

sys.path.insert(0, str(ROOT / 'scripts'))
import ranking_eval


def source_rows(args, bundle_splits):
    if args.dataset == 'test':
        rows, checksum = ranking_eval.load()
        for row in rows:
            if row['context'] != []:
                raise ValueError('Unexpected frozen test context representation')
            row['context'] = ''
        return rows, checksum

    rows = pipeline.read_queries(args.diagnostic)
    held = {pipeline.normalized(row['input']) for row in rows}
    trained = {pipeline.normalized(row['input']) for split in bundle_splits for row in split}
    if len(held) != len(rows) or held & trained:
        raise ValueError('Diagnostic inputs must be unique and separate from training inputs')
    return rows, pipeline.sha(args.diagnostic)


def build_pools(args, rows, manifest):
    models = pipeline.neural_features.NeuralModels(
        args.pinyin_model, args.reranker_model, manifest['neural_models']['device'],
        manifest['neural_models']['beam_size'])
    assets = {'exporter': args.binary, 'lexicon': args.lexicon, 'grams': args.grams,
              'pinyin_model': args.pinyin_model, 'reranker_model': args.reranker_model}
    checksums = {name: pipeline.sha(path) for name, path in assets.items()}
    if any(manifest['resources'][name] != value for name, value in checksums.items()):
        raise ValueError('The V5 evaluator requires the same resources as the prepared training bundle')
    if manifest['personal_state']['user_resources_supplied']:
        raise ValueError('The experimental evaluator expects the baseline bundle without user resources')
    exported = pipeline.export_rows(
        args.binary, args.lexicon, args.grams, rows, schema=pipeline.V5_LEXICAL_SCHEMA,
        correction=manifest['pinyin_correction'], model_correction_pool=manifest['model_correction_pool'],
        pinyin_paths=models.contextual)
    merged = [pipeline.neural_features.merge_row(row, pipeline.V5_LEXICAL_FEATURES,
                                                models.generate, models.score) for row in exported]
    from_si, from_pinyin = INDICES['from_si_engine'], INDICES['from_pinyin_model']
    for row in merged:
        features = [candidate['features'] for candidate in row['candidates']]
        if (len(features) > 64 + models.beam_size
                or any(len(values) != len(NAMES) for values in features)
                or sum(values[from_si] for values in features) > 64
                or sum(values[from_pinyin] for values in features) > models.beam_size):
            raise ValueError(f'Invalid pool width or source limit in {row["id"]}')
    return merged, checksums


def candidate_source(features):
    sources = (features[INDICES['from_si_engine']], features[INDICES['from_pinyin_model']])
    return {(1, 0): 'SI', (0, 1): '拼音模型', (1, 1): 'SI + 拼音模型'}[sources]


def score(args):
    import lightgbm as lgb

    data = json.loads(args.pool_file.read_text())
    rows = data.pop('rows')
    variants = args.variant
    model_info = json.loads((args.models / 'manifest.json').read_text())
    if model_info['bundle_manifest_sha256'] != data['bundle_manifest_sha256']:
        raise ValueError('Model suite and pool were prepared from different manifests')
    for variant in variants:
        path = args.models / f'{variant}.txt'
        if pipeline.sha(path) != model_info['models'][variant]:
            raise ValueError(f'Model checksum mismatch for {variant}')
    sizes = [len(row['candidates']) for row in rows]
    report = {**data, 'model_sha256': {variant: model_info['models'][variant] for variant in variants},
              'queries': len(rows), 'pool_sizes': {'min': min(sizes), 'median': statistics.median(sizes),
                                                 'max': max(sizes), 'mean': statistics.fmean(sizes),
                                                 'empty_queries': sum(size == 0 for size in sizes),
                                                 'candidates': sum(sizes)}}
    if args.smoke and (variants != ['A'] or not any(sizes)):
        raise ValueError('Smoke evaluation requires baseline A and a nonempty candidate set')
    ranked = {variant: rank_pools(lgb.Booster(model_file=str(args.models / f'{variant}.txt')), rows, variant)
              for variant in variants}
    if args.smoke:
        report['smoke'] = {'scored_candidates': sum(len(pool) for pool in ranked['A']),
                           'all_scores_finite': True, 'passed': True}
    elif data['dataset'] == 'diagnostic':
        diagnostics = []
        for index, row in enumerate(rows):
            outputs = {}
            for variant in variants:
                outputs[variant] = [
                    {'rank': rank, 'text': candidate['text'], 'language': candidate['language'],
                     'score': float(score), 'source': candidate_source(candidate['features'])}
                    for rank, (candidate, score) in enumerate(ranked[variant][index][:4], 1)
                ]
            diagnostics.append({'id': row['id'], 'input': row['input'], 'references': row['references'],
                                'candidate_count': sizes[index], 'variants': outputs})
        report['diagnostics'] = diagnostics
    else:
        report['metrics'] = {}
        for variant, pools in ranked.items():
            results = [evaluate_row(pool) for pool in pools]
            report['metrics'][variant] = {
                'overall': {name: statistics.fmean(result[name] for result in results) for name in METRICS},
                'per_query': [{'id': row['id'], **result} for row, result in zip(rows, results, strict=True)],
            }
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2, ensure_ascii=False, allow_nan=False)
        stream.write('\n')
    print(json.dumps({'dataset': data['dataset'], 'queries': len(rows), 'variants': variants,
                      'pool_sizes': report['pool_sizes'], 'output': str(args.output)}, ensure_ascii=False))


def evaluate(args):
    if args.smoke and args.dataset != 'test':
        raise ValueError('Smoke mode is for the frozen test evaluation')
    if args.output.exists():
        raise ValueError('Choose a new evaluation output')
    splits, manifest = pipeline.load_bundle(args.bundle)
    rows, checksum = source_rows(args, splits)
    merged, resources = build_pools(args, rows, manifest)
    payload = {'dataset': args.dataset, 'dataset_sha256': checksum,
               'bundle_manifest_sha256': pipeline.sha(args.bundle / 'manifest.json'),
               'model_correction_pool': manifest['model_correction_pool'],
               'pinyin_beam_size': manifest['neural_models']['beam_size'],
               'resources': resources, 'rows': merged}
    variants = list(VARIANTS) if args.dataset == 'diagnostic' else ['A']
    with tempfile.TemporaryDirectory(prefix='si-v5-eval-', dir='/tmp') as scratch:
        pool_file = Path(scratch) / 'pools.json'
        pipeline.write_json(pool_file, payload)
        command = [str(args.scoring_python), '-B', str(Path(__file__).resolve()), 'score',
                   '--pool-file', str(pool_file), '--models', str(args.models), '--output', str(args.output)]
        for variant in variants:
            command += ['--variant', variant]
        if args.smoke:
            command.append('--smoke')
        subprocess.run(command, check=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    run = commands.add_parser('evaluate')
    run.add_argument('--dataset', choices=('test', 'diagnostic'), required=True)
    run.add_argument('--bundle', type=Path, required=True)
    run.add_argument('--models', type=Path, required=True)
    run.add_argument('--diagnostic', type=Path, default=ROOT / 'eval/ranking/diagnostic-dev.jsonl')
    run.add_argument('--binary', type=Path, default=ROOT / 'target/release/si-cli')
    run.add_argument('--lexicon', type=Path, default=pipeline.DEFAULT_RESOURCES / 'main.silex')
    run.add_argument('--grams', type=Path, default=pipeline.DEFAULT_RESOURCES / 'words.sigram')
    run.add_argument('--pinyin-model', type=Path,
                     default=ROOT / 'llm/pinyin_to_text/runs/small-pinyin-syllable-100k-v1/best.pt')
    run.add_argument('--reranker-model', type=Path,
                     default=ROOT / 'llm/reranker_small/runs/small-chat-v2/best.pt')
    run.add_argument('--scoring-python', type=Path, default=ROOT / '.venv/lambdarank/bin/python')
    run.add_argument('--output', type=Path, required=True)
    run.add_argument('--smoke', action='store_true')
    scorer = commands.add_parser('score')
    scorer.add_argument('--pool-file', type=Path, required=True)
    scorer.add_argument('--models', type=Path, required=True)
    scorer.add_argument('--output', type=Path, required=True)
    scorer.add_argument('--variant', choices=VARIANTS, action='append', required=True)
    scorer.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    if args.command == 'evaluate':
        evaluate(args)
    else:
        score(args)


if __name__ == '__main__':
    main()
